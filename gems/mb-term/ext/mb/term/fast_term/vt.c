/*
 * MB::Term::FastTerm::VT: mb-term's terminal model in C, the exact mirror
 * of MB::Term::RubyVT (lib/mb/term/vt.rb; MB::Term::NativeVT gives this
 * class RubyVT's keyword interface).  Every step follows the Ruby: the
 * same UTF-8 scrubbing (String#scrub's rule), printable runs, escape
 * parsing (CSI parameters are their leading digits, saturating at
 * PARAM_MAX), cursor moves, erases, insert/delete, scroll regions, the
 * alternate screen, SGR, wide characters (Reline's width table, given by
 * the Ruby side once), pending wraps, tabs, resizes, the scrollback, and
 * the replies.  Specs compare the whole state of both after captured
 * streams and random bytes (gems/mb-term/spec/vt_native_spec.rb).
 *
 * Rows: code points (0 for the right half of a wide character) and, once
 * a cell was styled, colors (packed, -1 for none) and attributes.  Rows
 * in the scrollback are trimmed to their last cell that isn't a blank
 * unstyled space (the cells after it are such blanks), so 10 000 lines
 * of short output take little memory.
 *
 * Nothing here releases the GVL or calls Ruby code while it holds a
 * pointer to a row (VT#draw into a Ruby grid builds each row's runs as
 * Ruby values before calling #put_run), so other threads can't change
 * rows under it.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <ruby.h>
#include <ruby/encoding.h>

#include "fast_term.h"

// The largest CSI parameter (VT::PARAM_MAX) and sync mark (VT::MARK_MAX)
#define VT_PARAM_MAX 65535L
#define VT_MARK_MAX ((1LL << 62) - 1)

// Size limits (far above any terminal's)
#define VT_MAX_SIDE 100000L
#define VT_MAX_CELLS 10000000L

#define VT_BOLD 1
#define VT_REVERSE 2
#define VT_UNDERLINE 4
#define VT_ITALIC 8
#define VT_DIM 16

static VALUE cVT;
static VALUE cRow = Qnil; // MB::Term::VT::Row (looked up on first use)
static ID id_build, id_put_run, id_to_a;

// Reline's East Asian width table (Reline::Unicode::EastAsianWidth's
// CHUNK_LAST and CHUNK_WIDTH), set by VT.width_table= before any VT feeds
static long *wt_last;
static int *wt_width;
static long wt_len;

struct vt_buf {
	char *p;
	long len, cap;
};

struct vt_row {
	uint32_t *cp;      // n code points
	int32_t *fg, *bg;  // n packed colors (-1: none), or NULL while plain
	uint8_t *attr;     // n attribute sets, or NULL while plain
	long len;          // cells
	long n;            // cells stored (cells n...len are unstyled spaces)
	unsigned char styled, wrapped;
};

// A saved cursor (DECSC, CSI s, ?1049)
struct vt_saved {
	int has;
	long row, col;
	int32_t fg, bg;
	long attr;
	int origin, wrap_pending;
};

struct vt {
	long rows, cols;
	long max_scrollback;
	long ambiguous_width;

	struct vt_row **main;
	struct vt_row **alt; // NULL when the main screen shows

	struct vt_row **sb; // the scrollback, a ring
	long sb_cap, sb_head, sb_len;

	long dropped, scrolled;
	long long bytes_fed, sync_mark;

	long row, col, top, bottom;
	int wrap_pending;
	int32_t fg, bg;
	long attr;
	struct vt_saved saved, saved_main;
	int origin, autowrap, cursor_visible, bracketed_paste, app_cursor;

	uint8_t *tabs;  // cols: 1 where a tab stop is
	uint8_t *dirty; // rows
	int all_dirty;

	struct vt_buf replies, pending, title;
	int has_title;

	// Work buffers (reused)
	struct vt_buf data;
	uint32_t *cps;
	long cps_cap;
	long *nums;
	long nums_cap;
};

/* Buffers */

static void buf_reserve(struct vt_buf *b, long extra)
{
	if (b->len + extra <= b->cap) {
		return;
	}
	long cap = b->cap ? b->cap : 64;
	while (cap < b->len + extra) {
		cap *= 2;
	}
	REALLOC_N(b->p, char, cap);
	b->cap = cap;
}

static void buf_cat(struct vt_buf *b, const char *s, long n)
{
	if (n <= 0) {
		return;
	}
	buf_reserve(b, n);
	memcpy(b->p + b->len, s, (size_t)n);
	b->len += n;
}

static void buf_utf8(struct vt_buf *b, uint32_t cp)
{
	char t[4];
	long n;
	if (cp < 0x80) {
		t[0] = (char)cp;
		n = 1;
	} else if (cp < 0x800) {
		t[0] = (char)(0xC0 | (cp >> 6));
		t[1] = (char)(0x80 | (cp & 0x3F));
		n = 2;
	} else if (cp < 0x10000) {
		t[0] = (char)(0xE0 | (cp >> 12));
		t[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
		t[2] = (char)(0x80 | (cp & 0x3F));
		n = 3;
	} else {
		t[0] = (char)(0xF0 | (cp >> 18));
		t[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
		t[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
		t[3] = (char)(0x80 | (cp & 0x3F));
		n = 4;
	}
	buf_cat(b, t, n);
}

static void buf_free(struct vt_buf *b)
{
	xfree(b->p);
	b->p = NULL;
	b->len = b->cap = 0;
}

static VALUE utf8_str(const char *p, long n)
{
	return rb_enc_str_new(p, n, rb_utf8_encoding());
}

/* Rows */

static inline long clampl(long v, long lo, long hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

static struct vt_row *row_new(long cols)
{
	struct vt_row *r = ZALLOC(struct vt_row);
	r->len = r->n = cols;
	r->cp = ALLOC_N(uint32_t, cols > 0 ? cols : 1);
	for (long c = 0; c < cols; c++) {
		r->cp[c] = ' ';
	}
	return r;
}

static void row_free(struct vt_row *r)
{
	if (r == NULL) {
		return;
	}
	xfree(r->cp);
	xfree(r->fg);
	xfree(r->bg);
	xfree(r->attr);
	xfree(r);
}

// RubyVT::Row#styles: per-cell styles from now on
static void row_ensure_styles(struct vt_row *r)
{
	if (r->styled) {
		return;
	}
	r->styled = 1;
	if (r->n == 0) {
		return;
	}
	r->fg = ALLOC_N(int32_t, r->n);
	r->bg = ALLOC_N(int32_t, r->n);
	r->attr = ALLOC_N(uint8_t, r->n);
	for (long c = 0; c < r->n; c++) {
		r->fg[c] = -1;
		r->bg[c] = -1;
		r->attr[c] = 0;
	}
}

static void row_fill_styles(struct vt_row *r, long from, long n, int32_t fg, int32_t bg, long attr)
{
	for (long c = from; c < from + n; c++) {
		r->fg[c] = fg;
		r->bg[c] = bg;
		r->attr[c] = (uint8_t)attr;
	}
}

static inline uint32_t row_cp(const struct vt_row *r, long c)
{
	return c < r->n ? r->cp[c] : ' ';
}

static inline int32_t row_fg(const struct vt_row *r, long c)
{
	return r->styled && c < r->n ? r->fg[c] : -1;
}

static inline int32_t row_bg(const struct vt_row *r, long c)
{
	return r->styled && c < r->n ? r->bg[c] : -1;
}

static inline long row_attr(const struct vt_row *r, long c)
{
	return r->styled && c < r->n ? r->attr[c] : 0;
}

// Row#write: +k+ code points from cell +c+ in one style
static void row_write(struct vt_row *r, long c, const uint32_t *cps, long k, int32_t fg, int32_t bg, long attr)
{
	if (c < 0 || k <= 0) {
		return;
	}
	if (c + k > r->n) {
		k = r->n - c; // (never: the VT keeps writes inside the row)
	}
	if (k <= 0) {
		return;
	}
	memcpy(r->cp + c, cps, (size_t)k * sizeof(uint32_t));
	if (r->styled || fg != -1 || bg != -1 || attr != 0) {
		row_ensure_styles(r);
		row_fill_styles(r, c, k, fg, bg, attr);
	}
}

// Row#blank: cells from...to blank, background +bg+
static void row_blank(struct vt_row *r, long from, long to, int32_t bg)
{
	if (to <= from) {
		return;
	}
	from = clampl(from, 0, r->n);
	to = clampl(to, 0, r->n);
	for (long c = from; c < to; c++) {
		r->cp[c] = ' ';
	}
	if (!(r->styled || bg != -1)) {
		return;
	}
	row_ensure_styles(r);
	row_fill_styles(r, from, to - from, -1, bg, 0);
}

// Row#delete: +k+ cells at +c+ out, blanks with background +bg+ in at the end
static void row_delete(struct vt_row *r, long c, long k, int32_t bg)
{
	long n = r->n;
	if (c < 0 || c >= n || k <= 0) {
		return;
	}
	if (k > n - c) {
		k = n - c;
	}
	long rest = n - c - k;
	memmove(r->cp + c, r->cp + c + k, (size_t)rest * sizeof(uint32_t));
	for (long i = n - k; i < n; i++) {
		r->cp[i] = ' ';
	}
	if (r->styled || bg != -1) {
		row_ensure_styles(r);
		memmove(r->fg + c, r->fg + c + k, (size_t)rest * sizeof(int32_t));
		memmove(r->bg + c, r->bg + c + k, (size_t)rest * sizeof(int32_t));
		memmove(r->attr + c, r->attr + c + k, (size_t)rest);
		row_fill_styles(r, n - k, k, -1, bg, 0);
	}
}

// Row#insert: +k+ blank cells at +c+, the rest shifted right (cut)
static void row_insert(struct vt_row *r, long c, long k, int32_t bg)
{
	long n = r->n;
	if (c < 0 || c >= n || k <= 0) {
		return;
	}
	if (k > n - c) {
		k = n - c;
	}
	long rest = n - c - k;
	memmove(r->cp + c + k, r->cp + c, (size_t)rest * sizeof(uint32_t));
	for (long i = c; i < c + k; i++) {
		r->cp[i] = ' ';
	}
	if (r->styled || bg != -1) {
		row_ensure_styles(r);
		memmove(r->fg + c + k, r->fg + c, (size_t)rest * sizeof(int32_t));
		memmove(r->bg + c + k, r->bg + c, (size_t)rest * sizeof(int32_t));
		memmove(r->attr + c + k, r->attr + c, (size_t)rest);
		row_fill_styles(r, c, k, -1, bg, 0);
	}
}

// Stores +n+ cells (cut, or padded with unstyled spaces)
static void row_store(struct vt_row *r, long n)
{
	long old = r->n;
	if (n == old) {
		return;
	}
	if (n == 0) {
		xfree(r->cp);
		xfree(r->fg);
		xfree(r->bg);
		xfree(r->attr);
		r->cp = NULL;
		r->fg = r->bg = NULL;
		r->attr = NULL;
		r->n = 0;
		return;
	}
	REALLOC_N(r->cp, uint32_t, n);
	for (long c = old; c < n; c++) {
		r->cp[c] = ' ';
	}
	if (r->styled) {
		REALLOC_N(r->fg, int32_t, n);
		REALLOC_N(r->bg, int32_t, n);
		REALLOC_N(r->attr, uint8_t, n);
		if (n > old) {
			row_fill_styles(r, old, n - old, -1, -1, 0);
		}
	}
	r->n = n;
}

// Row#resize of a screen row (every cell stored)
static void row_resize(struct vt_row *r, long cols)
{
	if (cols < r->n) {
		int half = r->cp[cols] == 0;
		row_store(r, cols);
		if (half) {
			r->cp[cols - 1] = ' '; // a wide character whose right half was cut
		}
	} else {
		row_store(r, cols);
	}
	r->len = cols;
}

// Drops the trailing unstyled spaces' storage (scrollback rows)
static void row_trim(struct vt_row *r)
{
	long last = r->n - 1;
	while (last >= 0 && r->cp[last] == ' ' && (!r->styled || (r->fg[last] == -1 && r->bg[last] == -1 && r->attr[last] == 0))) {
		last--;
	}
	row_store(r, last + 1);
}

/* The VT */

static void vt_free_rows(struct vt_row **rows, long n)
{
	if (rows == NULL) {
		return;
	}
	for (long i = 0; i < n; i++) {
		row_free(rows[i]);
	}
	xfree(rows);
}

static struct vt_row **vt_new_screen(long rows, long cols)
{
	struct vt_row **s = ALLOC_N(struct vt_row *, rows);
	for (long i = 0; i < rows; i++) {
		s[i] = row_new(cols);
	}
	return s;
}

static void sb_clear(struct vt *v)
{
	for (long i = 0; i < v->sb_len; i++) {
		row_free(v->sb[(v->sb_head + i) % v->sb_cap]);
	}
	v->sb_len = 0;
	v->sb_head = 0;
}

static void vt_free(void *p)
{
	struct vt *v = p;
	vt_free_rows(v->main, v->rows);
	vt_free_rows(v->alt, v->rows);
	if (v->sb) {
		sb_clear(v);
		xfree(v->sb);
	}
	xfree(v->tabs);
	xfree(v->dirty);
	buf_free(&v->replies);
	buf_free(&v->pending);
	buf_free(&v->title);
	buf_free(&v->data);
	xfree(v->cps);
	xfree(v->nums);
	xfree(v);
}

static size_t row_memsize(const struct vt_row *r)
{
	return sizeof(*r) + (size_t)r->n * (r->styled ? 13 : 4);
}

static size_t vt_memsize(const void *p)
{
	const struct vt *v = p;
	size_t s = sizeof(*v) + (size_t)(v->cols + v->rows) + (size_t)(v->replies.cap + v->pending.cap + v->title.cap + v->data.cap);
	s += (size_t)v->cps_cap * 4 + (size_t)v->nums_cap * sizeof(long) + (size_t)v->sb_cap * sizeof(void *);
	for (long i = 0; v->main && i < v->rows; i++) {
		s += row_memsize(v->main[i]);
	}
	for (long i = 0; v->alt && i < v->rows; i++) {
		s += row_memsize(v->alt[i]);
	}
	for (long i = 0; i < v->sb_len; i++) {
		s += row_memsize(v->sb[(v->sb_head + i) % v->sb_cap]);
	}
	return s;
}

static const rb_data_type_t vt_type = {
	.wrap_struct_name = "MB::Term::FastTerm::VT",
	.function = { .dmark = NULL, .dfree = vt_free, .dsize = vt_memsize },
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE vt_alloc(VALUE klass)
{
	struct vt *v = ZALLOC(struct vt);
	return TypedData_Wrap_Struct(klass, &vt_type, v);
}

static struct vt *get_vt(VALUE self)
{
	struct vt *v;
	TypedData_Get_Struct(self, struct vt, &vt_type, v);
	if (v->main == NULL) {
		rb_raise(rb_eRuntimeError, "VT not initialized");
	}
	return v;
}

static void default_tabs(struct vt *v)
{
	REALLOC_N(v->tabs, uint8_t, v->cols);
	for (long c = 0; c < v->cols; c++) {
		v->tabs[c] = c % 8 == 0 && c > 0;
	}
}

static void reset_state(struct vt *v)
{
	v->row = v->col = 0;
	v->top = 0;
	v->bottom = v->rows - 1;
	v->wrap_pending = 0;
	v->fg = v->bg = -1;
	v->attr = 0;
	v->saved.has = 0;
	v->origin = 0;
	v->autowrap = 1;
	v->cursor_visible = 1;
	v->bracketed_paste = 0;
	v->app_cursor = 0;
	default_tabs(v);
}

static void check_size(long rows, long cols)
{
	if (rows > VT_MAX_SIDE || cols > VT_MAX_SIDE || rows * cols > VT_MAX_CELLS) {
		rb_raise(rb_eArgError, "A VT of %ldx%ld cells is too large", rows, cols);
	}
}

/* initialize(rows, cols, scrollback, ambiguous_width): NativeVT#initialize checks its arguments first */
static VALUE vt_initialize(VALUE self, VALUE rows_v, VALUE cols_v, VALUE sb_v, VALUE aw_v)
{
	struct vt *v;
	TypedData_Get_Struct(self, struct vt, &vt_type, v);
	if (v->main) {
		rb_raise(rb_eRuntimeError, "VT already initialized");
	}
	long rows = NUM2LONG(rows_v);
	long cols = NUM2LONG(cols_v);
	long sb = NUM2LONG(sb_v);
	long aw = NUM2LONG(aw_v);
	if (rows < 1 || cols < 1) {
		rb_raise(rb_eArgError, "A VT needs at least 1x1 cells (got %ldx%ld)", rows, cols);
	}
	check_size(rows, cols);
	v->rows = rows;
	v->cols = cols;
	v->max_scrollback = sb;
	v->ambiguous_width = aw;
	v->main = vt_new_screen(rows, cols);
	v->dirty = ALLOC_N(uint8_t, rows);
	memset(v->dirty, 1, (size_t)rows);
	v->all_dirty = 1;
	reset_state(v);
	return self;
}

static inline struct vt_row **screen(struct vt *v)
{
	return v->alt ? v->alt : v->main;
}

static inline void mark(struct vt *v, long r)
{
	if (r >= 0 && r < v->rows) {
		v->dirty[r] = 1;
	}
}

static long width_of(struct vt *v, uint32_t o)
{
	if (o < 0x7F) {
		return 1;
	}
	long lo = 0, hi = wt_len; // the first chunk whose last code point is >= o
	while (lo < hi) {
		long mid = lo + (hi - lo) / 2;
		if ((long)o <= wt_last[mid]) {
			hi = mid;
		} else {
			lo = mid + 1;
		}
	}
	long size = lo < wt_len ? wt_width[lo] : 1;
	return size == -1 ? v->ambiguous_width : size;
}

static void push_scrollback(struct vt *v, struct vt_row *r)
{
	if (v->max_scrollback <= 0) {
		row_free(r);
		return;
	}
	row_trim(r);
	if (v->sb_len == v->max_scrollback) {
		row_free(v->sb[v->sb_head]);
		v->sb[v->sb_head] = r;
		v->sb_head = (v->sb_head + 1) % v->sb_cap;
		v->dropped++;
		return;
	}
	if (v->sb_len == v->sb_cap) {
		long cap = v->sb_cap ? v->sb_cap * 2 : 64;
		if (cap > v->max_scrollback) {
			cap = v->max_scrollback;
		}
		struct vt_row **s = ALLOC_N(struct vt_row *, cap);
		for (long i = 0; i < v->sb_len; i++) {
			s[i] = v->sb[(v->sb_head + i) % v->sb_cap];
		}
		xfree(v->sb);
		v->sb = s;
		v->sb_cap = cap;
		v->sb_head = 0;
	}
	v->sb[(v->sb_head + v->sb_len) % v->sb_cap] = r;
	v->sb_len++;
}

static void scroll_up(struct vt *v, long n)
{
	struct vt_row **scr = screen(v);
	if (n > v->bottom - v->top + 1) {
		n = v->bottom - v->top + 1;
	}
	for (long k = 0; k < n; k++) {
		struct vt_row *gone = scr[v->top];
		memmove(scr + v->top, scr + v->top + 1, (size_t)(v->bottom - v->top) * sizeof(*scr));
		scr[v->bottom] = row_new(v->cols);
		if (v->top == 0 && v->alt == NULL) {
			push_scrollback(v, gone);
			v->scrolled++;
		} else {
			row_free(gone);
		}
	}
	v->all_dirty = 1;
}

static void scroll_down(struct vt *v, long n)
{
	struct vt_row **scr = screen(v);
	if (n > v->bottom - v->top + 1) {
		n = v->bottom - v->top + 1;
	}
	for (long k = 0; k < n; k++) {
		row_free(scr[v->bottom]);
		memmove(scr + v->top + 1, scr + v->top, (size_t)(v->bottom - v->top) * sizeof(*scr));
		scr[v->top] = row_new(v->cols);
	}
	v->all_dirty = 1;
}

static void index_down(struct vt *v)
{
	if (v->row == v->bottom) {
		scroll_up(v, 1);
	} else if (v->row < v->rows - 1) {
		v->row++;
	}
}

static void wrap_now(struct vt *v)
{
	v->wrap_pending = 0;
	screen(v)[v->row]->wrapped = 1;
	v->col = 0;
	index_down(v);
}

static inline void blank_cell(struct vt *v, long r, long c)
{
	row_blank(screen(v)[r], c, c + 1, -1);
}

static void put_char(struct vt *v, uint32_t cp)
{
	long w = width_of(v, cp);
	if (w == 0) {
		return; // combining marks and zero-width characters are dropped
	}
	if (w > 2 || w < 0) {
		w = 1;
	}
	if (w == 2 && v->cols < 2) {
		return;
	}
	if (v->wrap_pending) {
		wrap_now(v);
	}
	if (w == 2 && v->col == v->cols - 1) {
		if (v->autowrap) {
			blank_cell(v, v->row, v->col);
			screen(v)[v->row]->wrapped = 1;
			v->col = 0;
			index_down(v);
		} else {
			return;
		}
	}
	struct vt_row *r = screen(v)[v->row];
	if (r->cp[v->col] == 0 && v->col > 0) {
		blank_cell(v, v->row, v->col - 1);
	}
	if (v->col + w < v->cols && r->cp[v->col + w] == 0) {
		blank_cell(v, v->row, v->col + w);
	}
	row_write(r, v->col, &cp, 1, v->fg, v->bg, v->attr);
	if (w == 2) {
		uint32_t half = 0;
		row_write(r, v->col + 1, &half, 1, v->fg, v->bg, v->attr);
	}
	mark(v, v->row);
	if (v->col + w >= v->cols) {
		v->col = v->cols - 1;
		v->wrap_pending = v->autowrap;
	} else {
		v->col += w;
	}
}

// Printable text at the cursor (a run between controls)
static void put_text(struct vt *v, const uint32_t *s, long len)
{
	int ascii = 1;
	for (long i = 0; i < len; i++) {
		if (s[i] >= 0x80) {
			ascii = 0;
			break;
		}
	}
	if (!ascii) {
		for (long i = 0; i < len; i++) {
			put_char(v, s[i]);
		}
		return;
	}
	struct vt_row **scr = screen(v);
	long pos = 0;
	while (pos < len) {
		if (v->wrap_pending) {
			wrap_now(v);
		}
		long room = v->cols - v->col;
		long n = room < len - pos ? room : len - pos;
		struct vt_row *r = scr[v->row];
		if (v->col > 0 && r->cp[v->col] == 0) {
			blank_cell(v, v->row, v->col - 1);
		}
		if (v->col + n < v->cols && r->cp[v->col + n] == 0) {
			blank_cell(v, v->row, v->col + n);
		}
		row_write(r, v->col, s + pos, n, v->fg, v->bg, v->attr);
		mark(v, v->row);
		pos += n;
		if (v->col + n >= v->cols) {
			v->col = v->cols - 1;
			v->wrap_pending = v->autowrap;
		} else {
			v->col += n;
		}
	}
}

static void control(struct vt *v, uint32_t o)
{
	switch (o) {
	case 0x0A:
	case 0x0B:
	case 0x0C:
		v->wrap_pending = 0;
		screen(v)[v->row]->wrapped = 0;
		index_down(v);
		break;
	case 0x0D:
		v->wrap_pending = 0;
		v->col = 0;
		break;
	case 0x08:
		v->wrap_pending = 0;
		if (v->col > 0) {
			v->col--;
		}
		break;
	case 0x09: {
		long t = v->cols - 1;
		for (long c = v->col + 1; c < v->cols; c++) {
			if (v->tabs[c]) {
				t = c;
				break;
			}
		}
		v->col = clampl(t, 0, v->cols - 1);
		break;
	}
	default:
		break; // BEL, NUL, SO, SI, and the rest: ignored
	}
}

static void save_cursor(struct vt *v, struct vt_saved *s)
{
	s->has = 1;
	s->row = v->row;
	s->col = v->col;
	s->fg = v->fg;
	s->bg = v->bg;
	s->attr = v->attr;
	s->origin = v->origin;
	s->wrap_pending = v->wrap_pending;
}

static void load_cursor(struct vt *v, const struct vt_saved *s)
{
	v->row = clampl(s->row, 0, v->rows - 1);
	v->col = clampl(s->col, 0, v->cols - 1);
	v->fg = s->fg;
	v->bg = s->bg;
	v->attr = s->attr;
	v->origin = s->origin;
	v->wrap_pending = s->wrap_pending;
}

static void restore_cursor(struct vt *v)
{
	if (v->saved.has) {
		load_cursor(v, &v->saved);
	} else {
		v->row = v->col = 0;
	}
}

static long long leading_int(const uint32_t *s, long n, long long max)
{
	long long x = 0;
	for (long i = 0; i < n; i++) {
		if (s[i] < '0' || s[i] > '9') {
			break;
		}
		x = x * 10 + (long long)(s[i] - '0');
		if (x >= max) {
			return max;
		}
	}
	return x;
}

static void reply(struct vt *v, const char *s)
{
	buf_cat(&v->replies, s, (long)strlen(s));
}

static void alt_screen(struct vt *v, int on, int save)
{
	if (on && v->alt == NULL) {
		if (save) {
			save_cursor(v, &v->saved_main);
		}
		v->alt = vt_new_screen(v->rows, v->cols);
	} else if (!on && v->alt) {
		vt_free_rows(v->alt, v->rows);
		v->alt = NULL;
		if (save && v->saved_main.has) {
			load_cursor(v, &v->saved_main);
		}
	}
	v->all_dirty = 1;
}

static void set_row(struct vt *v, long r)
{
	v->wrap_pending = 0;
	v->row = v->origin ? clampl(v->top + r - 1, v->top, v->bottom) : clampl(r - 1, 0, v->rows - 1);
}

static void erase_line(struct vt *v, long mode)
{
	struct vt_row *r = screen(v)[v->row];
	if (mode == 0) {
		row_blank(r, v->col, v->cols, v->bg);
	} else if (mode == 1) {
		row_blank(r, 0, v->col + 1, v->bg);
	} else {
		row_blank(r, 0, v->cols, v->bg);
	}
	if (mode != 1) {
		r->wrapped = 0;
	}
	v->wrap_pending = 0;
	mark(v, v->row);
}

static void erase_display(struct vt *v, long mode)
{
	struct vt_row **scr = screen(v);
	if (mode == 0) {
		erase_line(v, 0);
		for (long r = v->row + 1; r < v->rows; r++) {
			row_blank(scr[r], 0, v->cols, v->bg);
			scr[r]->wrapped = 0;
		}
	} else if (mode == 1) {
		erase_line(v, 1);
		for (long r = 0; r < v->row; r++) {
			row_blank(scr[r], 0, v->cols, v->bg);
			scr[r]->wrapped = 0;
		}
	} else if (mode == 2) {
		for (long r = 0; r < v->rows; r++) {
			row_blank(scr[r], 0, v->cols, v->bg);
			scr[r]->wrapped = 0;
		}
	} else if (mode == 3) {
		v->dropped += v->sb_len;
		sb_clear(v);
	}
	v->all_dirty = 1;
}

static void insert_lines(struct vt *v, long n)
{
	if (v->row < v->top || v->row > v->bottom) {
		return;
	}
	struct vt_row **scr = screen(v);
	if (n > v->bottom - v->row + 1) {
		n = v->bottom - v->row + 1;
	}
	for (long k = 0; k < n; k++) {
		row_free(scr[v->bottom]);
		memmove(scr + v->row + 1, scr + v->row, (size_t)(v->bottom - v->row) * sizeof(*scr));
		scr[v->row] = row_new(v->cols);
	}
	v->col = 0;
	v->all_dirty = 1;
}

static void delete_lines(struct vt *v, long n)
{
	if (v->row < v->top || v->row > v->bottom) {
		return;
	}
	struct vt_row **scr = screen(v);
	if (n > v->bottom - v->row + 1) {
		n = v->bottom - v->row + 1;
	}
	for (long k = 0; k < n; k++) {
		row_free(scr[v->row]);
		memmove(scr + v->row, scr + v->row + 1, (size_t)(v->bottom - v->row) * sizeof(*scr));
		scr[v->bottom] = row_new(v->cols);
	}
	v->col = 0;
	v->all_dirty = 1;
}

// A parsed parameter: -1 for an empty one (nil in the Ruby)
static inline long num_at(const struct vt *v, long count, long k)
{
	return k < count ? v->nums[k] : -1;
}

static void sgr(struct vt *v, long count)
{
	static const long basic[8] = { 0, VT_BOLD, VT_DIM, VT_ITALIC, VT_UNDERLINE, 0, 0, VT_REVERSE };
	if (count == 0) {
		v->fg = v->bg = -1;
		v->attr = 0;
		return;
	}
	long k = 0;
	while (k < count) {
		long c = v->nums[k];
		if (c < 0) {
			c = 0;
		}
		if (c == 0) {
			v->fg = v->bg = -1;
			v->attr = 0;
		} else if (c == 1 || c == 2 || c == 3 || c == 4 || c == 7) {
			v->attr |= basic[c];
		} else if (c == 21) {
			v->attr &= ~VT_BOLD;
		} else if (c == 22) {
			v->attr &= ~(VT_BOLD | VT_DIM);
		} else if (c == 23) {
			v->attr &= ~VT_ITALIC;
		} else if (c == 24) {
			v->attr &= ~VT_UNDERLINE;
		} else if (c == 27) {
			v->attr &= ~VT_REVERSE;
		} else if (c >= 30 && c <= 37) {
			v->fg = MB_TERM_COLOR_INDEXED | (int32_t)(c - 30);
		} else if (c == 39) {
			v->fg = -1;
		} else if (c >= 40 && c <= 47) {
			v->bg = MB_TERM_COLOR_INDEXED | (int32_t)(c - 40);
		} else if (c == 49) {
			v->bg = -1;
		} else if (c >= 90 && c <= 97) {
			v->fg = MB_TERM_COLOR_INDEXED | (int32_t)(c - 90 + 8);
		} else if (c >= 100 && c <= 107) {
			v->bg = MB_TERM_COLOR_INDEXED | (int32_t)(c - 100 + 8);
		} else if (c == 38 || c == 48) {
			// (the Ruby's extended: nil arguments read as 0)
			long kind = num_at(v, count, k + 1);
			int32_t color = -1;
			long used = 0;
			if (kind == 5) {
				long i = num_at(v, count, k + 2);
				color = MB_TERM_COLOR_INDEXED | (int32_t)((i < 0 ? 0 : i) & 255);
				used = 2;
			} else if (kind == 2) {
				long r = clampl(num_at(v, count, k + 2), 0, 255);
				long g = clampl(num_at(v, count, k + 3), 0, 255);
				long b = clampl(num_at(v, count, k + 4), 0, 255);
				color = (int32_t)((r << 16) | (g << 8) | b);
				used = 4;
			}
			if (c == 38) {
				v->fg = color;
			} else {
				v->bg = color;
			}
			k += used;
		}
		k++;
	}
}

static int is_lead(uint32_t c)
{
	return c == '?' || c == '>' || c == '<' || c == '=';
}

static void private_csi(struct vt *v, uint32_t lead, const uint32_t *p, long n, uint32_t final)
{
	char t[64];
	if (lead == '?' && final == 'p' && n > 0 && p[n - 1] == '$') {
		long m = (long)leading_int(p, n, VT_PARAM_MAX);
		int val;
		switch (m) {
		case 1: val = v->app_cursor ? 1 : 2; break;
		case 6: val = v->origin ? 1 : 2; break;
		case 7: val = v->autowrap ? 1 : 2; break;
		case 25: val = v->cursor_visible ? 1 : 2; break;
		case 1049:
		case 47:
		case 1047: val = v->alt ? 1 : 2; break;
		case 2004: val = v->bracketed_paste ? 1 : 2; break;
		default: val = 0; break;
		}
		snprintf(t, sizeof(t), "\033[?%ld;%d$y", m, val);
		reply(v, t);
		return;
	}
	if (lead == '>' && final == 'c') {
		reply(v, "\033[>0;0;0c");
		return;
	}
	if (!(lead == '?' && (final == 'h' || final == 'l'))) {
		return;
	}
	int on = final == 'h';
	long start = 0;
	for (long i = 0; i <= n; i++) {
		if (i < n && p[i] != ';') {
			continue;
		}
		long m = (long)leading_int(p + start, i - start, VT_PARAM_MAX);
		start = i + 1;
		switch (m) {
		case 1: v->app_cursor = on; break;
		case 6:
			v->origin = on;
			v->row = on ? v->top : 0;
			v->col = 0;
			break;
		case 7: v->autowrap = on; break;
		case 25: v->cursor_visible = on; break;
		case 2004: v->bracketed_paste = on; break;
		case 47:
		case 1047:
		case 1049: alt_screen(v, on, m == 1049); break;
		default: break;
		}
	}
}

static void csi(struct vt *v, const uint32_t *p, long n, uint32_t final)
{
	char t[64];
	if (n > 0 && is_lead(p[0])) {
		private_csi(v, p[0], p + 1, n - 1, final);
		return;
	}
	if (n > 0 && (p[n - 1] == ' ' || p[n - 1] == '$' || p[n - 1] == '"' || p[n - 1] == '\'')) {
		return; // DECSCUSR, DECSCA, ...: ignored
	}

	// Parameters split at ';' (none for an empty string), -1 for empty ones
	long count = 0;
	if (n > 0) {
		long need = 1;
		for (long i = 0; i < n; i++) {
			need += p[i] == ';';
		}
		if (need > v->nums_cap) {
			REALLOC_N(v->nums, long, need);
			v->nums_cap = need;
		}
		long start = 0;
		for (long i = 0; i <= n; i++) {
			if (i < n && p[i] != ';') {
				continue;
			}
			v->nums[count++] = i == start ? -1 : (long)leading_int(p + start, i - start, VT_PARAM_MAX);
			start = i + 1;
		}
	}
	long n0 = num_at(v, count, 0);
	long n1 = num_at(v, count, 1);
	long k = n0 < 0 ? 1 : n0;
	if (k < 1) {
		k = 1;
	}

	switch (final) {
	case 'A': {
		long lim = v->row >= v->top ? v->top : 0;
		v->row = v->row - k > lim ? v->row - k : lim;
		v->wrap_pending = 0;
		break;
	}
	case 'B':
	case 'e': {
		long lim = v->row <= v->bottom ? v->bottom : v->rows - 1;
		v->row = v->row + k < lim ? v->row + k : lim;
		v->wrap_pending = 0;
		break;
	}
	case 'C':
	case 'a':
		v->col = v->col + k < v->cols - 1 ? v->col + k : v->cols - 1;
		v->wrap_pending = 0;
		break;
	case 'D':
		v->col = v->col - k > 0 ? v->col - k : 0;
		v->wrap_pending = 0;
		break;
	case 'E':
		v->row = v->row + k < v->bottom ? v->row + k : v->bottom;
		v->col = 0;
		v->wrap_pending = 0;
		break;
	case 'F':
		v->row = v->row - k > v->top ? v->row - k : v->top;
		v->col = 0;
		v->wrap_pending = 0;
		break;
	case 'G':
	case '`':
		v->col = clampl(k - 1, 0, v->cols - 1);
		v->wrap_pending = 0;
		break;
	case 'd':
		set_row(v, k);
		break;
	case 'H':
	case 'f':
		set_row(v, n0 < 0 ? 1 : n0);
		v->col = clampl((n1 < 0 ? 1 : n1) - 1, 0, v->cols - 1);
		break;
	case 'J':
		erase_display(v, n0 < 0 ? 0 : n0);
		break;
	case 'K':
		erase_line(v, n0 < 0 ? 0 : n0);
		break;
	case 'X': {
		long e = k < v->cols - v->col ? k : v->cols - v->col;
		row_blank(screen(v)[v->row], v->col, v->col + e, v->bg);
		mark(v, v->row);
		break;
	}
	case 'P':
		row_delete(screen(v)[v->row], v->col, k < v->cols - v->col ? k : v->cols - v->col, v->bg);
		v->wrap_pending = 0;
		mark(v, v->row);
		break;
	case '@':
		row_insert(screen(v)[v->row], v->col, k < v->cols - v->col ? k : v->cols - v->col, v->bg);
		v->wrap_pending = 0;
		mark(v, v->row);
		break;
	case 'L':
		insert_lines(v, k);
		break;
	case 'M':
		delete_lines(v, k);
		break;
	case 'S':
		scroll_up(v, k);
		break;
	case 'T':
		scroll_down(v, k);
		break;
	case 'r': {
		// (0 or empty: the default, as xterm reads them)
		long tp = (n0 <= 0 ? 1 : n0) - 1;
		long bt = (n1 <= 0 ? v->rows : n1) - 1;
		if (bt >= v->rows) {
			bt = v->rows - 1;
		}
		if (tp < bt) {
			v->top = tp;
			v->bottom = bt;
			v->row = v->origin ? v->top : 0;
			v->col = 0;
			v->wrap_pending = 0;
		}
		break;
	}
	case 'm':
		sgr(v, count);
		break;
	case 'n':
		if (n0 == 5) {
			reply(v, "\033[0n");
		} else if (n0 == 6) {
			long r = v->origin ? v->row - v->top + 1 : v->row + 1;
			snprintf(t, sizeof(t), "\033[%ld;%ldR", r, v->col + 1);
			reply(v, t);
		}
		break;
	case 'c':
		if (n0 <= 0) {
			reply(v, "\033[?62;22c");
		}
		break;
	case 's':
		save_cursor(v, &v->saved);
		break;
	case 'u':
		restore_cursor(v);
		break;
	case 'g': {
		long m = n0 < 0 ? 0 : n0;
		if (m == 0) {
			v->tabs[v->col] = 0;
		} else if (m == 3) {
			memset(v->tabs, 0, (size_t)v->cols);
		}
		break;
	}
	default:
		break; // ANSI modes (insert mode), window ops, LEDs, the rest: ignored
	}
}

static void osc(struct vt *v, const uint32_t *b, long n)
{
	long semi = -1;
	for (long i = 0; i < n; i++) {
		if (b[i] == ';') {
			semi = i;
			break;
		}
	}
	long numlen = semi < 0 ? n : semi;
	if (numlen == 1 && (b[0] == '0' || b[0] == '2')) {
		v->title.len = 0;
		v->has_title = semi >= 0;
		for (long i = semi + 1; semi >= 0 && i < n; i++) {
			buf_utf8(&v->title, b[i]);
		}
	} else if (numlen == 4 && b[0] == '7' && b[1] == '7' && b[2] == '6' && b[3] == '5') {
		v->sync_mark = semi < 0 ? 0 : leading_int(b + semi + 1, n - semi - 1, VT_MARK_MAX);
	}
}

static void ris(struct vt *v)
{
	vt_free_rows(v->main, v->rows);
	v->main = vt_new_screen(v->rows, v->cols);
	vt_free_rows(v->alt, v->rows);
	v->alt = NULL;
	reset_state(v);
	v->all_dirty = 1;
}

// The escape sequence at +i+ (an ESC): the index after it, or -1 when it's
// incomplete
static long escape(struct vt *v, const uint32_t *s, long len, long i)
{
	if (i + 1 >= len) {
		return -1;
	}
	uint32_t c = s[i + 1];
	switch (c) {
	case '[': {
		long j = i + 2;
		while (j < len && !(s[j] >= 0x40 && s[j] <= 0x7E)) {
			j++;
		}
		if (j >= len) {
			return -1;
		}
		csi(v, s + i + 2, j - i - 2, s[j]);
		return j + 1;
	}
	case ']':
	case 'P':
	case '_':
	case '^':
	case 'X': {
		// OSC (titles), DCS, APC, PM, and SOS strings: to BEL or ST
		long j = i + 2;
		while (j < len && !(s[j] == 0x07 || (s[j] == 0x1B && j + 1 < len && s[j + 1] == '\\'))) {
			j++;
		}
		if (j >= len) {
			return -1;
		}
		if (c == ']') {
			osc(v, s + i + 2, j - i - 2);
		}
		return j + (s[j] == 0x07 ? 1 : 2);
	}
	case '7':
		save_cursor(v, &v->saved);
		return i + 2;
	case '8':
		restore_cursor(v);
		return i + 2;
	case 'D':
		index_down(v);
		return i + 2;
	case 'E':
		v->col = 0;
		index_down(v);
		return i + 2;
	case 'M':
		v->wrap_pending = 0;
		if (v->row == v->top) {
			scroll_down(v, 1);
		} else if (v->row > 0) {
			v->row--;
		}
		return i + 2;
	case 'c':
		ris(v);
		return i + 2;
	case '(':
	case ')':
	case '*':
	case '+':
	case '#':
	case '%':
	case ' ':
		if (i + 2 >= len) {
			return -1;
		}
		return i + 3;
	default:
		return i + 2; // ESC = > N O H and others: ignored
	}
}

// RubyVT#incomplete_utf8_tail: bytes of an incomplete UTF-8 character at the end
static long incomplete_utf8_tail(const uint8_t *b, long n)
{
	for (long k = 1; k <= 3 && k <= n; k++) {
		uint8_t byte = b[n - k];
		if ((byte & 0xC0) == 0x80) {
			continue;
		}
		long need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1;
		return need > k ? k : 0;
	}
	return 0;
}

/*
 * One UTF-8 character at +p+ (Ruby's UTF-8: no overlongs, surrogates, or
 * code points past U+10FFFF): its length (> 0) with *cp set, 0 when the
 * bytes end inside a valid prefix, or -1 - v for an invalid sequence whose
 * first v bytes were a valid prefix.
 */
static long utf8_char(const uint8_t *p, long n, uint32_t *cp)
{
	uint8_t b = p[0];
	if (b < 0x80) {
		*cp = b;
		return 1;
	}
	long need;
	uint32_t c;
	uint8_t lo = 0x80, hi = 0xBF;
	if (b >= 0xC2 && b <= 0xDF) {
		need = 2;
		c = b & 0x1F;
	} else if (b >= 0xE0 && b <= 0xEF) {
		need = 3;
		c = b & 0x0F;
		if (b == 0xE0) {
			lo = 0xA0;
		} else if (b == 0xED) {
			hi = 0x9F;
		}
	} else if (b >= 0xF0 && b <= 0xF4) {
		need = 4;
		c = b & 0x07;
		if (b == 0xF0) {
			lo = 0x90;
		} else if (b == 0xF4) {
			hi = 0x8F;
		}
	} else {
		return -1;
	}
	for (long k = 1; k < need; k++) {
		if (k >= n) {
			return 0;
		}
		uint8_t x = p[k];
		if (x < lo || x > hi) {
			return -1 - k;
		}
		lo = 0x80;
		hi = 0xBF;
		c = (c << 6) | (x & 0x3F);
	}
	*cp = c;
	return need;
}

/*
 * Code points of +p+ with String#scrub('?')'s replacements: an invalid
 * sequence becomes one '?' for its valid prefix (or one byte), and bytes
 * ending inside a character one '?'.
 */
static long decode(struct vt *v, const uint8_t *p, long n)
{
	if (n > v->cps_cap) {
		REALLOC_N(v->cps, uint32_t, n);
		v->cps_cap = n;
	}
	long m = 0;
	long i = 0;
	while (i < n) {
		uint32_t cp;
		if (p[i] < 0x80) {
			v->cps[m++] = p[i++];
			continue;
		}
		long r = utf8_char(p + i, n - i, &cp);
		if (r > 0) {
			v->cps[m++] = cp;
			i += r;
		} else if (r == 0) {
			v->cps[m++] = '?';
			break;
		} else {
			long valid = -1 - r;
			v->cps[m++] = '?';
			i += valid >= 2 ? valid : 1;
		}
	}
	return m;
}

/* feed(bytes): see RubyVT#feed */
static VALUE vt_feed(VALUE self, VALUE bytes)
{
	struct vt *v = get_vt(self);
	if (NIL_P(bytes)) {
		return self;
	}
	StringValue(bytes);
	long blen = RSTRING_LEN(bytes);
	if (blen == 0) {
		return self;
	}
	v->bytes_fed += blen;

	v->data.len = 0;
	buf_cat(&v->data, v->pending.p, v->pending.len);
	buf_cat(&v->data, RSTRING_PTR(bytes), blen);
	v->pending.len = 0;

	// Hold back an incomplete UTF-8 character at the end
	const uint8_t *data = (const uint8_t *)v->data.p;
	long dlen = v->data.len;
	long tail = incomplete_utf8_tail(data, dlen);
	char held[4];
	memcpy(held, data + dlen - tail, (size_t)tail);
	dlen -= tail;
	buf_cat(&v->pending, held, tail);

	long len = decode(v, data, dlen);
	const uint32_t *s = v->cps;
	long i = 0;
	while (i < len) {
		uint32_t o = s[i];
		if (o >= 0x20 && o != 0x7F) {
			long j = i + 1;
			while (j < len && s[j] >= 0x20 && s[j] != 0x7F) {
				j++;
			}
			put_text(v, s + i, j - i);
			i = j;
		} else if (o == 0x1B) {
			long n = escape(v, s, len, i);
			if (n < 0) {
				// Incomplete: kept (with the held-back bytes) for the next feed
				v->pending.len = 0;
				for (long k = i; k < len; k++) {
					buf_utf8(&v->pending, s[k]);
				}
				buf_cat(&v->pending, held, tail);
				break;
			}
			i = n;
		} else {
			control(v, o);
			i++;
		}
	}
	return self;
}

/* resize(rows, cols): NativeVT#resize checks its arguments first */
static VALUE vt_resize(VALUE self, VALUE rows_v, VALUE cols_v)
{
	struct vt *v = get_vt(self);
	long rows = NUM2LONG(rows_v);
	long cols = NUM2LONG(cols_v);
	if (rows == v->rows && cols == v->cols) {
		return self;
	}
	if (rows < 1 || cols < 1) {
		rb_raise(rb_eArgError, "A VT needs at least 1x1 cells (got %ldx%ld)", rows, cols);
	}
	check_size(rows, cols);

	for (long i = 0; i < v->rows; i++) {
		row_resize(v->main[i], cols);
		if (v->alt) {
			row_resize(v->alt[i], cols);
		}
	}
	for (long i = 0; i < v->sb_len; i++) {
		struct vt_row *r = v->sb[(v->sb_head + i) % v->sb_cap];
		if (r->len < cols) {
			r->len = cols; // (padded: the cells past n are spaces)
		}
	}
	if (rows < v->rows) {
		long drop = v->rows - rows;
		long below = v->rows - 1 - v->row;
		if (below < 0) {
			below = 0;
		}
		long cut = drop < below ? drop : below;
		// Rows below the cursor go first, then lines from the top
		for (long i = v->rows - cut; i < v->rows; i++) {
			row_free(v->main[i]);
			if (v->alt) {
				row_free(v->alt[i]);
			}
		}
		long top = drop - cut;
		long keep = v->rows - cut;
		for (long i = 0; i < top; i++) {
			if (v->alt) {
				row_free(v->main[i]);
				row_free(v->alt[i]);
			} else {
				push_scrollback(v, v->main[i]);
			}
		}
		memmove(v->main, v->main + top, (size_t)(keep - top) * sizeof(*v->main));
		REALLOC_N(v->main, struct vt_row *, rows);
		if (v->alt) {
			memmove(v->alt, v->alt + top, (size_t)(keep - top) * sizeof(*v->alt));
			REALLOC_N(v->alt, struct vt_row *, rows);
		}
		v->row -= top;
	} else {
		REALLOC_N(v->main, struct vt_row *, rows);
		for (long i = v->rows; i < rows; i++) {
			v->main[i] = row_new(cols);
		}
		if (v->alt) {
			REALLOC_N(v->alt, struct vt_row *, rows);
			for (long i = v->rows; i < rows; i++) {
				v->alt[i] = row_new(cols);
			}
		}
	}
	v->rows = rows;
	v->cols = cols;
	v->top = 0;
	v->bottom = rows - 1;
	v->row = clampl(v->row, 0, rows - 1);
	v->col = clampl(v->col, 0, cols - 1);
	v->wrap_pending = 0;
	default_tabs(v);
	REALLOC_N(v->dirty, uint8_t, rows);
	memset(v->dirty, 1, (size_t)rows);
	v->all_dirty = 1;
	return self;
}

/* Reading */

static struct vt_row *line_at(struct vt *v, long n)
{
	long i = n - v->dropped;
	if (i < 0) {
		return NULL;
	}
	if (i < v->sb_len) {
		return v->sb[(v->sb_head + i) % v->sb_cap];
	}
	i -= v->sb_len;
	return i < v->rows ? screen(v)[i] : NULL;
}

// Cells +from+...+to+ of a row as UTF-8 ("\0" for right halves unless +skip_halves+)
static VALUE row_str(const struct vt_row *r, long from, long to, int skip_halves)
{
	struct vt_buf b = { 0 };
	buf_reserve(&b, to - from + 1);
	for (long c = from; c < to; c++) {
		uint32_t cp = row_cp(r, c);
		if (cp == 0 && skip_halves) {
			continue;
		}
		buf_utf8(&b, cp);
	}
	VALUE s = utf8_str(b.p, b.len);
	buf_free(&b);
	return s;
}

static inline VALUE color_value(int32_t c)
{
	return c < 0 ? Qnil : INT2NUM(c);
}

// A VT::Row copy of a row
static VALUE row_value(const struct vt_row *r)
{
	VALUE text = row_str(r, 0, r->len, 0);
	VALUE fg = Qnil, bg = Qnil, attr = Qnil;
	if (r->styled) {
		fg = rb_ary_new_capa(r->len);
		bg = rb_ary_new_capa(r->len);
		attr = rb_ary_new_capa(r->len);
		for (long c = 0; c < r->len; c++) {
			rb_ary_push(fg, color_value(row_fg(r, c)));
			rb_ary_push(bg, color_value(row_bg(r, c)));
			rb_ary_push(attr, LONG2NUM(row_attr(r, c)));
		}
	}
	VALUE args[5] = { text, fg, bg, attr, r->wrapped ? Qtrue : Qfalse };
	if (NIL_P(cRow)) {
		cRow = rb_path2class("MB::Term::VT::Row");
	}
	return rb_funcallv(cRow, id_build, 5, args);
}

/* line_at(n): a copy of absolute line +n+ as a VT::Row, or nil */
static VALUE vt_line_at(VALUE self, VALUE n_v)
{
	struct vt *v = get_vt(self);
	struct vt_row *r = line_at(v, NUM2LONG(n_v));
	return r ? row_value(r) : Qnil;
}

/* line_text(n): the text (one character per cell) of absolute line +n+, or nil */
static VALUE vt_line_text(VALUE self, VALUE n_v)
{
	struct vt *v = get_vt(self);
	struct vt_row *r = line_at(v, NUM2LONG(n_v));
	return r ? row_str(r, 0, r->len, 0) : Qnil;
}

/* screen: copies of the rows on screen (VT::Row) */
static VALUE vt_screen(VALUE self)
{
	struct vt *v = get_vt(self);
	long rows = v->rows;
	VALUE out = rb_ary_new_capa(rows);
	for (long i = 0; i < rows; i++) {
		// (row_value calls Row.build, Ruby code: the VT is looked at again each time)
		v = get_vt(self);
		if (i >= v->rows) {
			break;
		}
		rb_ary_push(out, row_value(screen(v)[i]));
	}
	return out;
}

/* lines: the screen's lines as text (trailing spaces kept) */
static VALUE vt_lines(VALUE self)
{
	struct vt *v = get_vt(self);
	VALUE out = rb_ary_new_capa(v->rows);
	for (long i = 0; i < v->rows; i++) {
		struct vt_row *r = screen(v)[i];
		rb_ary_push(out, row_str(r, 0, r->len, 1));
	}
	return out;
}

static VALUE vt_take_replies(VALUE self)
{
	struct vt *v = get_vt(self);
	VALUE s = utf8_str(v->replies.p, v->replies.len);
	v->replies.len = 0;
	return s;
}

static VALUE vt_dirty_p(VALUE self)
{
	struct vt *v = get_vt(self);
	if (v->all_dirty) {
		return Qtrue;
	}
	for (long i = 0; i < v->rows; i++) {
		if (v->dirty[i]) {
			return Qtrue;
		}
	}
	return Qfalse;
}

static void clean(struct vt *v)
{
	v->all_dirty = 0;
	memset(v->dirty, 0, (size_t)v->rows);
}

static VALUE vt_clean(VALUE self)
{
	clean(get_vt(self));
	return self;
}

static VALUE vt_invalidate(VALUE self)
{
	get_vt(self)->all_dirty = 1;
	return self;
}

#define VT_READER(name, expr) \
	static VALUE vt_##name(VALUE self) \
	{ \
		struct vt *v = get_vt(self); \
		return expr; \
	}

VT_READER(rows, LONG2NUM(v->rows))
VT_READER(cols, LONG2NUM(v->cols))
VT_READER(row, LONG2NUM(v->row))
VT_READER(col, LONG2NUM(v->col))
VT_READER(max_scrollback, LONG2NUM(v->max_scrollback))
VT_READER(ambiguous_width, LONG2NUM(v->ambiguous_width))
VT_READER(dropped, LONG2NUM(v->dropped))
VT_READER(scrolled, LONG2NUM(v->scrolled))
VT_READER(bytes_fed, LL2NUM(v->bytes_fed))
VT_READER(sync_mark, LL2NUM(v->sync_mark))
VT_READER(scrollback_length, LONG2NUM(v->sb_len))
VT_READER(title, v->has_title ? utf8_str(v->title.p, v->title.len) : Qnil)
VT_READER(alt_p, v->alt ? Qtrue : Qfalse)
VT_READER(bracketed_paste_p, v->bracketed_paste ? Qtrue : Qfalse)
VT_READER(app_cursor_p, v->app_cursor ? Qtrue : Qfalse)
VT_READER(cursor_visible_p, v->cursor_visible ? Qtrue : Qfalse)

static VALUE vt_set_ambiguous_width(VALUE self, VALUE w)
{
	get_vt(self)->ambiguous_width = NUM2LONG(w);
	return w;
}

/* Drawing */

// Grid#put_run's cells for cells from...from+k of +r+ (or spaces when +r+ is NULL) at (x, y)
static void grid_put(struct mb_term_grid *g, long x, long y, const struct vt_row *r, long from, long k, int32_t fg, int32_t bg, long attr)
{
	if (y < 0 || y >= g->height) {
		return;
	}
	for (long i = 0; i < k; i++) {
		long cx = x + i;
		if (cx >= g->width) {
			break;
		}
		if (cx < 0) {
			continue;
		}
		long gi = y * g->width + cx;
		g->cp[gi] = r ? row_cp(r, from + i) : ' ';
		g->fg[gi] = fg;
		g->bg[gi] = bg;
		g->attr[gi] = (uint8_t)attr;
	}
}

struct draw_mark {
	long line, from, to, bits;
};

static VALUE run_args(long x, long y, VALUE str, int32_t fg, int32_t bg, long attr)
{
	return rb_ary_new_from_args(6, LONG2NUM(x), LONG2NUM(y), str, color_value(fg), color_value(bg), LONG2NUM(attr));
}

/*
 * The runs that draw +r+ (RubyVT#draw_row): each one's cells into +g+, or
 * when +g+ is NULL appended to +runs+ as #put_run's arguments.
 */
static void draw_row(struct mb_term_grid *g, VALUE runs, long x, long y, long w, const struct vt_row *r, const struct draw_mark *marks, long nmarks, long line, long *extra)
{
	long n = w < r->len ? w : r->len;
	if (n < 0) {
		n = 0;
	}
	int any = 0;
	for (long m = 0; m < nmarks; m++) {
		any |= marks[m].line == line;
	}
	if (!r->styled && !any) {
		if (g) {
			grid_put(g, x, y, r, 0, n, -1, -1, 0);
		} else {
			rb_ary_push(runs, run_args(x, y, row_str(r, 0, n, 0), -1, -1, 0));
		}
	} else {
		for (long c = 0; c < n; c++) {
			extra[c] = 0;
		}
		for (long m = 0; m < nmarks; m++) {
			if (marks[m].line != line) {
				continue;
			}
			long to = marks[m].to < n ? marks[m].to : n;
			for (long c = marks[m].from; c < to; c++) {
				if (c >= 0) {
					extra[c] |= marks[m].bits;
				}
			}
		}
		long c = 0;
		while (c < n) {
			int32_t f = row_fg(r, c);
			int32_t b = row_bg(r, c);
			long a = row_attr(r, c) | extra[c];
			long e = c + 1;
			while (e < n && row_fg(r, e) == f && row_bg(r, e) == b && (row_attr(r, e) | extra[e]) == a) {
				e++;
			}
			if (g) {
				grid_put(g, x + c, y, r, c, e - c, f, b, a);
			} else {
				rb_ary_push(runs, run_args(x + c, y, row_str(r, c, e, 0), f, b, a));
			}
			c = e;
		}
	}
	if (w > n) {
		if (g) {
			grid_put(g, x + n, y, NULL, 0, w - n, -1, -1, 0);
		} else {
			VALUE sp = rb_str_buf_new(w - n);
			for (long i = 0; i < w - n; i++) {
				rb_str_cat(sp, " ", 1);
			}
			rb_enc_associate(sp, rb_utf8_encoding());
			rb_ary_push(runs, run_args(x + n, y, sp, -1, -1, 0));
		}
	}
}

static void call_runs(VALUE grid, VALUE runs)
{
	long n = RARRAY_LEN(runs);
	for (long i = 0; i < n; i++) {
		VALUE a = rb_ary_entry(runs, i);
		rb_funcallv(grid, id_put_run, 6, RARRAY_CONST_PTR(a));
	}
}

/*
 * draw_cells(grid, x, y, w, h, offset, all, marks): RubyVT#draw (NativeVT#draw
 * takes its keywords).  Native grids (FastTerm::Grid and subclasses) get
 * their cells written directly; any other grid gets the same #put_run
 * calls RubyVT makes.
 */
static VALUE vt_draw_cells(VALUE self, VALUE grid, VALUE x_v, VALUE y_v, VALUE w_v, VALUE h_v, VALUE offset_v, VALUE all_v, VALUE marks_v)
{
	struct vt *v = get_vt(self);
	long x = NUM2LONG(x_v);
	long y = NUM2LONG(y_v);
	long w = NUM2LONG(w_v);
	long h = NUM2LONG(h_v);
	long offset = NUM2LONG(offset_v);

	// The marks as C values first (conversions may run Ruby code)
	long nmarks = 0;
	struct draw_mark *marks = NULL;
	VALUE marks_tmp = 0;
	if (!NIL_P(marks_v)) {
		marks_v = rb_Array(marks_v);
		long n = RARRAY_LEN(marks_v);
		marks = ALLOCV_N(struct draw_mark, marks_tmp, n > 0 ? n : 1);
		for (long i = 0; i < n; i++) {
			VALUE m = rb_Array(rb_ary_entry(marks_v, i));
			marks[i].line = NUM2LONG(rb_ary_entry(m, 0));
			marks[i].from = NUM2LONG(rb_ary_entry(m, 1));
			marks[i].to = NUM2LONG(rb_ary_entry(m, 2));
			marks[i].bits = NUM2LONG(rb_ary_entry(m, 3));
		}
		nmarks = n;
	}
	struct mb_term_grid *g = mb_term_grid_or_null(grid);

	v = get_vt(self);
	int all = RTEST(all_v) || v->all_dirty || offset > 0 || !NIL_P(marks_v);
	long first = v->dropped + v->sb_len - offset; // absolute line at the pane's top
	long drawn = 0;
	VALUE extra_tmp = 0;
	long *extra = ALLOCV_N(long, extra_tmp, w > 0 ? w : 1);
	for (long r = 0; r < h; r++) {
		if (!(all || (offset == 0 && r < v->rows && v->dirty[r]))) {
			continue;
		}
		struct vt_row *row = line_at(v, first + r);
		if (g) {
			if (row == NULL) {
				grid_put(g, x, y + r, NULL, 0, w, -1, -1, 0);
			} else {
				draw_row(g, Qnil, x, y + r, w, row, marks, nmarks, first + r, extra);
			}
		} else {
			// (runs built before any Ruby call; rows looked up again per row)
			VALUE runs = rb_ary_new();
			if (row == NULL) {
				VALUE sp = rb_str_buf_new(w > 0 ? w : 0);
				for (long i = 0; i < w; i++) {
					rb_str_cat(sp, " ", 1);
				}
				rb_enc_associate(sp, rb_utf8_encoding());
				rb_ary_push(runs, run_args(x, y + r, sp, -1, -1, 0));
			} else {
				draw_row(NULL, runs, x, y + r, w, row, marks, nmarks, first + r, extra);
			}
			call_runs(grid, runs);
			v = get_vt(self);
		}
		drawn++;
	}
	ALLOCV_END(extra_tmp);
	if (marks_tmp) {
		ALLOCV_END(marks_tmp);
	}
	clean(v);
	return LONG2NUM(drawn);
}

/* For comparing implementations: RubyVT#debug_state */

static VALUE row_state(const struct vt_row *r)
{
	VALUE row = row_value(r);
	return rb_funcall(row, id_to_a, 0);
}

static VALUE saved_state(const struct vt_saved *s)
{
	if (!s->has) {
		return Qnil;
	}
	return rb_ary_new_from_args(7, LONG2NUM(s->row), LONG2NUM(s->col), color_value(s->fg), color_value(s->bg), LONG2NUM(s->attr), s->origin ? Qtrue : Qfalse, s->wrap_pending ? Qtrue : Qfalse);
}

static VALUE rows_state(VALUE self, int alt)
{
	struct vt *v = get_vt(self);
	if (alt && v->alt == NULL) {
		return Qnil;
	}
	long rows = v->rows;
	VALUE out = rb_ary_new_capa(rows);
	for (long i = 0; i < rows; i++) {
		v = get_vt(self);
		if (i >= v->rows || (alt && v->alt == NULL)) {
			break;
		}
		rb_ary_push(out, row_state((alt ? v->alt : v->main)[i]));
	}
	return out;
}

#define SET(key, val) rb_hash_aset(h, ID2SYM(rb_intern(key)), (val))
#define BOOL(x) ((x) ? Qtrue : Qfalse)

static VALUE vt_debug_state(VALUE self)
{
	struct vt *v = get_vt(self);
	VALUE h = rb_hash_new();
	SET("rows", LONG2NUM(v->rows));
	SET("cols", LONG2NUM(v->cols));
	SET("row", LONG2NUM(v->row));
	SET("col", LONG2NUM(v->col));
	SET("top", LONG2NUM(v->top));
	SET("bottom", LONG2NUM(v->bottom));
	SET("wrap_pending", BOOL(v->wrap_pending));
	SET("fg", color_value(v->fg));
	SET("bg", color_value(v->bg));
	SET("attr", LONG2NUM(v->attr));
	SET("saved", saved_state(&v->saved));
	SET("saved_main", saved_state(&v->saved_main));
	SET("origin", BOOL(v->origin));
	SET("autowrap", BOOL(v->autowrap));
	SET("cursor_visible", BOOL(v->cursor_visible));
	SET("bracketed_paste", BOOL(v->bracketed_paste));
	SET("app_cursor", BOOL(v->app_cursor));
	VALUE tabs = rb_ary_new();
	for (long c = 0; c < v->cols; c++) {
		if (v->tabs[c]) {
			rb_ary_push(tabs, LONG2NUM(c));
		}
	}
	SET("tabs", tabs);
	SET("main", rows_state(self, 0));
	SET("alt", rows_state(self, 1));
	v = get_vt(self);
	long sbn = v->sb_len;
	VALUE sb = rb_ary_new_capa(sbn);
	for (long i = 0; i < sbn; i++) {
		v = get_vt(self);
		if (i >= v->sb_len) {
			break;
		}
		rb_ary_push(sb, row_state(v->sb[(v->sb_head + i) % v->sb_cap]));
	}
	SET("scrollback", sb);
	v = get_vt(self);
	SET("dropped", LONG2NUM(v->dropped));
	SET("scrolled", LONG2NUM(v->scrolled));
	SET("bytes_fed", LL2NUM(v->bytes_fed));
	SET("sync_mark", LL2NUM(v->sync_mark));
	SET("title", v->has_title ? utf8_str(v->title.p, v->title.len) : Qnil);
	SET("pending", rb_str_new(v->pending.p, v->pending.len));
	SET("replies", utf8_str(v->replies.p, v->replies.len));
	VALUE dirty = rb_ary_new_capa(v->rows);
	for (long i = 0; i < v->rows; i++) {
		rb_ary_push(dirty, BOOL(v->dirty[i]));
	}
	SET("dirty", dirty);
	SET("all_dirty", BOOL(v->all_dirty));
	SET("max_scrollback", LONG2NUM(v->max_scrollback));
	SET("ambiguous_width", LONG2NUM(v->ambiguous_width));
	return h;
}

/* VT.width_table = [last, width]: Reline's East Asian width chunks */
static VALUE vt_set_width_table(VALUE klass, VALUE pair)
{
	pair = rb_Array(pair);
	VALUE last = rb_Array(rb_ary_entry(pair, 0));
	VALUE width = rb_Array(rb_ary_entry(pair, 1));
	long n = RARRAY_LEN(last);
	if (RARRAY_LEN(width) != n) {
		rb_raise(rb_eArgError, "Width table lengths differ (%ld, %ld)", n, RARRAY_LEN(width));
	}
	long *l = ALLOC_N(long, n > 0 ? n : 1);
	int *w = ALLOC_N(int, n > 0 ? n : 1);
	for (long i = 0; i < n; i++) {
		l[i] = NUM2LONG(rb_ary_entry(last, i));
		w[i] = NUM2INT(rb_ary_entry(width, i));
	}
	xfree(wt_last);
	xfree(wt_width);
	wt_last = l;
	wt_width = w;
	wt_len = n;
	return pair;
}

void mb_term_init_vt(VALUE mFastTerm)
{
	rb_gc_register_address(&cRow);
	id_build = rb_intern("build");
	id_put_run = rb_intern("put_run");
	id_to_a = rb_intern("to_a");

	cVT = rb_define_class_under(mFastTerm, "VT", rb_cObject);
	rb_define_alloc_func(cVT, vt_alloc);
	rb_define_singleton_method(cVT, "width_table=", vt_set_width_table, 1);
	rb_define_method(cVT, "initialize", vt_initialize, 4);
	rb_define_method(cVT, "feed", vt_feed, 1);
	rb_define_method(cVT, "<<", vt_feed, 1);
	rb_define_method(cVT, "resize", vt_resize, 2);
	rb_define_method(cVT, "draw_cells", vt_draw_cells, 8);
	rb_define_method(cVT, "line_at", vt_line_at, 1);
	rb_define_method(cVT, "line_text", vt_line_text, 1);
	rb_define_method(cVT, "screen", vt_screen, 0);
	rb_define_method(cVT, "lines", vt_lines, 0);
	rb_define_method(cVT, "take_replies", vt_take_replies, 0);
	rb_define_method(cVT, "dirty?", vt_dirty_p, 0);
	rb_define_method(cVT, "clean!", vt_clean, 0);
	rb_define_method(cVT, "invalidate", vt_invalidate, 0);
	rb_define_method(cVT, "rows", vt_rows, 0);
	rb_define_method(cVT, "cols", vt_cols, 0);
	rb_define_method(cVT, "row", vt_row, 0);
	rb_define_method(cVT, "col", vt_col, 0);
	rb_define_method(cVT, "max_scrollback", vt_max_scrollback, 0);
	rb_define_method(cVT, "ambiguous_width", vt_ambiguous_width, 0);
	rb_define_method(cVT, "ambiguous_width=", vt_set_ambiguous_width, 1);
	rb_define_method(cVT, "dropped", vt_dropped, 0);
	rb_define_method(cVT, "scrolled", vt_scrolled, 0);
	rb_define_method(cVT, "bytes_fed", vt_bytes_fed, 0);
	rb_define_method(cVT, "sync_mark", vt_sync_mark, 0);
	rb_define_method(cVT, "scrollback_length", vt_scrollback_length, 0);
	rb_define_method(cVT, "title", vt_title, 0);
	rb_define_method(cVT, "alt?", vt_alt_p, 0);
	rb_define_method(cVT, "bracketed_paste?", vt_bracketed_paste_p, 0);
	rb_define_method(cVT, "app_cursor?", vt_app_cursor_p, 0);
	rb_define_method(cVT, "cursor_visible?", vt_cursor_visible_p, 0);
	rb_define_method(cVT, "debug_state", vt_debug_state, 0);
}
