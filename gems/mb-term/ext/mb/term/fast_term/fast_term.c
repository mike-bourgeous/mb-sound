/*
 * MB::Term::FastTerm: mb-term's native cell grid.
 *
 * FastTerm::Grid is a grid of character cells (codepoint, foreground and
 * background as packed colors or -1, attributes; mb_term_grid.h), the
 * native twin of MB::Term::Cells, each method an exact mirror that specs
 * compare with it (same cells, same bytes): #set_cell, #put_text,
 * #put_run, #char, #copy_from, #blit, #clear, #lines and #to_text (SGR
 * text in each color mode), #frame (the bytes that draw every cell, or
 * those that differ from a previous grid), and #write_frame (#frame
 * written to a file descriptor without the GVL).  MB::Term::NativeCells
 * (native.rb) gives it Cells' keyword interface.
 *
 * FastTerm::VT (vt.c) is the native terminal model, the mirror of
 * MB::Term::RubyVT (MB::Term::NativeVT in vt.rb).
 *
 * Moved from mb-sound's fast_ui (term-extract-1, 2026-10-29), which keeps
 * the plot kernels and Grid#compose in a subclass (MB::Sound::FastUI::Grid).
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/io.h>
#include <ruby/thread.h>
#include <errno.h>
#include <poll.h>
#include <unistd.h>

#include "mb_term_grid.h"
#include "fast_term.h"

static VALUE cGrid;

static void grid_free(void *p)
{
	struct mb_term_grid *g = p;
	xfree(g->cp);
	xfree(g->fg);
	xfree(g->bg);
	xfree(g->attr);
	xfree(g->out.p);
	xfree(g->sgr);
	xfree(g);
}

static size_t grid_memsize(const void *p)
{
	const struct mb_term_grid *g = p;
	return sizeof(*g) + (size_t)(g->width * g->height) * (4 + 4 + 4 + 1);
}

static const rb_data_type_t grid_type = {
	.wrap_struct_name = "MB::Term::FastTerm::Grid",
	.function = { .dmark = NULL, .dfree = grid_free, .dsize = grid_memsize },
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE grid_alloc(VALUE klass)
{
	struct mb_term_grid *g = ZALLOC(struct mb_term_grid);
	return TypedData_Wrap_Struct(klass, &grid_type, g);
}

static struct mb_term_grid *get_grid(VALUE self)
{
	struct mb_term_grid *g;
	TypedData_Get_Struct(self, struct mb_term_grid, &grid_type, g);
	if (g->cp == NULL && g->width * g->height > 0) {
		rb_raise(rb_eRuntimeError, "Grid not initialized");
	}
	return g;
}

static void grid_clear_cells(struct mb_term_grid *g)
{
	long n = g->width * g->height;
	for (long i = 0; i < n; i++) {
		g->cp[i] = ' ';
		g->fg[i] = -1;
		g->bg[i] = -1;
		g->attr[i] = 0;
	}
}

static VALUE grid_initialize(VALUE self, VALUE w_v, VALUE h_v)
{
	struct mb_term_grid *g;
	TypedData_Get_Struct(self, struct mb_term_grid, &grid_type, g);
	long w = NUM2LONG(w_v);
	long h = NUM2LONG(h_v);
	if (w < 0 || h < 0 || w > 100000 || h > 100000 || w * h > 10000000) {
		rb_raise(rb_eArgError, "Bad grid size %ldx%ld", w, h);
	}
	if (g->cp) {
		rb_raise(rb_eRuntimeError, "Grid already initialized");
	}
	size_t n = (size_t)(w * h);
	g->width = w;
	g->height = h;
	g->cp = ALLOC_N(uint32_t, n ? n : 1);
	g->fg = ALLOC_N(int32_t, n ? n : 1);
	g->bg = ALLOC_N(int32_t, n ? n : 1);
	g->attr = ALLOC_N(uint8_t, n ? n : 1);
	grid_clear_cells(g);
	return self;
}

static VALUE grid_width(VALUE self)
{
	return LONG2NUM(get_grid(self)->width);
}

static VALUE grid_height(VALUE self)
{
	return LONG2NUM(get_grid(self)->height);
}

static int32_t color_arg(VALUE v)
{
	return NIL_P(v) ? -1 : (int32_t)NUM2INT(v);
}

static uint32_t first_codepoint(VALUE str)
{
	StringValue(str);
	if (RSTRING_LEN(str) == 0) {
		return 0; // the right half of a wide character (written as nothing)
	}
	rb_encoding *enc = rb_enc_get(str);
	int len;
	return (uint32_t)rb_enc_codepoint_len(RSTRING_PTR(str), RSTRING_END(str), &len, enc);
}

/* set_cell(x, y, ch, fg, bg, attr): one cell (clipped); fg/bg 0xRRGGBB or nil */
static VALUE grid_set_cell(VALUE self, VALUE x_v, VALUE y_v, VALUE ch_v, VALUE fg_v, VALUE bg_v, VALUE attr_v)
{
	struct mb_term_grid *g = get_grid(self);
	long x = NUM2LONG(x_v);
	long y = NUM2LONG(y_v);
	if (x < 0 || y < 0 || x >= g->width || y >= g->height) {
		return Qnil;
	}
	long i = y * g->width + x;
	g->cp[i] = first_codepoint(ch_v);
	g->fg[i] = color_arg(fg_v);
	g->bg[i] = color_arg(bg_v);
	g->attr[i] = (uint8_t)NUM2INT(attr_v);
	return Qnil;
}

/* put_text(x, y, str, fg, attr, max): each character of +str+ (up to +max+ or nil) from (x, y), clipped, background cleared */
static VALUE grid_put_text(VALUE self, VALUE x_v, VALUE y_v, VALUE str, VALUE fg_v, VALUE attr_v, VALUE max_v)
{
	struct mb_term_grid *g = get_grid(self);
	long x = NUM2LONG(x_v);
	long y = NUM2LONG(y_v);
	int32_t fg = color_arg(fg_v);
	uint8_t attr = (uint8_t)NUM2INT(attr_v);
	long max = NIL_P(max_v) ? -1 : NUM2LONG(max_v);
	str = rb_obj_as_string(str);
	rb_encoding *enc = rb_enc_get(str);
	const char *p = RSTRING_PTR(str);
	const char *e = RSTRING_END(str);
	long k = 0;
	while (p < e && (max < 0 || k < max)) {
		int len;
		uint32_t cp = (uint32_t)rb_enc_codepoint_len(p, e, &len, enc);
		p += len;
		long cx = x + k;
		k++;
		if (cx < 0 || y < 0 || cx >= g->width || y >= g->height) {
			continue;
		}
		long i = y * g->width + cx;
		g->cp[i] = cp;
		g->fg[i] = fg;
		g->bg[i] = -1;
		g->attr[i] = attr;
	}
	return Qnil;
}

/*
 * put_run(x, y, str, fg, bg, attr): each character of +str+ from (x, y)
 * with one style (packed colors or nil), clipped; "\0" (or code point 0)
 * marks the right half of a wide character.  For terminal panes (MB::Term::VT
 * rows), which keep backgrounds.
 */
static VALUE grid_put_run(VALUE self, VALUE x_v, VALUE y_v, VALUE str, VALUE fg_v, VALUE bg_v, VALUE attr_v)
{
	struct mb_term_grid *g = get_grid(self);
	long x = NUM2LONG(x_v);
	long y = NUM2LONG(y_v);
	int32_t fg = color_arg(fg_v);
	int32_t bg = color_arg(bg_v);
	uint8_t attr = (uint8_t)NUM2INT(attr_v);
	StringValue(str);
	if (y < 0 || y >= g->height) {
		return Qnil;
	}
	rb_encoding *enc = rb_enc_get(str);
	const char *p = RSTRING_PTR(str);
	const char *e = RSTRING_END(str);
	long cx = x;
	while (p < e && cx < g->width) {
		int len;
		uint32_t cp = (uint32_t)rb_enc_codepoint_len(p, e, &len, enc);
		p += len;
		if (cx >= 0) {
			long i = y * g->width + cx;
			g->cp[i] = cp;
			g->fg[i] = fg;
			g->bg[i] = bg;
			g->attr[i] = attr;
		}
		cx++;
	}
	return Qnil;
}

/* char(x, y): the character at a cell (a String) */
static VALUE grid_char(VALUE self, VALUE x_v, VALUE y_v)
{
	struct mb_term_grid *g = get_grid(self);
	long x = NUM2LONG(x_v);
	long y = NUM2LONG(y_v);
	if (x < 0 || y < 0 || x >= g->width || y >= g->height) {
		return Qnil;
	}
	uint32_t cp = g->cp[y * g->width + x];
	if (cp == 0) {
		return rb_enc_str_new("", 0, rb_utf8_encoding());
	}
	return rb_enc_uint_chr(cp, rb_utf8_encoding());
}

/* copy_from(other): every cell from a grid of the same size */
static VALUE grid_copy_from(VALUE self, VALUE other)
{
	struct mb_term_grid *g = get_grid(self);
	struct mb_term_grid *o = get_grid(other);
	if (g->width != o->width || g->height != o->height) {
		rb_raise(rb_eArgError, "Grid sizes differ");
	}
	size_t n = (size_t)(g->width * g->height);
	memcpy(g->cp, o->cp, n * sizeof(uint32_t));
	memcpy(g->fg, o->fg, n * sizeof(int32_t));
	memcpy(g->bg, o->bg, n * sizeof(int32_t));
	memcpy(g->attr, o->attr, n);
	return self;
}

/*
 * blit(other, x, y): copies every cell of +other+ (any size) into this grid
 * with its top left corner at 0-based (+x+, +y+), clipped to this grid.
 * Screens composite pane grids (mb-sound's Plot::Live) into their own this way, so
 * what they draw afterwards (overlays) stays on top.
 */
static VALUE grid_blit(VALUE self, VALUE other, VALUE x_v, VALUE y_v)
{
	struct mb_term_grid *g = get_grid(self);
	struct mb_term_grid *o = get_grid(other);
	long x = NUM2LONG(x_v);
	long y = NUM2LONG(y_v);
	long sx = x < 0 ? -x : 0;
	long sy = y < 0 ? -y : 0;
	long w = o->width - sx;
	long h = o->height - sy;
	if (x + sx + w > g->width) {
		w = g->width - (x + sx);
	}
	if (y + sy + h > g->height) {
		h = g->height - (y + sy);
	}
	if (w <= 0 || h <= 0) {
		return self;
	}
	for (long r = 0; r < h; r++) {
		size_t si = (size_t)((sy + r) * o->width + sx);
		size_t di = (size_t)((y + sy + r) * g->width + x + sx);
		memmove(g->cp + di, o->cp + si, (size_t)w * sizeof(uint32_t));
		memmove(g->fg + di, o->fg + si, (size_t)w * sizeof(int32_t));
		memmove(g->bg + di, o->bg + si, (size_t)w * sizeof(int32_t));
		memmove(g->attr + di, o->attr + si, (size_t)w);
	}
	return self;
}

static VALUE grid_clear(VALUE self)
{
	grid_clear_cells(get_grid(self));
	return self;
}


static const int basic16[16][3] = {
	{ 0, 0, 0 }, { 205, 49, 49 }, { 13, 188, 121 }, { 229, 229, 16 }, { 36, 114, 200 }, { 188, 63, 188 }, { 17, 168, 205 }, { 229, 229, 229 },
	{ 102, 102, 102 }, { 241, 76, 76 }, { 35, 209, 139 }, { 245, 245, 67 }, { 59, 142, 234 }, { 214, 112, 214 }, { 41, 184, 219 }, { 255, 255, 255 },
};

static inline long cdist(const int *a, const int *b)
{
	long d0 = a[0] - b[0], d1 = a[1] - b[1], d2 = a[2] - b[2];
	return d0 * d0 * 2 + d1 * d1 * 4 + d2 * d2 * 3;
}

static int index256(const int *rgb)
{
	static const int levels[6] = { 0, 95, 135, 175, 215, 255 };
	int cube[3], cube_rgb[3];
	for (int c = 0; c < 3; c++) {
		int best = 0;
		for (int l = 1; l < 6; l++) {
			if (abs(levels[l] - rgb[c]) < abs(levels[best] - rgb[c])) {
				best = l;
			}
		}
		cube[c] = best;
		cube_rgb[c] = levels[best];
	}
	double avg = (double)(rgb[0] + rgb[1] + rgb[2]) / 3.0;
	long gray = (long)round((avg - 8) / 10);
	if (gray < 0) {
		gray = 0;
	}
	if (gray > 23) {
		gray = 23;
	}
	int gray_rgb[3] = { 8 + (int)gray * 10, 8 + (int)gray * 10, 8 + (int)gray * 10 };
	if (cdist(rgb, gray_rgb) < cdist(rgb, cube_rgb)) {
		return 232 + (int)gray;
	}
	return 16 + 36 * cube[0] + 6 * cube[1] + cube[2];
}

static int nearest16(const int *rgb)
{
	int best = 0;
	long bd = cdist(rgb, basic16[0]);
	for (int i = 1; i < 16; i++) {
		long dd = cdist(rgb, basic16[i]);
		if (dd < bd) {
			bd = dd;
			best = i;
		}
	}
	return best;
}

// The [r, g, b] of xterm-256 color +n+ (MB::Term::ANSI.xterm)
static void xterm_rgb(int n, int *rgb)
{
	static const int levels[6] = { 0, 95, 135, 175, 215, 255 };
	if (n < 16) {
		for (int c = 0; c < 3; c++) {
			rgb[c] = basic16[n][c];
		}
	} else if (n < 232) {
		n -= 16;
		rgb[0] = levels[n / 36];
		rgb[1] = levels[(n / 6) % 6];
		rgb[2] = levels[n % 6];
	} else {
		int g = 8 + 10 * (n - 232);
		rgb[0] = rgb[1] = rgb[2] = g;
	}
}

enum { MODE_NONE, MODE_TRUECOLOR, MODE_ANSI256, MODE_ANSI16 };

static int append_color(char *buf, int32_t c, int mode, int bg)
{
	if (c & MB_TERM_COLOR_INDEXED) {
		int k = c & 255;
		if (k >= 16 && mode == MODE_ANSI16) {
			int rgb[3];
			xterm_rgb(k, rgb);
			k = nearest16(rgb);
		}
		if (k < 8) {
			return sprintf(buf, "%d", (bg ? 40 : 30) + k);
		}
		if (k < 16) {
			return sprintf(buf, "%d", (bg ? 100 : 90) + k - 8);
		}
		return sprintf(buf, "%d;5;%d", bg ? 48 : 38, k);
	}
	int rgb[3] = { (c >> 16) & 255, (c >> 8) & 255, c & 255 };
	switch (mode) {
	case MODE_TRUECOLOR:
		return sprintf(buf, "%d;2;%d;%d;%d", bg ? 48 : 38, rgb[0], rgb[1], rgb[2]);
	case MODE_ANSI256:
		return sprintf(buf, "%d;5;%d", bg ? 48 : 38, index256(rgb));
	default: {
		int k = nearest16(rgb);
		int base = k < 8 ? (bg ? 40 : 30) + k : (bg ? 100 : 90) + k - 8;
		return sprintf(buf, "%d", base);
	}
	}
}


static inline void ob_reserve(struct mb_term_outbuf *o, size_t extra)
{
	if (o->len + extra > o->cap) {
		size_t cap = o->cap ? o->cap * 2 : 4096;
		while (cap < o->len + extra) {
			cap *= 2;
		}
		REALLOC_N(o->p, char, cap);
		o->cap = cap;
	}
}

static inline void ob_cat(struct mb_term_outbuf *o, const char *s, size_t n)
{
	ob_reserve(o, n);
	memcpy(o->p + o->len, s, n);
	o->len += n;
}

// The SGR sequence for a style (Cells#sgr) into +buf+; returns its length
static int format_sgr(char *buf, int32_t f, int32_t b, int a, int mode)
{
	// Attributes in Cells#sgr's order: bold, dim, italic, underline, reverse
	static const struct { int bit; char code; } attrs[] = {
		{ MB_TERM_ATTR_BOLD, '1' }, { MB_TERM_ATTR_DIM, '2' }, { MB_TERM_ATTR_ITALIC, '3' }, { MB_TERM_ATTR_UNDERLINE, '4' }, { MB_TERM_ATTR_REVERSE, '7' },
	};
	int n = 0;
	int first = 1;
	buf[n++] = '\033';
	buf[n++] = '[';
	for (int k = 0; k < 5; k++) {
		if (a & attrs[k].bit) {
			if (!first) {
				buf[n++] = ';';
			}
			buf[n++] = attrs[k].code;
			first = 0;
		}
	}
	if (f >= 0) {
		if (!first) {
			buf[n++] = ';';
		}
		n += append_color(buf + n, f, mode, 0);
		first = 0;
	}
	if (b >= 0) {
		if (!first) {
			buf[n++] = ';';
		}
		n += append_color(buf + n, b, mode, 1);
	}
	buf[n++] = 'm';
	return n;
}


static struct mb_term_sgr_entry *sgr_cache_new(void)
{
	struct mb_term_sgr_entry *c = ALLOC_N(struct mb_term_sgr_entry, MB_TERM_SGR_CACHE);
	for (int i = 0; i < MB_TERM_SGR_CACHE; i++) {
		c[i].mode = -1;
	}
	return c;
}

static inline void append_sgr(struct mb_term_outbuf *o, struct mb_term_sgr_entry *cache, int32_t f, int32_t b, int a, int mode)
{
	uint32_t h = ((uint32_t)f * 2654435761u) ^ ((uint32_t)b * 40503u) ^ ((uint32_t)a << 7) ^ (uint32_t)mode;
	struct mb_term_sgr_entry *e = &cache[(h ^ (h >> 16)) & (MB_TERM_SGR_CACHE - 1)];
	if (!(e->mode == mode && e->f == f && e->b == b && e->a == a)) {
		e->f = f;
		e->b = b;
		e->a = (int16_t)a;
		e->mode = (int16_t)mode;
		e->len = (int8_t)format_sgr(e->seq, f, b, a, mode);
	}
	ob_cat(o, e->seq, (size_t)e->len);
}

// Code point 0 is the right half of a wide character: nothing is written
// for it (the terminal moved past it after the left half)
static inline void append_cp(struct mb_term_outbuf *o, uint32_t cp)
{
	if (cp == 0) {
		return;
	}
	ob_reserve(o, 4);
	char *buf = o->p + o->len;
	if (cp < 0x80) {
		buf[0] = (char)cp;
		o->len += 1;
	} else if (cp < 0x800) {
		buf[0] = (char)(0xC0 | (cp >> 6));
		buf[1] = (char)(0x80 | (cp & 0x3F));
		o->len += 2;
	} else if (cp < 0x10000) {
		buf[0] = (char)(0xE0 | (cp >> 12));
		buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
		buf[2] = (char)(0x80 | (cp & 0x3F));
		o->len += 3;
	} else {
		buf[0] = (char)(0xF0 | (cp >> 18));
		buf[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
		buf[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
		buf[3] = (char)(0x80 | (cp & 0x3F));
		o->len += 4;
	}
}

// One row as text with SGR codes (Cells#line)
static void grid_line(struct mb_term_grid *g, long y, int mode, struct mb_term_outbuf *o)
{
	long start = y * g->width;
	long stop = start + g->width;
	if (mode == MODE_NONE) {
		for (long i = start; i < stop; i++) {
			append_cp(o, g->cp[i]);
		}
		return;
	}
	if (g->sgr == NULL) {
		g->sgr = sgr_cache_new();
	}
	int styled = 0;
	int32_t pf = -1, pb = -1;
	int pa = 0;
	for (long i = start; i < stop; i++) {
		int32_t f = g->fg[i];
		int32_t b = g->bg[i];
		int a = g->attr[i];
		if (!(f == pf && b == pb && a == pa)) {
			if (styled) {
				ob_cat(o, "\033[0m", 4);
			}
			styled = !(f < 0 && b < 0 && a == 0);
			if (styled) {
				append_sgr(o, g->sgr, f, b, a, mode);
			}
			pf = f;
			pb = b;
			pa = a;
		}
		append_cp(o, g->cp[i]);
	}
	if (styled) {
		ob_cat(o, "\033[0m", 4);
	}
}

/* lines(mode): an Array of Strings, one per row; mode 0 none, 1 truecolor, 2 ansi256, 3 ansi16 */
static VALUE grid_lines(VALUE self, VALUE mode_v)
{
	struct mb_term_grid *g = get_grid(self);
	int mode = NUM2INT(mode_v);
	VALUE ary = rb_ary_new_capa(g->height);
	for (long y = 0; y < g->height; y++) {
		g->out.len = 0;
		grid_line(g, y, mode, &g->out);
		rb_ary_push(ary, rb_enc_str_new(g->out.p, (long)g->out.len, rb_utf8_encoding()));
	}
	return ary;
}

/* to_text(mode): every row joined with newlines into one String (no trailing newline) */
static VALUE grid_text(VALUE self, VALUE mode_v)
{
	struct mb_term_grid *g = get_grid(self);
	int mode = NUM2INT(mode_v);
	g->out.len = 0;
	for (long y = 0; y < g->height; y++) {
		if (y > 0) {
			ob_cat(&g->out, "\n", 1);
		}
		grid_line(g, y, mode, &g->out);
	}
	return rb_enc_str_new(g->out.p, (long)g->out.len, rb_utf8_encoding());
}

// Unchanged cells this short between changed ones are rewritten rather
// than skipped with a cursor move (FRAME_GAP in MB::Term::Cells)
#define FRAME_GAP 4

static inline int cell_changed(const struct mb_term_grid *g, const struct mb_term_grid *p, long i)
{
	return p == NULL || g->cp[i] != p->cp[i] || g->fg[i] != p->fg[i] || g->bg[i] != p->bg[i] || g->attr[i] != p->attr[i];
}

static void append_int(struct mb_term_outbuf *o, long v)
{
	char buf[24];
	int n = snprintf(buf, sizeof(buf), "%ld", v);
	ob_cat(o, buf, (size_t)n);
}

/*
 * The terminal bytes that draw grid +g+ at 1-based screen (+row+, +col+):
 * every cell (+p+ NULL) or only the cells that differ from +p+ (a grid of
 * the same size holding what the screen shows), as runs placed with
 * cursor moves (CUP), styles as SGR codes like #lines, optionally inside
 * DEC 2026 synchronized output.  Mirrored by MB::Term::Cells#frame.
 */
static void encode_frame(struct mb_term_grid *g, struct mb_term_grid *p, int mode, long row, long col, int sync, struct mb_term_outbuf *o)
{
	if (sync) {
		ob_cat(o, "\033[?2026h", 8);
	}
	if (mode != MODE_NONE) {
		ob_cat(o, "\033[0m", 4);
		if (g->sgr == NULL) {
			g->sgr = sgr_cache_new();
		}
	}
	int styled = 0;
	int32_t pf = -1, pb = -1;
	int pa = 0;
	for (long y = 0; y < g->height; y++) {
		long base = y * g->width;
		long cx = -1; // the cursor's column on this row, -1 if elsewhere
		long x = 0;
		while (x < g->width) {
			if (!cell_changed(g, p, base + x)) {
				x++;
				continue;
			}
			// A run: changed cells with gaps of at most FRAME_GAP
			long end = x + 1;
			long last = x;
			while (end < g->width) {
				if (cell_changed(g, p, base + end)) {
					last = end;
					end++;
				} else if (end - last <= FRAME_GAP) {
					end++;
				} else {
					break;
				}
			}
			end = last + 1;
			if (cx != x) {
				ob_cat(o, "\033[", 2);
				append_int(o, row + y);
				ob_cat(o, ";", 1);
				append_int(o, col + x);
				ob_cat(o, "H", 1);
			}
			for (long i = base + x; i < base + end; i++) {
				if (mode != MODE_NONE) {
					int32_t f = g->fg[i];
					int32_t b = g->bg[i];
					int a = g->attr[i];
					if (!(f == pf && b == pb && a == pa)) {
						if (styled) {
							ob_cat(o, "\033[0m", 4);
						}
						styled = !(f < 0 && b < 0 && a == 0);
						if (styled) {
							append_sgr(o, g->sgr, f, b, a, mode);
						}
						pf = f;
						pb = b;
						pa = a;
					}
				}
				append_cp(o, g->cp[i]);
			}
			cx = end;
			x = end;
		}
	}
	if (styled) {
		ob_cat(o, "\033[0m", 4);
	}
	if (sync) {
		ob_cat(o, "\033[?2026l", 8);
	}
}

static struct mb_term_grid *frame_prev(struct mb_term_grid *g, VALUE prev_v)
{
	if (NIL_P(prev_v)) {
		return NULL;
	}
	if (!rb_typeddata_is_kind_of(prev_v, &grid_type)) {
		rb_raise(rb_eTypeError, "The previous frame must be a Grid or nil");
	}
	struct mb_term_grid *p = get_grid(prev_v);
	if (p->width != g->width || p->height != g->height) {
		rb_raise(rb_eArgError, "The previous frame's size differs");
	}
	return p;
}

/* frame(prev, mode, row, col, sync) -> String (see encode_frame) */
static VALUE grid_frame(VALUE self, VALUE prev_v, VALUE mode_v, VALUE row_v, VALUE col_v, VALUE sync_v)
{
	struct mb_term_grid *g = get_grid(self);
	struct mb_term_grid *p = frame_prev(g, prev_v);
	g->out.len = 0;
	encode_frame(g, p, NUM2INT(mode_v), NUM2LONG(row_v), NUM2LONG(col_v), RTEST(sync_v), &g->out);
	return rb_enc_str_new(g->out.p, (long)g->out.len, rb_utf8_encoding());
}

struct write_job {
	struct mb_term_grid *g, *p;
	int mode, sync, fd;
	long row, col;
	int encoded;
	size_t off;
	int err;
};

// Encodes the frame (once) and writes it from j->off on.  A non-blocking
// descriptor (a terminal on macOS) returns EAGAIN when its buffer is full:
// wait for it to drain with poll() and go on.  An interrupted write or poll
// returns with err = EINTR so the caller can check Ruby interrupts
// (Ctrl-C, Thread#kill) and call again, resuming at j->off.
static void *write_frame_nogvl(void *arg)
{
	struct write_job *j = arg;
	struct mb_term_outbuf *o = &j->g->out;
	if (!j->encoded) {
		o->len = 0;
		encode_frame(j->g, j->p, j->mode, j->row, j->col, j->sync, o);
		j->encoded = 1;
		j->off = 0;
	}
	while (j->off < o->len) {
		ssize_t n = write(j->fd, o->p + j->off, o->len - j->off);
		if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				struct pollfd pfd = { .fd = j->fd, .events = POLLOUT };
				if (poll(&pfd, 1, -1) < 0 && errno != EAGAIN) {
					j->err = errno;
					return NULL;
				}
				continue;
			}
			j->err = errno;
			return NULL;
		}
		j->off += (size_t)n;
	}
	return NULL;
}

/*
 * write_frame(io, prev, mode, row, col, sync) -> bytes written: encodes the
 * frame like #frame and writes it to +io+'s file descriptor, both without
 * the GVL (the render thread runs meanwhile).  The grids must not change
 * during the call (the painter thread owns them).  The encoding buffer
 * grows outside the GVL with Ruby's xrealloc, so it is reserved first.
 */
static VALUE grid_write_frame(VALUE self, VALUE io, VALUE prev_v, VALUE mode_v, VALUE row_v, VALUE col_v, VALUE sync_v)
{
	struct mb_term_grid *g = get_grid(self);
	struct write_job j;
	j.g = g;
	j.p = frame_prev(g, prev_v);
	j.mode = NUM2INT(mode_v);
	j.row = NUM2LONG(row_v);
	j.col = NUM2LONG(col_v);
	j.sync = RTEST(sync_v);
	j.fd = rb_io_descriptor(io);
	j.encoded = 0;
	j.off = 0;
	j.err = 0;
	// The worst case: a cursor move per cell plus SGR codes, so the
	// buffer never reallocates without the GVL
	ob_reserve(&g->out, (size_t)(g->width * g->height) * (16 + 4 + 2 * 56 + 8) + 64);
	if (g->sgr == NULL) {
		g->sgr = sgr_cache_new();
	}
	rb_io_flush(io);
	for (;;) {
		j.err = 0;
		rb_thread_call_without_gvl(write_frame_nogvl, &j, RUBY_UBF_IO, NULL);
		if (j.err == EINTR) {
			// Raises if Ruby has a pending interrupt; otherwise resume
			rb_thread_check_ints();
			continue;
		}
		break;
	}
	if (j.err) {
		rb_syserr_fail(j.err, "write_frame");
	}
	return LONG2NUM((long)j.off);
}


struct mb_term_grid *mb_term_grid_get(VALUE self)
{
	return get_grid(self);
}

struct mb_term_grid *mb_term_grid_or_null(VALUE v)
{
	if (!rb_typeddata_is_kind_of(v, &grid_type)) {
		return NULL;
	}
	return get_grid(v);
}

void Init_fast_term(void)
{
#ifdef HAVE_RB_EXT_RACTOR_SAFE
	rb_ext_ractor_safe(true);
#endif
	VALUE mMB = rb_define_module("MB");
	VALUE mTerm = rb_define_module_under(mMB, "Term");
	VALUE mFastTerm = rb_define_module_under(mTerm, "FastTerm");

	cGrid = rb_define_class_under(mFastTerm, "Grid", rb_cObject);
	rb_define_alloc_func(cGrid, grid_alloc);
	rb_define_method(cGrid, "initialize", grid_initialize, 2);
	rb_define_method(cGrid, "width", grid_width, 0);
	rb_define_method(cGrid, "height", grid_height, 0);
	rb_define_method(cGrid, "set_cell", grid_set_cell, 6);
	rb_define_method(cGrid, "put_text", grid_put_text, 6);
	rb_define_method(cGrid, "put_run", grid_put_run, 6);
	rb_define_method(cGrid, "char", grid_char, 2);
	rb_define_method(cGrid, "copy_from", grid_copy_from, 1);
	rb_define_method(cGrid, "blit", grid_blit, 3);
	rb_define_method(cGrid, "clear", grid_clear, 0);
	rb_define_method(cGrid, "lines", grid_lines, 1);
	rb_define_method(cGrid, "to_text", grid_text, 1);
	rb_define_method(cGrid, "frame", grid_frame, 5);
	rb_define_method(cGrid, "write_frame", grid_write_frame, 6);

	mb_term_init_vt(mFastTerm);
}
