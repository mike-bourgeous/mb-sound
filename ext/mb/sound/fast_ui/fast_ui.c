/*
 * MB::Sound::FastUI: terminal UI kernels.
 *
 * Step 1 of the terminal UI (ui-2): the hot paths of MB::Sound::Plot's text
 * renderer for live panes, each the exact mirror of a Ruby method that
 * specs compare it with (same dots, same cells, same bytes):
 *
 * - FastUI.decimate(xs, ys, columns, regular, ends): per-column min/max
 *   decimation of a long polyline (Plot::Geometry.decimate_ruby).
 * - FastUI.polyline(dots, xs, ys, color, dash_on, dash_sum): rasterizes a
 *   polyline into a Raster's dots (Plot::Raster#polyline_ruby, i.e.
 *   Geometry.line_points plus the dash pattern plus Raster#set).
 * - FastUI.area(dots, xs, ys, base, fill_color, line_color): a line filled
 *   down to a base row (Plot::Text::Surface#area_ruby).
 * - FastUI::Grid#compose: a canvas's dots to characters and colors,
 *   mirroring Plot::Text::Canvas.cells plus Panel#compose.  FastUI::Grid is
 *   a subclass of mb-term's native cell grid (MB::Term::FastTerm::Grid:
 *   cells, SGR text, changed-cell frames, write_frame; gems/mb-term, moved
 *   there in term-extract-1), whose cells it reaches through
 *   mb_term_grid.h.
 *
 * Numo semantics are copied where the Ruby code relies on them: min/max
 * skip leading NaNs (numo's f_min/f_max), double to Int32 casts go through
 * long long for negative values (numo's xint m_from_real), round() is C's.
 * Built with -ffp-contract=off so no multiply-add is fused.
 *
 * gvl_probe.c adds FastUI::GVLProbe (GVL wait and hold times of chosen
 * threads) for the dashboard band (ui-3; design/notes/terminal_ui.md).
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/io.h>
#include <ruby/thread.h>
#include <errno.h>
#include <poll.h>
#include <unistd.h>
#include "numo/narray.h"
#include "mb_term_grid.h"

// Geometry.line_points' limit on dots per polyline
#define LINE_POINT_LIMIT 4000000

static VALUE mFastUI;
static VALUE cGrid;

// gvl_probe.c
void mb_fast_ui_init_gvl_probe(VALUE mFastUI);

// numo's double to Int32 conversion (xint_macro.h m_from_real)
static inline int32_t to_i32(double x)
{
	return x < 0 ? (int32_t)((long long)x) : (int32_t)x;
}

// numo's NaN-skipping min/max over n values (real_accum.h f_min/f_max)
static inline double nmin(const double *p, size_t n)
{
	double y = 0.0;
	size_t i = 0;
	for (; i < n; i++) {
		y = p[i];
		if (!isnan(y)) {
			for (i++; i < n; i++) {
				if (p[i] < y) {
					y = p[i];
				}
			}
			break;
		}
	}
	return y;
}

static inline double nmax(const double *p, size_t n)
{
	double y = 0.0;
	size_t i = 0;
	for (; i < n; i++) {
		y = p[i];
		if (!isnan(y)) {
			for (i++; i < n; i++) {
				if (p[i] > y) {
					y = p[i];
				}
			}
			break;
		}
	}
	return y;
}

// True if +v+ is a contiguous 1D NArray of class +klass+
static int contiguous_1d(VALUE v, VALUE klass)
{
	return CLASS_OF(v) == klass && RNARRAY_NDIM(v) == 1 && RTEST(nary_check_contiguous(v));
}

static const double *dfloat_ptr(VALUE v)
{
	return (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

static VALUE new_dfloat(size_t n, double **ptr)
{
	size_t shape[1] = { n };
	VALUE v = nary_new(numo_cDFloat, 1, shape);
	*ptr = (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
	return v;
}

// Checks that +dots+ is a contiguous 2D UInt16 NArray; sets its size
static uint16_t *dots_ptr(VALUE dots, long *width, long *height)
{
	if (CLASS_OF(dots) != numo_cUInt16 || RNARRAY_NDIM(dots) != 2 || !RTEST(nary_check_contiguous(dots))) {
		rb_raise(rb_eArgError, "The dots must be a contiguous 2D Numo::UInt16");
	}
	*height = (long)RNARRAY_SHAPE(dots)[0];
	*width = (long)RNARRAY_SHAPE(dots)[1];
	return (uint16_t *)(nary_get_pointer_for_write(dots) + nary_get_offset(dots));
}

/*
 * decimate(xs, ys, columns, regular, ends) -> [xs, ys] (new DFloats), or nil
 * when the inputs aren't contiguous 1D DFloats of the same length (the
 * caller falls back to Ruby).  Callers check n > columns * 2 first.
 */
static VALUE ruby_decimate(VALUE self, VALUE xs_v, VALUE ys_v, VALUE columns_v, VALUE regular_v, VALUE ends_v)
{
	if (!contiguous_1d(xs_v, numo_cDFloat) || !contiguous_1d(ys_v, numo_cDFloat) ||
			RNARRAY_SHAPE(xs_v)[0] != RNARRAY_SHAPE(ys_v)[0]) {
		return Qnil;
	}
	long n = (long)RNARRAY_SHAPE(xs_v)[0];
	long columns = NUM2LONG(columns_v);
	int ends = RTEST(ends_v);
	if (n <= columns * 2 || columns < 1 || n == 0) {
		return Qnil;
	}

	const double *xs = dfloat_ptr(xs_v);
	const double *ys = dfloat_ptr(ys_v);
	double *ox, *oy;
	VALUE ox_v, oy_v;

	if (RTEST(regular_v)) {
		// Geometry.decimate_regular: equal groups of g points, the last
		// padded with the last point
		long g = ends ? (long)ceil((double)n / (double)columns) : (long)floor((double)n / (double)columns);
		if (g < 1) {
			g = 1;
		}
		long groups = (long)ceil((double)n / (double)g);
		double *buf = ALLOC_N(double, g);
		ox_v = new_dfloat((size_t)groups * 2, &ox);
		oy_v = new_dfloat((size_t)groups * 2, &oy);
		for (long k = 0; k < groups; k++) {
			long a = k * g;
			for (long j = 0; j < g; j++) {
				long i = a + j;
				buf[j] = ys[i < n ? i : n - 1];
			}
			double ymin = nmin(buf, (size_t)g);
			double ymax = nmax(buf, (size_t)g);
			int rising = (buf[g - 1] - buf[0]) >= 0;
			double x0 = xs[a < n ? a : n - 1];
			double x1 = xs[a + g - 1 < n ? a + g - 1 : n - 1];
			if (ends) {
				ox[2 * k] = x0;
				ox[2 * k + 1] = x1;
			} else {
				double xc = (x0 + x1) * 0.5;
				ox[2 * k] = xc;
				ox[2 * k + 1] = xc;
			}
			oy[2 * k] = rising ? ymin : ymax;
			oy[2 * k + 1] = rising ? ymax : ymin;
		}
		xfree(buf);
		return rb_assoc_new(ox_v, oy_v);
	}

	// Irregular x: groups of points whose rounded (floored with +ends+)
	// x is the same; groups of up to two points pass through.  Like the
	// Ruby, every group of three or more points keeps its first and last x.
	double *tx = ALLOC_N(double, 2 * n);
	double *ty = ALLOC_N(double, 2 * n);
	long m = 0;
	long a = 0;
	while (a < n) {
		double ca = ends ? floor(xs[a]) : round(xs[a]);
		// (Ruby: a new group where the difference of rounded x isn't 0,
		// so NaNs and repeated infinities each start one)
		long b = a + 1;
		double prev = ca;
		while (b < n) {
			double cb = ends ? floor(xs[b]) : round(xs[b]);
			if ((cb - prev) != 0) {
				break;
			}
			prev = cb;
			b++;
		}
		if (b - a <= 2) {
			for (long i = a; i < b; i++) {
				tx[m] = xs[i];
				ty[m] = ys[i];
				m++;
			}
		} else {
			double lo = nmin(ys + a, (size_t)(b - a));
			double hi = nmax(ys + a, (size_t)(b - a));
			tx[m] = xs[a];
			tx[m + 1] = xs[b - 1];
			if (ys[b - 1] >= ys[a]) {
				ty[m] = lo;
				ty[m + 1] = hi;
			} else {
				ty[m] = hi;
				ty[m + 1] = lo;
			}
			m += 2;
		}
		a = b;
	}
	ox_v = new_dfloat((size_t)m, &ox);
	oy_v = new_dfloat((size_t)m, &oy);
	memcpy(ox, tx, sizeof(double) * (size_t)m);
	memcpy(oy, ty, sizeof(double) * (size_t)m);
	xfree(tx);
	xfree(ty);
	return rb_assoc_new(ox_v, oy_v);
}

/*
 * project(v, kind, lo, span, reverse, mul, flip) -> DFloat, or nil for
 * inputs that aren't contiguous 1D DFloats: data values to device units
 * (Mark::Base#device_ruby through a scale's #map).  +kind+ 0 is a linear
 * scale ((v - lo) / span, Scale::Base#forward), 1 a log scale
 * ((log10(v) - lo) / span, NaN for v <= 0, Scale::Log#forward); +reverse+
 * maps u to 1 - u; the result is u * mul, or (1 - u) * mul with +flip+
 * (device y grows downward).
 */
static VALUE ruby_project(VALUE self, VALUE v_v, VALUE kind_v, VALUE lo_v, VALUE span_v, VALUE reverse_v, VALUE mul_v, VALUE flip_v)
{
	if (!contiguous_1d(v_v, numo_cDFloat)) {
		return Qnil;
	}
	int kind = NUM2INT(kind_v);
	double lo = NUM2DBL(lo_v);
	double span = NUM2DBL(span_v);
	int reverse = RTEST(reverse_v);
	double mul = NUM2DBL(mul_v);
	int flip = RTEST(flip_v);
	size_t n = RNARRAY_SHAPE(v_v)[0];
	const double *v = dfloat_ptr(v_v);
	double *out;
	VALUE out_v = new_dfloat(n, &out);
	for (size_t i = 0; i < n; i++) {
		double u;
		if (kind == 1) {
			double x = v[i];
			if (x <= 0) {
				x = NAN;
			}
			u = (log10(x) - lo) / span;
		} else {
			u = (v[i] - lo) / span;
		}
		if (reverse) {
			u = 1 - u;
		}
		out[i] = flip ? (1 - u) * mul : u * mul;
	}
	return out_v;
}

/*
 * monotonic(xs) -> true if no finite step between neighbors decreases
 * (Geometry.monotonic_ruby), or nil for inputs that aren't contiguous 1D
 * DFloats.
 */
static VALUE ruby_monotonic(VALUE self, VALUE xs_v)
{
	if (!contiguous_1d(xs_v, numo_cDFloat)) {
		return Qnil;
	}
	size_t n = RNARRAY_SHAPE(xs_v)[0];
	const double *x = dfloat_ptr(xs_v);
	for (size_t i = 0; i + 1 < n; i++) {
		double d = x[i + 1] - x[i];
		if (isfinite(d) && d < 0) {
			return Qfalse;
		}
	}
	return Qtrue;
}

// A visitor for the dots of a polyline, in Geometry.line_points' order:
// lone finite points, every segment's interpolated points, then every
// segment's end point.
typedef void (*dot_fn)(void *ctx, long index, int32_t x, int32_t y);

// Walks the dots of the polyline; returns the dot count, or -1 if the
// count passes LINE_POINT_LIMIT (the caller falls back to Ruby, which
// subsamples).
static long walk_line(const double *xs, const double *ys, long n, dot_fn fn, void *ctx)
{
	if (n == 0) {
		return 0;
	}
	if (n == 1) {
		if (isfinite(xs[0]) && isfinite(ys[0])) {
			fn(ctx, 0, to_i32(round(xs[0])), to_i32(round(ys[0])));
			return 1;
		}
		return 0;
	}

	// Count first, so oversize lines go to Ruby before anything is drawn
	long total = 0;
	for (long i = 0; i + 1 < n; i++) {
		if (isfinite(xs[i]) && isfinite(ys[i]) && isfinite(xs[i + 1]) && isfinite(ys[i + 1])) {
			double dx = xs[i + 1] - xs[i];
			double dy = ys[i + 1] - ys[i];
			double ax = fabs(dx);
			double ay = fabs(dy);
			int32_t steps = to_i32(ceil(ax > ay ? ax : ay));
			if (steps < 1) {
				steps = 1;
			}
			total += steps;
			if (total > LINE_POINT_LIMIT) {
				return -1;
			}
		}
	}

	long k = 0;
	for (long i = 0; i < n; i++) {
		int f = isfinite(xs[i]) && isfinite(ys[i]);
		if (!f) {
			continue;
		}
		int before = i > 0 && isfinite(xs[i - 1]) && isfinite(ys[i - 1]);
		int after = i + 1 < n && isfinite(xs[i + 1]) && isfinite(ys[i + 1]);
		if (!before && !after) {
			fn(ctx, k++, to_i32(round(xs[i])), to_i32(round(ys[i])));
		}
	}

	for (long i = 0; i + 1 < n; i++) {
		if (!(isfinite(xs[i]) && isfinite(ys[i]) && isfinite(xs[i + 1]) && isfinite(ys[i + 1]))) {
			continue;
		}
		double x0 = xs[i];
		double y0 = ys[i];
		double dx = xs[i + 1] - x0;
		double dy = ys[i + 1] - y0;
		double ax = fabs(dx);
		double ay = fabs(dy);
		int32_t steps = to_i32(ceil(ax > ay ? ax : ay));
		if (steps < 1) {
			steps = 1;
		}
		double s = (double)steps;
		for (int32_t j = 0; j < steps; j++) {
			double t = (double)j / s;
			double sx = x0 + dx * t;
			double sy = y0 + dy * t;
			fn(ctx, k++, to_i32(round(sx)), to_i32(round(sy)));
		}
	}

	for (long i = 0; i + 1 < n; i++) {
		if (!(isfinite(xs[i]) && isfinite(ys[i]) && isfinite(xs[i + 1]) && isfinite(ys[i + 1]))) {
			continue;
		}
		double x0 = xs[i];
		double y0 = ys[i];
		double dx = xs[i + 1] - x0;
		double dy = ys[i + 1] - y0;
		fn(ctx, k++, to_i32(round(x0 + dx)), to_i32(round(y0 + dy)));
	}

	return k;
}

struct set_ctx {
	uint16_t *dots;
	uint8_t *mask;
	long width, height;
	uint16_t color;
	long dash_on, dash_sum;
};

static void set_dot(void *p, long index, int32_t x, int32_t y)
{
	struct set_ctx *c = p;
	if (c->dash_sum > 0 && index % c->dash_sum >= c->dash_on) {
		return;
	}
	if (x < 0 || y < 0 || x >= c->width || y >= c->height) {
		return;
	}
	if (c->mask) {
		c->mask[(long)y * c->width + x] = 1;
	} else {
		c->dots[(long)y * c->width + x] = c->color;
	}
}

/*
 * polyline(dots, xs, ys, color, dash_on, dash_sum) -> true, or nil if the
 * Ruby mirror must draw it (non-contiguous or non-DFloat inputs, or more
 * dots than Geometry.line_points draws unsampled).  +dash_sum+ 0 is solid.
 */
static VALUE ruby_polyline(VALUE self, VALUE dots_v, VALUE xs_v, VALUE ys_v, VALUE color_v, VALUE dash_on_v, VALUE dash_sum_v)
{
	struct set_ctx c;
	c.dots = dots_ptr(dots_v, &c.width, &c.height);
	if (!contiguous_1d(xs_v, numo_cDFloat) || !contiguous_1d(ys_v, numo_cDFloat) ||
			RNARRAY_SHAPE(xs_v)[0] != RNARRAY_SHAPE(ys_v)[0]) {
		return Qnil;
	}
	c.mask = NULL;
	c.color = (uint16_t)NUM2UINT(color_v);
	c.dash_on = NUM2LONG(dash_on_v);
	c.dash_sum = NUM2LONG(dash_sum_v);

	const double *xs = dfloat_ptr(xs_v);
	const double *ys = dfloat_ptr(ys_v);
	long n = (long)RNARRAY_SHAPE(xs_v)[0];

	// (walk_line counts before drawing, so an oversize line draws nothing)
	return walk_line(xs, ys, n, set_dot, &c) < 0 ? Qnil : Qtrue;
}

/*
 * area(dots, xs, ys, base, fill_color, line_color) -> true or nil: the
 * polyline's dots in +line_color+ over a fill in +fill_color+ from each
 * column's dots to device row +base+ (a Float, rounded and clamped).
 */
static VALUE ruby_area(VALUE self, VALUE dots_v, VALUE xs_v, VALUE ys_v, VALUE base_v, VALUE fill_v, VALUE line_v)
{
	long width, height;
	uint16_t *dots = dots_ptr(dots_v, &width, &height);
	if (!contiguous_1d(xs_v, numo_cDFloat) || !contiguous_1d(ys_v, numo_cDFloat) ||
			RNARRAY_SHAPE(xs_v)[0] != RNARRAY_SHAPE(ys_v)[0]) {
		return Qnil;
	}
	const double *xs = dfloat_ptr(xs_v);
	const double *ys = dfloat_ptr(ys_v);
	long n = (long)RNARRAY_SHAPE(xs_v)[0];
	if (width == 0 || height == 0) {
		return Qtrue;
	}

	struct set_ctx c;
	c.dots = NULL;
	c.width = width;
	c.height = height;
	c.color = 0;
	c.dash_on = 0;
	c.dash_sum = 0;
	uint8_t *mask = ZALLOC_N(uint8_t, (size_t)(width * height));
	c.mask = mask;
	if (walk_line(xs, ys, n, set_dot, &c) < 0) {
		xfree(mask);
		return Qnil;
	}

	// Ruby: base.round.clamp(0, height - 1)
	double bf = NUM2DBL(base_v);
	long b = (long)round(bf);
	if (b < 0) {
		b = 0;
	}
	if (b > height - 1) {
		b = height - 1;
	}

	uint16_t fill = (uint16_t)NUM2UINT(fill_v);
	uint16_t line = (uint16_t)NUM2UINT(line_v);
	for (long x = 0; x < width; x++) {
		long top = -1, bot = -1;
		for (long y = 0; y < height; y++) {
			if (mask[y * width + x]) {
				if (top < 0) {
					top = y;
				}
				bot = y;
			}
		}
		if (top < 0) {
			continue;
		}
		if (top > b) {
			top = b;
		}
		if (bot < b) {
			bot = b;
		}
		for (long y = top; y <= bot; y++) {
			dots[y * width + x] = fill;
		}
	}
	for (long i = 0; i < width * height; i++) {
		if (mask[i]) {
			dots[i] = line;
		}
	}
	xfree(mask);
	return Qtrue;
}
/* ------------------------------------------------------------------ */
/* Grid#compose                                                         */
/* ------------------------------------------------------------------ */

// FastUI::Grid is mb-term's native grid (MB::Term::FastTerm::Grid, cells
// in mb_term_grid.h) plus #compose, the plot canvases' packing of dots
// into characters.
static inline struct mb_term_grid *get_grid(VALUE self)
{
	return mb_term_grid_get(self);
}

// Canvas kinds for #compose (Plot::Text::Canvas::KINDS)
enum { CANVAS_BRAILLE, CANVAS_HALF, CANVAS_QUADRANT, CANVAS_SEXTANT, CANVAS_EIGHTHS, CANVAS_ASCII };

/*
 * compose(dots, canvas, cw, ch, px, py, pw, ph, prio, colors, table):
 * turns a pw*cw x ph*ch raster of color indexes into characters at cell
 * (px, py) (Canvas.cells + Panel#compose without a heatmap layer).
 * +prio+ (Int32) is each color index's priority, +colors+ (Int32) each
 * index's 0xRRGGBB (index 0 unused), +table+ (Int32) the canvas's
 * codepoints: Braille 256, quadrants 16, sextants 64, ASCII 8, half
 * [' ', full, upper, lower], eighths LOWER[0..8] + [upper half, upper 1/8].
 * Cells that come out blank with no background are left as they were.
 */
static VALUE grid_compose(int argc, VALUE *argv, VALUE self)
{
	if (argc != 11) {
		rb_raise(rb_eArgError, "compose takes 11 arguments, not %d", argc);
	}
	struct mb_term_grid *g = get_grid(self);
	long dw, dh;
	uint16_t *dots = dots_ptr(argv[0], &dw, &dh);
	int canvas = NUM2INT(argv[1]);
	long cw = NUM2LONG(argv[2]);
	long ch = NUM2LONG(argv[3]);
	long px = NUM2LONG(argv[4]);
	long py = NUM2LONG(argv[5]);
	long pw = NUM2LONG(argv[6]);
	long ph = NUM2LONG(argv[7]);
	VALUE prio_v = argv[8], colors_v = argv[9], table_v = argv[10];
	if (!contiguous_1d(prio_v, numo_cInt32) || !contiguous_1d(colors_v, numo_cInt32) || !contiguous_1d(table_v, numo_cInt32)) {
		rb_raise(rb_eArgError, "prio, colors, and table must be contiguous 1D Numo::Int32s");
	}
	if (dw != pw * cw || dh != ph * ch || cw * ch > 8 || cw < 1 || ch < 1) {
		rb_raise(rb_eArgError, "The dots don't fit %ldx%ld cells of %ldx%ld", pw, ph, cw, ch);
	}
	const int32_t *prio = (const int32_t *)(nary_get_pointer_for_read(prio_v) + nary_get_offset(prio_v));
	const int32_t *colors = (const int32_t *)(nary_get_pointer_for_read(colors_v) + nary_get_offset(colors_v));
	const int32_t *table = (const int32_t *)(nary_get_pointer_for_read(table_v) + nary_get_offset(table_v));
	long nprio = (long)RNARRAY_SHAPE(prio_v)[0];
	long ncolors = (long)RNARRAY_SHAPE(colors_v)[0];
	long ntable = (long)RNARRAY_SHAPE(table_v)[0];
	static const long table_len[] = { 256, 4, 16, 64, 11, 8 };
	if (canvas < 0 || canvas > CANVAS_ASCII || ntable != table_len[canvas]) {
		rb_raise(rb_eArgError, "Bad canvas %d or table length %ld", canvas, ntable);
	}
	long k = cw * ch;
	for (long i = 0; i < dw * dh; i++) {
		if (dots[i] >= nprio || dots[i] >= ncolors) {
			rb_raise(rb_eIndexError, "Color index %u has no priority or color", dots[i]);
		}
	}

	static const int braille_weights[8] = { 1, 8, 2, 16, 4, 32, 64, 128 };
	uint16_t d[8];
	int32_t pr[8];

	for (long r = 0; r < ph; r++) {
		long gy = py + r;
		for (long c = 0; c < pw; c++) {
			long gx = px + c;
			// The cell's dots in row-major order within the cell
			int any = 0;
			for (long dy = 0; dy < ch; dy++) {
				for (long dx = 0; dx < cw; dx++) {
					uint16_t v = dots[(r * ch + dy) * dw + c * cw + dx];
					d[dy * cw + dx] = v;
					pr[dy * cw + dx] = prio[v];
					any |= v;
				}
			}
			if (!any) {
				// Every canvas draws an empty cell as a blank with no
				// background, which leaves the cell as it was
				continue;
			}
			// Foreground: the first dot of the highest priority
			long best = 0;
			for (long j = 1; j < k; j++) {
				if (pr[j] > pr[best]) {
					best = j;
				}
			}
			int fgi = d[best];
			int bgi = 0;
			int rev = 0;
			uint32_t cp = ' ';

			switch (canvas) {
			case CANVAS_BRAILLE: {
				int code = 0;
				for (long j = 0; j < 8; j++) {
					if (d[j]) {
						code += braille_weights[j];
					}
				}
				cp = (uint32_t)table[code];
				break;
			}
			case CANVAS_HALF: {
				int t = d[0], b = d[1];
				fgi = 0;
				if (t == 0 && b == 0) {
					cp = (uint32_t)table[0];
				} else if (t == b) {
					cp = (uint32_t)table[1];
					fgi = t;
				} else if (b == 0) {
					cp = (uint32_t)table[2];
					fgi = t;
				} else if (t == 0) {
					cp = (uint32_t)table[3];
					fgi = b;
				} else {
					cp = (uint32_t)table[2];
					fgi = t;
					bgi = b;
				}
				break;
			}
			case CANVAS_QUADRANT:
			case CANVAS_SEXTANT: {
				int code = 0, n_other = 0, n_empty = 0;
				// The second color: the first other-colored dot of the
				// lowest priority
				long second = 0;
				int32_t second_p = 0;
				int found = 0;
				for (long j = 0; j < k; j++) {
					int set = d[j] > 0;
					int on = set && d[j] == fgi;
					if (on) {
						code |= 1 << j;
					}
					if (!set) {
						n_empty++;
					}
					if (set && !on) {
						n_other++;
						if (!found || pr[j] < second_p) {
							second_p = pr[j];
							second = j;
							found = 1;
						}
					}
				}
				if (n_other > 0 && n_other >= n_empty) {
					bgi = d[second];
				}
				cp = (uint32_t)table[code];
				break;
			}
			case CANVAS_EIGHTHS: {
				int cnt = 0, first = -1, last = -1;
				for (long j = 0; j < k; j++) {
					if (d[j]) {
						cnt++;
						if (first < 0) {
							first = (int)j;
						}
						last = (int)j;
					}
				}
				if (cnt == 0) {
					cp = ' ';
					break;
				}
				if (first == 0 && last == 7) {
					cp = (uint32_t)table[8];
				} else if (last == 7 || (7 - last) <= first) {
					cp = (uint32_t)table[8 - first];
				} else if (last == 3) {
					cp = (uint32_t)table[9];
				} else if (last == 0) {
					cp = (uint32_t)table[10];
				} else {
					cp = (uint32_t)table[7 - last];
					rev = 1;
				}
				break;
			}
			case CANVAS_ASCII: {
				int code = (d[0] ? 1 : 0) | (d[1] ? 2 : 0) | (d[2] ? 4 : 0);
				cp = (uint32_t)table[code];
				break;
			}
			}

			int32_t f = fgi > 0 ? colors[fgi] : -1;
			int32_t b = bgi > 0 ? colors[bgi] : -1;
			if (cp == ' ' && b < 0) {
				continue;
			}
			if (gx < 0 || gy < 0 || gx >= g->width || gy >= g->height) {
				continue;
			}
			long i = gy * g->width + gx;
			g->cp[i] = cp;
			g->fg[i] = f;
			g->bg[i] = b;
			g->attr[i] = rev ? MB_TERM_ATTR_REVERSE : 0;
		}
	}
	return Qnil;
}

/* ANSI colors (Plot::Text::ANSI) */
void Init_fast_ui(void)
{
#ifdef HAVE_RB_EXT_RACTOR_SAFE
	rb_ext_ractor_safe(true);
#endif
	VALUE mMB = rb_define_module("MB");
	VALUE mSound = rb_define_module_under(mMB, "Sound");
	mFastUI = rb_define_module_under(mSound, "FastUI");

	rb_define_module_function(mFastUI, "decimate", ruby_decimate, 5);
	rb_define_module_function(mFastUI, "polyline", ruby_polyline, 6);
	rb_define_module_function(mFastUI, "area", ruby_area, 6);
	rb_define_module_function(mFastUI, "project", ruby_project, 7);
	rb_define_module_function(mFastUI, "monotonic", ruby_monotonic, 1);

	// (mb-term's fast_term, loaded by require 'mb/term' before this file:
	// its mb_term_grid_get is linked at load time)
	VALUE cTermGrid = rb_path2class("MB::Term::FastTerm::Grid");
	cGrid = rb_define_class_under(mFastUI, "Grid", cTermGrid);
	rb_define_method(cGrid, "compose", grid_compose, -1);

	mb_fast_ui_init_gvl_probe(mFastUI);
}
