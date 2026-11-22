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
 * threads) for the dashboard band (ui-3; design/notes/terminal_ui.md);
 * gvl_yield.c FastUI::GVLYield (preview workers hand the GVL to the render
 * thread when it wants it; design/notes/sound_design_ui.md).
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
// gvl_yield.c
void mb_fast_ui_init_gvl_yield(VALUE mFastUI);

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

// One value of #project's map (see ruby_project)
static inline double project_one(double x, int kind, double lo, double span, int reverse, double mul, int flip)
{
	double u;
	if (kind == 1) {
		if (x <= 0) {
			x = NAN;
		}
		u = (log10(x) - lo) / span;
	} else {
		u = (x - lo) / span;
	}
	if (reverse) {
		u = 1 - u;
	}
	return flip ? (1 - u) * mul : u * mul;
}

// Groups the regular decimation makes of +n+ points over +columns+
static inline void regular_groups(long n, long columns, int ends, long *g, long *groups)
{
	*g = ends ? (long)ceil((double)n / (double)columns) : (long)floor((double)n / (double)columns);
	if (*g < 1) {
		*g = 1;
	}
	*groups = (long)ceil((double)n / (double)*g);
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
		long g, groups;
		regular_groups(n, columns, ends, &g, &groups);
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
		out[i] = project_one(v[i], kind, lo, span, reverse, mul, flip);
	}
	return out_v;
}

// Longest group #trace takes (its projected values live on the stack)
#define TRACE_GROUP_MAX 4096

/*
 * trace(ox, oy, dx, ys, kind, lo, span, reverse, mul, flip, columns, ends)
 * -> true, or nil when it can't take the arguments (the caller runs its
 * Ruby mirror): a live scope's line without allocating (ui-perf-2;
 * Plot::Trace).  Writes into +ox+ and +oy+ (contiguous 1D DFloats of the
 * regular decimation's length, 2 points a group) exactly what
 * decimate(dx, project(ys, kind, lo, span, reverse, mul, flip), columns,
 * true, ends) returns, +dx+ being the device x of each point (a contiguous
 * DFloat, as long as +ys+) and +ys+ a contiguous 1D DFloat or SFloat (read
 * as doubles, as Numo's cast to DFloat does).  Needs ys.length > columns * 2.
 */
static VALUE ruby_trace(int argc, VALUE *argv, VALUE self)
{
	if (argc != 12) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 12)", argc);
	}
	VALUE ox_v = argv[0], oy_v = argv[1], dx_v = argv[2], ys_v = argv[3];
	int single = contiguous_1d(ys_v, numo_cSFloat);
	if (!contiguous_1d(ox_v, numo_cDFloat) || !contiguous_1d(oy_v, numo_cDFloat) || !contiguous_1d(dx_v, numo_cDFloat) ||
			(!single && !contiguous_1d(ys_v, numo_cDFloat))) {
		return Qnil;
	}
	long n = (long)RNARRAY_SHAPE(ys_v)[0];
	long columns = NUM2LONG(argv[10]);
	int ends = RTEST(argv[11]);
	if ((long)RNARRAY_SHAPE(dx_v)[0] != n || n <= columns * 2 || columns < 1) {
		return Qnil;
	}
	long g, groups;
	regular_groups(n, columns, ends, &g, &groups);
	if (g > TRACE_GROUP_MAX || (long)RNARRAY_SHAPE(ox_v)[0] != groups * 2 || (long)RNARRAY_SHAPE(oy_v)[0] != groups * 2) {
		return Qnil;
	}
	int kind = NUM2INT(argv[4]);
	double lo = NUM2DBL(argv[5]);
	double span = NUM2DBL(argv[6]);
	int reverse = RTEST(argv[7]);
	double mul = NUM2DBL(argv[8]);
	int flip = RTEST(argv[9]);

	const double *xs = dfloat_ptr(dx_v);
	const char *yp = nary_get_pointer_for_read(ys_v) + nary_get_offset(ys_v);
	const float *yf = (const float *)yp;
	const double *yd = (const double *)yp;
	double *ox = (double *)(nary_get_pointer_for_write(ox_v) + nary_get_offset(ox_v));
	double *oy = (double *)(nary_get_pointer_for_write(oy_v) + nary_get_offset(oy_v));
	double buf[TRACE_GROUP_MAX];
	for (long k = 0; k < groups; k++) {
		long a = k * g;
		for (long j = 0; j < g; j++) {
			long i = a + j;
			i = i < n ? i : n - 1;
			buf[j] = project_one(single ? (double)yf[i] : yd[i], kind, lo, span, reverse, mul, flip);
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
	return Qtrue;
}

/*
 * copy(dst, src) -> true, or nil unless both are contiguous NArrays of the
 * same class and shape (the caller assigns in Ruby): src's elements into
 * dst without allocating (Raster#restore; ui-perf-2).
 */
static VALUE ruby_copy(VALUE self, VALUE dst_v, VALUE src_v)
{
	if (!rb_obj_is_kind_of(dst_v, numo_cNArray) || CLASS_OF(dst_v) != CLASS_OF(src_v) ||
			RNARRAY_NDIM(dst_v) != RNARRAY_NDIM(src_v) || RNARRAY_SIZE(dst_v) != RNARRAY_SIZE(src_v) ||
			!RTEST(nary_check_contiguous(dst_v)) || !RTEST(nary_check_contiguous(src_v))) {
		return Qnil;
	}
	for (int i = 0; i < RNARRAY_NDIM(dst_v); i++) {
		if (RNARRAY_SHAPE(dst_v)[i] != RNARRAY_SHAPE(src_v)[i]) {
			return Qnil;
		}
	}
	size_t bytes = RNARRAY_SIZE(dst_v) * nary_element_stride(dst_v);
	if (bytes) {
		memmove(nary_get_pointer_for_write(dst_v) + nary_get_offset(dst_v),
			nary_get_pointer_for_read(src_v) + nary_get_offset(src_v), bytes);
	}
	return Qtrue;
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

// Braille dot bits by dot row in a cell (0..3) and dot column (0..1)
static const uint8_t braille_bit[4][2] = { { 0x01, 0x08 }, { 0x02, 0x10 }, { 0x04, 0x20 }, { 0x40, 0x80 } };

// The dot row (0 top .. rows - 1 bottom) of +v+ between +lo+ and +hi+
static inline long wave_row(double v, double lo, double hi, long rows)
{
	double r = round((hi - v) / (hi - lo) * (double)(rows - 1));
	if (!(r > 0.0)) {
		return 0;
	}
	if (r > (double)(rows - 1)) {
		return rows - 1;
	}
	return (long)r;
}

/*
 * wave(grid, data, x, y, w, h, lo, hi, fg, mark, mark_fg) -> nil
 *
 * Draws +data+ (a contiguous 1D SFloat, e.g. one cycle of an oscillator)
 * as a Braille line across the grid's rectangle of +w+ x +h+ cells at
 * (+x+, +y+), +lo+ at the bottom dot row and +hi+ at the top, clearing
 * the rectangle first (ui-wave-perf-1; mirror Plot::Wave.draw_ruby).
 * Each of the 2 * w dot columns shows the min and max of the samples it
 * covers (as many samples as columns or more) or the value linearly
 * interpolated at its position (fewer), joined to the previous column's
 * last value so the line has no gaps.  +mark+ is a dot column for a
 * dotted vertical marker (a playhead; -1 for none), drawn in +mark_fg+
 * where its cells hold no line.  Colors are packed (0xRRGGBB,
 * MB_TERM_COLOR_INDEXED | n, -1 none).  NaN samples leave their column
 * empty.
 */
static VALUE ruby_wave(VALUE self, VALUE grid, VALUE data, VALUE x_v, VALUE y_v, VALUE w_v, VALUE h_v, VALUE lo_v, VALUE hi_v,
		VALUE fg_v, VALUE mark_v, VALUE mark_fg_v)
{
	(void)self;
	struct mb_term_grid *g = mb_term_grid_get(grid);
	if (!contiguous_1d(data, numo_cSFloat)) {
		rb_raise(rb_eArgError, "The data must be a contiguous 1D Numo::SFloat");
	}
	long x0 = NUM2LONG(x_v), y0 = NUM2LONG(y_v), w = NUM2LONG(w_v), h = NUM2LONG(h_v);
	double lo = NUM2DBL(lo_v), hi = NUM2DBL(hi_v);
	int32_t fg = NUM2INT(fg_v);
	long mark = NUM2LONG(mark_v);
	int32_t mark_fg = NUM2INT(mark_fg_v);
	const float *d = (const float *)(nary_get_pointer_for_read(data) + nary_get_offset(data));
	long n = (long)RNARRAY_SIZE(data);
	if (w <= 0 || h <= 0) {
		return Qnil;
	}

	// Clear the rectangle (clipped to the grid)
	for (long cy = 0; cy < h; cy++) {
		long gy = y0 + cy;
		if (gy < 0 || gy >= g->height) {
			continue;
		}
		for (long cx = 0; cx < w; cx++) {
			long gx = x0 + cx;
			if (gx < 0 || gx >= g->width) {
				continue;
			}
			long i = gy * g->width + gx;
			g->cp[i] = ' ';
			g->fg[i] = -1;
			g->bg[i] = -1;
			g->attr[i] = 0;
		}
	}
	if (n <= 0 || !(hi > lo)) {
		return Qnil;
	}

	long cols = 2 * w, rows = 4 * h;
	uint8_t *bits = ALLOC_N(uint8_t, h);
	uint8_t *marks = ALLOC_N(uint8_t, h);
	long prev = -1;
	for (long cx = 0; cx < w; cx++) {
		memset(bits, 0, (size_t)h);
		memset(marks, 0, (size_t)h);
		for (int dx = 0; dx < 2; dx++) {
			long c = 2 * cx + dx;
			long top, bot, last;
			if (n >= cols) {
				long i0 = c * n / cols;
				long i1 = (c + 1) * n / cols;
				if (i1 <= i0) {
					i1 = i0 + 1;
				}
				int seen = 0;
				double mn = 0.0, mx = 0.0;
				for (long i = i0; i < i1; i++) {
					double v = (double)d[i];
					if (isnan(v)) {
						continue;
					}
					if (!seen) {
						mn = mx = v;
						seen = 1;
					} else if (v < mn) {
						mn = v;
					} else if (v > mx) {
						mx = v;
					}
				}
				if (!seen) {
					prev = -1;
					continue;
				}
				double lv = (double)d[i1 - 1];
				top = wave_row(mx, lo, hi, rows);
				bot = wave_row(mn, lo, hi, rows);
				last = isnan(lv) ? -1 : wave_row(lv, lo, hi, rows);
			} else {
				double pos = cols > 1 ? (double)c * (double)(n - 1) / (double)(cols - 1) : 0.0;
				long j = (long)floor(pos);
				if (j > n - 1) {
					j = n - 1;
				}
				long j1 = j + 1 < n ? j + 1 : n - 1;
				double a = (double)d[j], b = (double)d[j1];
				double v = a + (b - a) * (pos - (double)j);
				if (isnan(v)) {
					prev = -1;
					continue;
				}
				top = bot = last = wave_row(v, lo, hi, rows);
			}
			if (prev >= 0) {
				if (prev < top) {
					top = prev;
				}
				if (prev > bot) {
					bot = prev;
				}
			}
			for (long r = top; r <= bot; r++) {
				bits[r / 4] |= braille_bit[r % 4][dx];
			}
			prev = last;
		}
		if (mark >= 0 && mark / 2 == cx) {
			int dx = (int)(mark % 2);
			for (long r = 0; r < rows; r += 2) {
				marks[r / 4] |= braille_bit[r % 4][dx];
			}
		}
		long gx = x0 + cx;
		if (gx < 0 || gx >= g->width) {
			continue;
		}
		for (long cy = 0; cy < h; cy++) {
			long gy = y0 + cy;
			uint8_t b = bits[cy] | marks[cy];
			if (b == 0 || gy < 0 || gy >= g->height) {
				continue;
			}
			long i = gy * g->width + gx;
			g->cp[i] = 0x2800u + b;
			g->fg[i] = bits[cy] ? fg : mark_fg;
		}
	}
	xfree(bits);
	xfree(marks);
	return Qnil;
}

/* ANSI colors (Plot::Text::ANSI) */
#define MB_RESPONSE_MAX_COEFFS 16

// Reads up to MB_RESPONSE_MAX_COEFFS coefficients from Ruby Array +ary+
static long response_coeffs(VALUE ary, double *c, const char *name)
{
	Check_Type(ary, T_ARRAY);
	long n = RARRAY_LEN(ary);
	if (n < 1 || n > MB_RESPONSE_MAX_COEFFS) {
		rb_raise(rb_eArgError, "The %s coefficients must be 1 to %d numbers (got %ld)", name, MB_RESPONSE_MAX_COEFFS, n);
	}
	for (long i = 0; i < n; i++) {
		c[i] = NUM2DBL(RARRAY_AREF(ary, i));
	}
	return n;
}

/*
 * response_db(out, b, a, rate, lo, hi, floor) -> out
 *
 * The magnitude in dB of H(z) = B(z^-1) / A(z^-1) (+b+ and +a+: Arrays of
 * up to 16 coefficients, lowest power first) at out.size log-spaced
 * frequencies from +lo+ to +hi+ Hz at sample rate +rate+, written into
 * +out+ (a contiguous 1D SFloat), each at least +floor+ dB.  Allocates
 * nothing (the sound-design screen's live filter curves, every frame;
 * ui-wave-perf-1; mirror Plot::Response.db_ruby).
 */
static VALUE ruby_response_db(VALUE self, VALUE out, VALUE b_v, VALUE a_v, VALUE rate_v, VALUE lo_v, VALUE hi_v, VALUE floor_v)
{
	(void)self;
	if (!contiguous_1d(out, numo_cSFloat)) {
		rb_raise(rb_eArgError, "The output must be a contiguous 1D Numo::SFloat");
	}
	rb_check_frozen(out);
	double b[MB_RESPONSE_MAX_COEFFS], a[MB_RESPONSE_MAX_COEFFS];
	long nb = response_coeffs(b_v, b, "numerator");
	long na = response_coeffs(a_v, a, "denominator");
	double rate = NUM2DBL(rate_v), lo = NUM2DBL(lo_v), hi = NUM2DBL(hi_v), floor_db = NUM2DBL(floor_v);
	if (!(rate > 0.0) || !(lo > 0.0) || !(hi > 0.0) || !isfinite(rate) || !isfinite(lo) || !isfinite(hi) || isnan(floor_db)) {
		rb_raise(rb_eArgError, "The rate and frequencies must be positive and finite, and the floor a number");
	}
	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	long n = (long)RNARRAY_SIZE(out);
	double l0 = log10(lo), l1 = log10(hi);
	double step = n > 1 ? (l1 - l0) / (double)(n - 1) : 0.0;
	double floor_mag = pow(10.0, floor_db / 20.0);
	for (long i = 0; i < n; i++) {
		double f = pow(10.0, l0 + step * (double)i);
		double w = 2.0 * 3.14159265358979323846 * f / rate;
		// z^-1 = cos w - j sin w; Horner from the highest power
		double zr = cos(w), zi = -sin(w);
		double br = b[nb - 1], bi = 0.0;
		for (long k = nb - 2; k >= 0; k--) {
			double tr = br * zr - bi * zi + b[k];
			bi = br * zi + bi * zr;
			br = tr;
		}
		double ar = a[na - 1], ai = 0.0;
		for (long k = na - 2; k >= 0; k--) {
			double tr = ar * zr - ai * zi + a[k];
			ai = ar * zi + ai * zr;
			ar = tr;
		}
		double mag = sqrt((br * br + bi * bi) / (ar * ar + ai * ai));
		if (!(mag >= floor_mag)) {
			mag = floor_mag; // (NaN too: a zero over a zero)
		}
		o[i] = (float)(20.0 * log10(mag));
	}
	RB_GC_GUARD(out);
	return out;
}

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
	rb_define_module_function(mFastUI, "trace", ruby_trace, -1);
	rb_define_module_function(mFastUI, "copy", ruby_copy, 2);
	rb_define_module_function(mFastUI, "wave", ruby_wave, 11);
	rb_define_module_function(mFastUI, "response_db", ruby_response_db, 7);

	// (mb-term's fast_term, loaded by require 'mb/term' before this file:
	// its mb_term_grid_get is linked at load time)
	VALUE cTermGrid = rb_path2class("MB::Term::FastTerm::Grid");
	cGrid = rb_define_class_under(mFastUI, "Grid", cTermGrid);
	rb_define_method(cGrid, "compose", grid_compose, -1);

	mb_fast_ui_init_gvl_probe(mFastUI);
	mb_fast_ui_init_gvl_yield(mFastUI);
}
