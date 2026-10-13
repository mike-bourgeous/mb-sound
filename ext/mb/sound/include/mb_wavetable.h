/*
 * The band-limited wavetable kernels' shared parts (see fast_wavetable.c
 * for the design): table and interpolation readers, level selection,
 * interpolation, warp corners, and the cycle-mode oscillator loop
 * (mb_wt_oscillate).  Shared by fast_wavetable (FastWavetable.oscillate)
 * and fast_plan (planned wavetable tones, plan_wavetable.c), so both run
 * the same operations.  Both build it without contraction into
 * multiply-adds: fast_wavetable with -ffp-contract=off, plan_wavetable.c
 * with clang's FP_CONTRACT OFF pragma (GCC's -std=c99 doesn't contract).
 * Moved here from fast_wavetable.c (2026-10-10, plan layer P3b).
 */
#ifndef MB_WAVETABLE_H
#define MB_WAVETABLE_H

#include <math.h>
#include <stdint.h>

#include <ruby.h>

#include "numo/narray.h"
#include "mb_ext_helpers.h"
#include "mb_phase.h"

#define WT_MAX_LEVELS 64
#define WT_DERIV_ORDERS 2 // value and slope (phase warp corners)
#define WT_GUARD 16 // Wavetable::GUARD
#define WT_MAX_TAPS 64 // sync residual taps (BandLimit::SYNC_TAPS)
#define WT_MIN_WIDTH 1e-4

enum wt_interp {
	WT_NONE = 0,
	WT_LINEAR = 1,
	WT_CUBIC = 2,
	WT_OPTIMAL = 3,
	WT_SINC = 4,
};

enum wt_wrap {
	WT_WRAP = 0,
	WT_BOUNCE = 1,
	WT_CLAMP = 2,
	WT_ZERO = 3,
	WT_SHAPE = 4,
};

// Phase-driven lookups without increments estimate the speed from the
// phase change per sample, holding its peak for WT_HOLD samples, then
// releasing by WT_RELEASE per sample, so levels don't flicker within a
// cycle (see ruby_lookup).
#define WT_HOLD 1024
#define WT_RELEASE 0.995

// Niemitalo's optimal 4-point, 4th-order interpolator for 4x oversampled
// data (z-form; see Wavetable::KernelRuby::OPTIMAL).
#define OPT_C0E 0.46567255120778489
#define OPT_C0O 0.03432729708429672
#define OPT_C1E 0.53743830753560162
#define OPT_C1O 0.15429462557307461
#define OPT_C2E -0.251942101340217441
#define OPT_C2O 0.25194744935939062
#define OPT_C3E -0.46896069955075126
#define OPT_C3O 0.15578800670302476
#define OPT_C4E 0.00986988334359864
#define OPT_C4O -0.00989340017126506

// floor() without a library call (x86-64 compilers call floor() unless
// SSE4.1 is enabled); the same result for any value that fits a long.
static inline __attribute__((always_inline)) double wt_floor(double x)
{
	if (!(fabs(x) < 4.0e18)) {
		return floor(x); // huge values and NaN
	}
	long i = (long)x;
	return (double)(x < (double)i ? i - 1 : i);
}

// Wraps +x+ to 0...+y+ like mb_wrap (and Ruby's %), with wt_floor.
static inline __attribute__((always_inline)) double wt_wrap(double x, double y)
{
	return x - y * wt_floor(x / y);
}

// One level: +data+ points at the first float of the NArray (complex
// values are two floats), +stride+ is the row length in samples.
struct wt_level {
	const float *data;
	long stride;
	long count;
};

struct wt_table {
	int mode; // 0 cycle, 1 sample
	long frames;
	int nlevels;
	int cs; // floats per sample: 1 real, 2 complex
	long guard;
	struct wt_level levels[WT_MAX_LEVELS];
	const double *rates;
	const double *hi;
	const double *lo;
	const double *half_means;
	int has_loop;
	struct wt_level loops[WT_MAX_LEVELS];
	const double *loop_rates;
	double loop_start;
	double loop_end;
	double end;
	const double *spectra; // [frames, spec_cols] complex (re, im pairs), or NULL
	long spec_cols;
	long harmonics[WT_MAX_LEVELS];
	int scan_wrap; // 1: scan positions wrap around (see wt_frames)
};

// The sinc kernel (Wavetable::SINC_KERNEL: [table DFloat, half, resolution,
// max_rate]).
struct wt_sinc {
	const double *table;
	long table_length;
	double half;
	double resolution;
};

static inline const double *wt_dfloat(VALUE v, long length, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || RNARRAY_SHAPE(v)[0] < (size_t)length) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D DFloat of at least %ld values", name, length);
	}
	return (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

// Reads an Array of level NArrays into +levels+, returning the count.
static inline int wt_read_levels(VALUE datas, VALUE counts, struct wt_level *levels, long rows, long guard, VALUE *klass)
{
	Check_Type(datas, T_ARRAY);
	Check_Type(counts, T_ARRAY);
	long n = RARRAY_LEN(datas);
	if (n < 1 || n > WT_MAX_LEVELS || RARRAY_LEN(counts) != n) {
		rb_raise(rb_eArgError, "A wavetable needs 1 to %d levels with a count for each", WT_MAX_LEVELS);
	}

	for (long k = 0; k < n; k++) {
		VALUE d = rb_ary_entry(datas, k);
		VALUE c = CLASS_OF(d);
		if ((c != numo_cSFloat && c != numo_cSComplex) || RNARRAY_NDIM(d) != 2 || !RTEST(nary_check_contiguous(d))) {
			rb_raise(rb_eArgError, "Wavetable levels must be contiguous 2D SFloat or SComplex NArrays");
		}
		if (*klass == Qnil) {
			*klass = c;
		} else if (*klass != c) {
			rb_raise(rb_eArgError, "Wavetable levels must all be real or all complex");
		}
		if ((long)RNARRAY_SHAPE(d)[0] != rows) {
			rb_raise(rb_eArgError, "Wavetable level %ld has %ld rows instead of %ld", k, (long)RNARRAY_SHAPE(d)[0], rows);
		}

		long count = NUM2LONG(rb_ary_entry(counts, k));
		long stride = RNARRAY_SHAPE(d)[1];
		if (count < 0 || stride != count + 2 * guard) {
			rb_raise(rb_eArgError, "Wavetable level %ld must have %ld + 2 * %ld guard samples per row", k, count, guard);
		}

		levels[k].data = (const float *)(nary_get_pointer_for_read(d) + nary_get_offset(d));
		levels[k].stride = stride;
		levels[k].count = count;
	}

	return (int)n;
}

// Reads a Wavetable#kernel_spec (which must stay referenced while used).
static inline void wt_read_table(VALUE spec, struct wt_table *t)
{
	Check_Type(spec, T_ARRAY);
	if (RARRAY_LEN(spec) != 18) {
		rb_raise(rb_eArgError, "A wavetable kernel spec has 18 elements");
	}

	t->mode = NUM2INT(rb_ary_entry(spec, 0));
	t->frames = NUM2LONG(rb_ary_entry(spec, 1));
	t->guard = NUM2LONG(rb_ary_entry(spec, 14));
	if (t->frames < 1 || (t->mode != 0 && t->mode != 1) || t->guard != WT_GUARD) {
		rb_raise(rb_eArgError, "Invalid wavetable mode, frame count, or guard");
	}

	VALUE klass = Qnil;
	t->nlevels = wt_read_levels(rb_ary_entry(spec, 2), rb_ary_entry(spec, 3), t->levels, t->frames, t->guard, &klass);
	t->cs = klass == numo_cSComplex ? 2 : 1;
	t->rates = wt_dfloat(rb_ary_entry(spec, 4), t->nlevels, "Level rates");
	t->hi = wt_dfloat(rb_ary_entry(spec, 5), t->nlevels, "Level thresholds");
	t->lo = wt_dfloat(rb_ary_entry(spec, 6), t->nlevels, "Level thresholds");
	t->half_means = wt_dfloat(rb_ary_entry(spec, 7), t->frames, "Half means");

	VALUE loops = rb_ary_entry(spec, 8);
	t->has_loop = !NIL_P(loops);
	if (t->has_loop) {
		if (t->mode != 1 || t->frames != 1) {
			rb_raise(rb_eArgError, "Only one-frame sample tables can loop");
		}
		VALUE loop_klass = klass;
		int n = wt_read_levels(loops, rb_ary_entry(spec, 9), t->loops, 1, t->guard, &loop_klass);
		if (n != t->nlevels) {
			rb_raise(rb_eArgError, "A looped wavetable needs a loop level for each level");
		}
		t->loop_rates = wt_dfloat(rb_ary_entry(spec, 10), n, "Loop rates");
	}

	t->loop_start = NUM2DBL(rb_ary_entry(spec, 11));
	t->loop_end = NUM2DBL(rb_ary_entry(spec, 12));
	t->end = NUM2DBL(rb_ary_entry(spec, 13));

	VALUE spectra = rb_ary_entry(spec, 15);
	t->spectra = NULL;
	t->spec_cols = 0;
	t->scan_wrap = NUM2INT(rb_ary_entry(spec, 17)) != 0;
	if (!NIL_P(spectra)) {
		if (CLASS_OF(spectra) != numo_cDComplex || RNARRAY_NDIM(spectra) != 2 || !RTEST(nary_check_contiguous(spectra)) ||
				(long)RNARRAY_SHAPE(spectra)[0] != t->frames) {
			rb_raise(rb_eArgError, "Derivative spectra must be a contiguous 2D DComplex with a row per frame");
		}
		t->spectra = (const double *)(nary_get_pointer_for_read(spectra) + nary_get_offset(spectra));
		t->spec_cols = RNARRAY_SHAPE(spectra)[1];
		VALUE counts = rb_ary_entry(spec, 16);
		Check_Type(counts, T_ARRAY);
		if (RARRAY_LEN(counts) != t->nlevels) {
			rb_raise(rb_eArgError, "Give a harmonic count for each level");
		}
		for (int k = 0; k < t->nlevels; k++) {
			long h = NUM2LONG(rb_ary_entry(counts, k));
			t->harmonics[k] = h < t->spec_cols - 1 ? h : t->spec_cols - 1;
		}
	}
	if (t->has_loop && !(t->loop_end > t->loop_start)) {
		rb_raise(rb_eArgError, "The loop must end after it starts");
	}
}

static inline void wt_read_sinc(VALUE kernel, struct wt_sinc *k)
{
	if (!RB_TYPE_P(kernel, T_ARRAY) || RARRAY_LEN(kernel) != 4) {
		rb_raise(rb_eArgError, "Sinc interpolation needs a kernel Array of [table, half, resolution, max_rate]");
	}

	VALUE table = rb_ary_entry(kernel, 0);
	if (CLASS_OF(table) != numo_cDFloat || RNARRAY_NDIM(table) != 1 || !RTEST(nary_check_contiguous(table))) {
		rb_raise(rb_eArgError, "The sinc kernel table must be a contiguous 1D DFloat NArray");
	}

	k->table = (const double *)(nary_get_pointer_for_read(table) + nary_get_offset(table));
	k->table_length = RNARRAY_SHAPE(table)[0];
	k->half = NUM2DBL(rb_ary_entry(kernel, 1));
	k->resolution = NUM2DBL(rb_ary_entry(kernel, 2));
}

// Reads the interpolation code and (for sinc) its kernel, checking that the
// guard samples cover the interpolator.
static inline int wt_read_interp(VALUE interp, VALUE sinc, const struct wt_table *t, struct wt_sinc *k)
{
	int mode = NUM2INT(interp);
	if (mode < WT_NONE || mode > WT_SINC) {
		rb_raise(rb_eArgError, "Invalid interpolation code %d", mode);
	}

	if (mode == WT_SINC) {
		wt_read_sinc(sinc, k);
		if (k->half + 4 > t->guard) {
			rb_raise(rb_eArgError, "The sinc kernel is too long for the guard samples");
		}
	}

	return mode;
}

// The sinc kernel weight at +x+ samples from its center
// (linearly interpolated in the table).
static inline double wt_sinc_weight(const struct wt_sinc *k, double x)
{
	double u = x * k->resolution;
	long j = (long)u;
	if (j + 1 >= k->table_length) {
		return 0;
	}
	double f = u - j;
	return k->table[j] + (k->table[j + 1] - k->table[j]) * f;
}

// Sample +j+ of row offset +ra+ (blended with row offset +rb+ by +fs+ unless
// +rb+ is negative), from floats +d+ with +cs+ floats per sample.
static inline __attribute__((always_inline)) double wt_tap(const float *d, long cs, long ra, long rb, double fs, long j)
{
	double ya = d[(ra + j) * cs];
	if (rb < 0) {
		return ya;
	}
	double yb = d[(rb + j) * cs];
	return ya + (yb - ya) * fs;
}

// Interpolates at +q+ samples past the guard (one component of the data).
static inline __attribute__((always_inline)) double wt_interpolate(const float *d, long cs, long ra, long rb, double fs, double q, int mode, long guard, const struct wt_sinc *k)
{
	double qi = wt_floor(q);
	double t = q - qi;
	long base = guard + (long)qi;

	switch (mode) {
		case WT_NONE:
			return wt_tap(d, cs, ra, rb, fs, base);

		case WT_LINEAR: {
			double y0 = wt_tap(d, cs, ra, rb, fs, base);
			double y1 = wt_tap(d, cs, ra, rb, fs, base + 1);
			return y0 + (y1 - y0) * t;
		}

		case WT_CUBIC: {
			double ym1 = wt_tap(d, cs, ra, rb, fs, base - 1);
			double y0 = wt_tap(d, cs, ra, rb, fs, base);
			double y1 = wt_tap(d, cs, ra, rb, fs, base + 1);
			double y2 = wt_tap(d, cs, ra, rb, fs, base + 2);
			double c0 = y0;
			double c1 = 0.5 * (y1 - ym1);
			double c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2;
			double c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1);
			return ((c3 * t + c2) * t + c1) * t + c0;
		}

		case WT_OPTIMAL: {
			double ym1 = wt_tap(d, cs, ra, rb, fs, base - 1);
			double y0 = wt_tap(d, cs, ra, rb, fs, base);
			double y1 = wt_tap(d, cs, ra, rb, fs, base + 1);
			double y2 = wt_tap(d, cs, ra, rb, fs, base + 2);
			double z = t - 0.5;
			double even1 = y1 + y0;
			double odd1 = y1 - y0;
			double even2 = y2 + ym1;
			double odd2 = y2 - ym1;
			double c0 = even1 * OPT_C0E + even2 * OPT_C0O;
			double c1 = odd1 * OPT_C1E + odd2 * OPT_C1O;
			double c2 = even1 * OPT_C2E + even2 * OPT_C2O;
			double c3 = odd1 * OPT_C3E + odd2 * OPT_C3O;
			double c4 = even1 * OPT_C4E + even2 * OPT_C4O;
			return (((c4 * z + c3) * z + c2) * z + c1) * z + c0;
		}

		default: {
			if (t == 0) {
				return wt_tap(d, cs, ra, rb, fs, base);
			}
			long kmin = (long)ceil(q - k->half);
			long kmax = (long)floor(q + k->half);
			double sum = 0;
			double wsum = 0;
			for (long kk = kmin; kk <= kmax; kk++) {
				double w = wt_sinc_weight(k, fabs((double)kk - q));
				sum += wt_tap(d, cs, ra, rb, fs, guard + kk) * w;
				wsum += w;
			}
			return wsum != 0 ? sum / wsum : 0;
		}
	}
}

// The frames around +scan+: *fa, *fb (-1 for one frame), and the blend
// *fs.  Frame k sits at k / (count - 1), so 0 is the first and 1 the last.
// Without +wrap+ the scan is clamped to 0..1.  With +wrap+ it repeats every
// count / (count - 1): from 1 to 1 + 1 / (count - 1) the last frame morphs
// into the first (one more frame step), and so on.
static inline __attribute__((always_inline)) void wt_frames(long count, double scan, int wrap, long *fa, long *fb, double *fs)
{
	if (count == 1) {
		*fa = 0;
		*fb = -1;
		*fs = 0;
		return;
	}

	double f = scan * (double)(count - 1);
	if (wrap && f == f && fabs(f) < 4.0e18) {
		f = wt_wrap(f, (double)count);
		if (f >= (double)count) f = 0; // rounding of tiny negative values
		if (f >= (double)(count - 1)) {
			*fa = count - 1;
			*fb = 0;
			*fs = f - (double)(count - 1);
			return;
		}
	}
	if (!(f >= 0)) f = 0; // also NaN
	if (f > count - 1) f = (double)(count - 1);
	double fl = wt_floor(f);
	if (fl > count - 2) fl = (double)(count - 2);
	*fa = (long)fl;
	*fb = *fa + 1;
	*fs = f - fl;
}

// Level +k+ at +u+ (cycles, or source samples in sample mode) into
// *re/*im.
static inline __attribute__((always_inline)) void wt_level_value(const struct wt_table *t, int k, double u, long fa, long fb, double fs, int mode, int cs, const struct wt_sinc *ks, double *re, double *im)
{
	const struct wt_level *l;
	double q;

	*re = 0;
	*im = 0;

	if (t->mode == 0) {
		l = &t->levels[k];
		q = u * t->rates[k];
	} else if (t->has_loop && u >= t->loop_start) {
		l = &t->loops[k];
		q = (u - t->loop_start) * t->loop_rates[k];
		fa = 0;
		fb = -1;
	} else {
		l = &t->levels[k];
		q = u * t->rates[k];
		double i = wt_floor(q);
		double half = 12; // the most taps any interpolator reads on each side (sinc)
		if (i < -(t->guard - half) || i > l->count + t->guard - half - 1) {
			return;
		}
		fa = 0;
		fb = -1;
	}

	long ra = fa * l->stride;
	long rb = fb < 0 ? -1 : fb * l->stride;
	*re = wt_interpolate(l->data, cs, ra, rb, fs, q, mode, WT_GUARD, ks);
	if (cs == 2) {
		*im = wt_interpolate(l->data + 1, cs, ra, rb, fs, q, mode, WT_GUARD, ks);
	}
}

// Levels and frames chosen for a motion +m+ and scan position (see
// wt_select): the first level k, whether to crossfade into k + 1 by x, and
// the frames fa and fb (-1 for none) blended by fs.  Kernels keep one and
// redo the choice only when m or the scan changes.  Values always read k
// and k2 (k + 1, or k itself for the last level) blended by x (0 outside a
// crossfade), so every pitch costs the same (see wt_value_sel).
struct wt_sel {
	double m, scan;
	_Bool valid;
	int k, k2;
	_Bool two;
	double x;
	long fa, fb;
	double fs;
};

static inline __attribute__((always_inline)) void wt_select(const struct wt_table *t, double m, double scan, struct wt_sel *sel)
{
	sel->m = m;
	sel->scan = scan;
	sel->valid = 1;
	wt_frames(t->frames, scan, t->scan_wrap, &sel->fa, &sel->fb, &sel->fs);

	// The first level with m <= hi (the last for anything above), by
	// binary search (hi rises; sync levels are many)
	int n = t->nlevels;
	int k = 0;
	int top = n - 1;
	while (k < top) {
		int mid = (k + top) / 2;
		if (m > t->hi[mid]) {
			k = mid + 1;
		} else {
			top = mid;
		}
	}
	sel->k = k;
	sel->k2 = k < n - 1 ? k + 1 : k;
	sel->two = n > 1 && k < n - 1 && m > t->lo[k];
	sel->x = sel->two ? (m - t->lo[k]) / (t->hi[k] - t->lo[k]) : 0;
}

// Like wt_select, reusing +sel+ if +m+ and +scan+ haven't changed.
static inline __attribute__((always_inline)) void wt_reselect(const struct wt_table *t, double m, double scan, struct wt_sel *sel)
{
	if (!sel->valid || m != sel->m || scan != sel->scan) {
		wt_select(t, m, scan, sel);
	}
}

// The table's value at +u+ with the levels and frames of +sel+.  Tables
// with levels always read two (the second weighted 0 outside crossfades,
// which leaves the first's value exactly), so a steady pitch costs the same
// inside and outside a crossfade (user: "all notes should cost close to the
// same for predictability").
static inline __attribute__((always_inline)) void wt_value_sel(const struct wt_table *t, double u, const struct wt_sel *sel, int mode, int cs, const struct wt_sinc *ks, double *re, double *im)
{
	if (t->nlevels > 1) {
		double re1, im1, re2, im2;
		wt_level_value(t, sel->k, u, sel->fa, sel->fb, sel->fs, mode, cs, ks, &re1, &im1);
		wt_level_value(t, sel->k2, u, sel->fa, sel->fb, sel->fs, mode, cs, ks, &re2, &im2);
		*re = re1 + (re2 - re1) * sel->x;
		*im = im1 + (im2 - im1) * sel->x;
	} else {
		wt_level_value(t, sel->k, u, sel->fa, sel->fb, sel->fs, mode, cs, ks, re, im);
	}
}

// wt_value_sel with the interpolation +mode+ a constant in each branch, so
// the compiler specializes the interpolator (the hot loops' dispatch).
static inline __attribute__((always_inline)) void wt_value_dispatch(const struct wt_table *t, double u, const struct wt_sel *sel, int mode, const struct wt_sinc *ks, double *re, double *im)
{
	if (t->cs == 1) {
		switch (mode) {
			case WT_NONE: wt_value_sel(t, u, sel, WT_NONE, 1, ks, re, im); break;
			case WT_LINEAR: wt_value_sel(t, u, sel, WT_LINEAR, 1, ks, re, im); break;
			case WT_CUBIC: wt_value_sel(t, u, sel, WT_CUBIC, 1, ks, re, im); break;
			case WT_OPTIMAL: wt_value_sel(t, u, sel, WT_OPTIMAL, 1, ks, re, im); break;
			default: wt_value_sel(t, u, sel, WT_SINC, 1, ks, re, im); break;
		}
	} else {
		wt_value_sel(t, u, sel, mode, 2, ks, re, im);
	}
}

// The table's value at +u+ moving +m+ per sample, at +scan+.
static inline __attribute__((always_inline)) void wt_value(const struct wt_table *t, double u, double m, double scan, int mode, const struct wt_sinc *ks, double *re, double *im)
{
	struct wt_sel sel;
	wt_select(t, m, scan, &sel);
	wt_value_sel(t, u, &sel, mode, t->cs, ks, re, im);
}

// The half mean (Wavetable::Builder.half_means) at +scan+.
static inline double wt_half_mean(const struct wt_table *t, double scan)
{
	long fa, fb;
	double fs;
	wt_frames(t->frames, scan, t->scan_wrap, &fa, &fb, &fs);
	if (fb < 0) {
		return t->half_means[fa];
	}
	return t->half_means[fa] + (t->half_means[fb] - t->half_means[fa]) * fs;
}

static inline double wt_clamp_width(double w)
{
	if (!(w >= WT_MIN_WIDTH)) return WT_MIN_WIDTH; // also NaN
	if (w > 1.0 - WT_MIN_WIDTH) return 1.0 - WT_MIN_WIDTH;
	return w;
}

// Makes *buffer a contiguous inplace 1D NArray of the table's output type
// (SFloat or SComplex), like mb_ensure_inplace_sfloat.
static inline void wt_ensure_output(VALUE *buffer, const struct wt_table *t, _Bool *was_inplace)
{
	if (t->cs == 1) {
		mb_ensure_inplace_sfloat(buffer, was_inplace);
		return;
	}

	if (RNARRAY_NDIM(*buffer) != 1) {
		rb_raise(rb_eArgError, "Only 1D NArrays may be processed");
	}
	_Bool prior_inplace = !!TEST_INPLACE(*buffer);
	*buffer = rb_funcall(numo_cSComplex, rb_intern("cast"), 1, *buffer);
	if (!RTEST(nary_check_contiguous(*buffer)) || !prior_inplace) {
		*buffer = nary_dup(*buffer);
		SET_INPLACE(*buffer);
		prior_inplace = 0;
	}
	*was_inplace = prior_inplace;
}

static inline void wt_store(float *out, long cs, size_t i, double re, double im, double g, double off)
{
	if (cs == 1) {
		out[i] = re * g + off;
	} else {
		out[2 * i] = re * g + off;
		out[2 * i + 1] = im * g;
	}
}

static inline double wt_read_state(VALUE state, long length, const char *name)
{
	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) < length) {
		rb_raise(rb_eArgError, "%s must have at least %ld elements", name, length);
	}
	return NUM2DBL(rb_ary_entry(state, 0));
}

// The next uniform random number in 0...1 from the splitmix64 state *s (the
// same generator as noise_random in fast_sound.c; Ruby mirror
// MB::Sound::Tone.noise_random).
static inline double wt_noise_random(uint64_t *s)
{
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	z ^= z >> 31;
	return (double)(z >> 11) * 0x1.0p-53;
}

// The phase increment for one sample at +freq+ Hz, with a random part for
// noise (as phasor_increment in fast_sound.c; separate statements so no
// multiply-add is fused).
static inline double wt_increment(double freq, double adv, double rndadv, uint64_t *rng)
{
	if (rndadv != 0) {
		double r = wt_noise_random(rng) * rndadv;
		double a = adv + r;
		return freq * a;
	}

	return freq * adv;
}

/*
 * Band-limited warp corners.  A phase warp (width w != 0.5) bends the phase
 * at e = w (the table's middle, u = 0.5) and at the wrap (u = 0), so the
 * waveform's slope jumps there by T'(u) times the change in the warp's
 * slope (T' per cycle of the table, k1 = 0.5 / w before the knee, k2 =
 * 0.5 / (1 - w) after).  As in FastSynth.oscillate_bl, each crossing adds
 * a 2-point PolyBLAMP to the samples before and after it, at its sub-sample
 * time.  The table is continuous, so there are no value jumps.  T' comes
 * exactly from the table's harmonics (wt_table_slope).
 */
#define WT_EPS 1e-9

// If moving from phase +e+ by +d+ cycles crosses phase +b+, the crossing
// time as a fraction of the step in (0, 1], else -1 (the same as
// bl_crossing in fast_synth.c).
static inline double wt_crossing(double e, double d, double b)
{
	double dist;
	if (d > 0) {
		dist = b - e;
	} else if (d < 0) {
		dist = e - b;
	} else {
		return -1;
	}
	if (dist < 0) {
		dist += 1.0;
	}
	if (dist == 0) {
		dist = 1.0;
	}

	double ad = fabs(d);
	if (ad >= 1.0 || dist > ad + WT_EPS) {
		return -1;
	}

	return dist >= ad ? 1.0 : dist / ad;
}

#define WT_TWO_PI (2.0 * M_PI)

// Adds the derivatives of orders 1...+orders+ (per cycle) of one frame's
// harmonics 1..+harmonics+ at +u+ times +weight+ to +dre+/+dim+: the sums of
// c_h (2 pi i h)^o e^(2 pi i h u).  The real parts are a real table's derivatives;
// complex tables use both.  The exponentials come from a rotation
// recurrence (the Ruby mirror does the same real arithmetic).
static inline void wt_harmonic_derivs(const double *c, long harmonics, double u, int orders, double weight, double *dre, double *dim)
{
	double cu = cos(WT_TWO_PI * u);
	double su = sin(WT_TWO_PI * u);
	double er = 1.0, ei = 0.0;
	double sre[WT_DERIV_ORDERS] = { 0 }, sim[WT_DERIV_ORDERS] = { 0 };

	for (long h = 1; h <= harmonics; h++) {
		double nr = er * cu - ei * su;
		double ni = er * su + ei * cu;
		er = nr;
		ei = ni;

		double cr = c[2 * h];
		double ci = c[2 * h + 1];
		double zr = cr * er - ci * ei;
		double zi = cr * ei + ci * er;

		double w = WT_TWO_PI * (double)h;
		double pr = 1.0, pi = 0.0;
		for (int o = 1; o < orders; o++) {
			double qr = -pi * w;
			double qi = pr * w;
			pr = qr;
			pi = qi;
			sre[o] += zr * pr - zi * pi;
			sim[o] += zr * pi + zi * pr;
		}
	}

	for (int o = 1; o < orders; o++) {
		dre[o] += sre[o] * weight;
		dim[o] += sim[o] * weight;
	}
}

// Derivatives of orders 1...+orders+ (per cycle) of the table at +u+ with
// the levels and frames of +sel+ (crossfaded and scanned like the values),
// into +dre+/+dim+ (order 0 is left alone).
static inline void wt_spectral_derivs(const struct wt_table *t, double u, const struct wt_sel *sel, int orders, double *dre, double *dim)
{
	for (int o = 1; o < orders; o++) {
		dre[o] = 0;
		dim[o] = 0;
	}
	if (t->spectra == NULL) {
		return;
	}

	int nlev = sel->two ? 2 : 1;
	for (int l = 0; l < nlev; l++) {
		double lw = sel->two ? (l == 0 ? 1.0 - sel->x : sel->x) : 1.0;
		long h = t->harmonics[sel->k + l];
		const double *fa = t->spectra + sel->fa * t->spec_cols * 2;
		if (sel->fb < 0) {
			wt_harmonic_derivs(fa, h, u, orders, lw, dre, dim);
		} else {
			const double *fb = t->spectra + sel->fb * t->spec_cols * 2;
			wt_harmonic_derivs(fa, h, u, orders, lw * (1.0 - sel->fs), dre, dim);
			wt_harmonic_derivs(fb, h, u, orders, lw * sel->fs, dre, dim);
		}
	}
}

// The table's slope per cycle at +u+ (real and imaginary parts), exactly,
// from its harmonics.
static inline void wt_table_slope(const struct wt_table *t, double u, double m, double sc, int mode, const struct wt_sinc *ks, double *re, double *im)
{
	struct wt_sel sel;
	wt_select(t, m, sc, &sel);
	double dre[2], dim[2];
	wt_spectral_derivs(t, u, &sel, 2, dre, dim);
	*re = dre[1];
	*im = dim[1];
}

// The warp corners crossed moving from phase +e+ by +d+ cycles: the
// corrections for the sample at the start of the step go in *bre/*bim, and
// for the sample at its end in *are/*aim.
static inline void wt_corner_step(const struct wt_table *t, double e, double d, double w, double m, double sc, int mode, const struct wt_sinc *ks,
		double *bre, double *bim, double *are, double *aim)
{
	*bre = *bim = *are = *aim = 0;

	for (int j = 0; j < 2; j++) {
		double f = wt_crossing(e, d, j == 0 ? 0.0 : w);
		if (f < 0) {
			continue;
		}

		double k1 = 0.5 / w;
		double k2 = 0.5 / (1.0 - w);
		double jump = (j == 0 ? k1 - k2 : k2 - k1) * fabs(d);
		double sre, sim;
		wt_table_slope(t, j == 0 ? 0.0 : 0.5, m, sc, mode, ks, &sre, &sim);

		double xa = f;
		double xb = 1.0 - f;
		double ca = xa * xa * xa / 6.0;
		double cb = xb * xb * xb / 6.0;
		*are += sre * jump * ca;
		*aim += sim * jump * ca;
		*bre += sre * jump * cb;
		*bim += sim * jump * cb;
	}
}

/*
 * Cycle-mode wavetable oscillator (see Wavetable#oscillate):
 *   oscillate(buffer, spec, frequency, advance, gain, offset, state, tstate,
 *             phase_mod, width, scan, interpolation, remove_dc, sinc
 *             [, random_advance, noise])
 *
 * The phase (state[0], cycles) advances like FastSound.phasor and
 * FastSynth.oscillate_bl: sample i reads phase phi + (increments 0...i)
 * (i * increment for a constant frequency), plus phase_mod (cycles), warped
 * like oscillate_bl when +width+ isn't nil.  Levels are picked from the
 * motion per sample (increment plus the change in phase modulation) times
 * the warp's steeper slope.  With a warp and band-limited levels, the
 * warp's corners get PolyBLAMP corrections (see wt_corner_step).  tstate is
 * [position, last phase modulation, primed, last phase, last increment].
 * A nonzero +random_advance+ adds noise to the increments (as
 * FastSound.phasor; +noise+ is the generator state, Tone::State#noise).
 */

// The state of a cycle-mode oscillator between blocks: the phase, and
// Tone::State#table's previous phase modulation, whether it is primed, the
// previous phase, and the previous increment (warp corners), plus the
// noise generator.
struct mb_wt_osc_state {
	double phi;
	struct mb_grid_phase grid; // a constant frequency's phase grid (see mb_phase.h)
	double prev_pm;
	_Bool primed;
	double prev_e;
	double prev_inc;
	double prev_w, prev_m, prev_sc; // the last sample's width, level measure, and scan (NAN if unknown)
	uint64_t rng;
};

// Reads the last sample's width, level measure, and scan from entries 5..7
// of cycle-mode wavetable state +tstate+ (NAN if absent; see
// mb_wt_oscillate's corners).
static inline void mb_wt_read_corner_state(VALUE tstate, struct mb_wt_osc_state *s)
{
	s->prev_w = s->prev_m = s->prev_sc = NAN;
	if (RARRAY_LEN(tstate) >= 8) {
		VALUE w = rb_ary_entry(tstate, 5), m = rb_ary_entry(tstate, 6), sc = rb_ary_entry(tstate, 7);
		if (RB_FLOAT_TYPE_P(w) && RB_FLOAT_TYPE_P(m) && RB_FLOAT_TYPE_P(sc)) {
			s->prev_w = RFLOAT_VALUE(w);
			s->prev_m = RFLOAT_VALUE(m);
			s->prev_sc = RFLOAT_VALUE(sc);
		}
	}
}

// Stores them back (see mb_wt_read_corner_state).
static inline void mb_wt_write_corner_state(VALUE tstate, const struct mb_wt_osc_state *s)
{
	rb_ary_store(tstate, 5, rb_float_new(s->prev_w));
	rb_ary_store(tstate, 6, rb_float_new(s->prev_m));
	rb_ary_store(tstate, 7, rb_float_new(s->prev_sc));
}

// FastWavetable.oscillate's loop: +length+ samples of cycle-mode table +t+
// (interpolation +mode+, sinc kernel +ks+) into +out+ (floats, two per
// sample for complex tables) at frequency +f+ (Hz) with phase modulation
// +p+ (cycles), width +wsig+ (used if +warped+), and scan +scan+, advance
// +adv+ (cycles per Hz per sample) and noise +rndadv+, output gain +g+
// and offset +off+, removing the warp's DC with +remove_dc+; updates *s.
static inline void mb_wt_oscillate(const struct wt_table *t, int mode, const struct wt_sinc *ks, float *out, size_t length,
		const struct mb_signal *f, const struct mb_signal *p, const struct mb_signal *wsig, _Bool warped, const struct mb_signal *scan,
		double adv, double rndadv, double g, double off, _Bool remove_dc, struct mb_wt_osc_state *s)
{
	double phi = s->phi;
	uint64_t rng = s->rng;

	double freq = f->scalar;
	const float *freqptr = f->ptr;
	size_t freqptr_step = f->step;

	double pm = p->scalar;
	const float *pmptr = p->ptr;
	size_t pmptr_step = p->step;

	double w = wt_clamp_width(wsig->scalar);
	const float *wptr = wsig->ptr;
	size_t wptr_step = wsig->step;

	double sc = scan->scalar;
	const float *scptr = scan->ptr;
	size_t scptr_step = scan->step;

	_Bool dc = remove_dc && warped;
	_Bool primed = s->primed;
	double prev_pm = primed ? s->prev_pm : pm;
	double prev_e = s->prev_e;
	double prev_inc = s->prev_inc;
	_Bool corners = warped && isfinite(t->hi[0]); // band-limited levels
	double pending_re = 0, pending_im = 0, pending_d = 0;
	double m = s->prev_m;

	_Bool constant = !freqptr && rndadv == 0;
	_Bool running = !constant && rndadv == 0; // a frequency signal (see mb_phase.h)
	if (running) {
		phi = mb_wrap_phase(phi);
	}
	struct mb_grid_phase grid = s->grid;
	if (constant) {
		mb_grid_phase_start(&grid, phi, wt_increment(freq, adv, 0, &rng));
	}
	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = freqptr[i * freqptr_step];
		if (pmptr) pm = pmptr[i * pmptr_step];
		if (wptr) w = wt_clamp_width(wptr[i * wptr_step]);
		if (scptr) sc = scptr[i * scptr_step];

		double inc = wt_increment(freq, adv, rndadv, &rng);

		double e = running ? phi : wt_wrap(constant ? grid.base + grid.inc * grid.k : phi, 1.0);
		if (pm != 0) {
			e = wt_wrap(e + pm, 1.0);
		}

		double u, wf;
		if (w != 0.5) {
			double k1 = 0.5 / w;
			double k2 = 0.5 / (1.0 - w);
			u = e < w ? e * k1 : 0.5 + (e - w) * k2;
			wf = k1 > k2 ? k1 : k2;
		} else {
			u = e;
			wf = 1.0;
		}

		// Noise picks levels by the mean increment (the pitch; a random
		// phase gives white noise with the table's distribution of values
		// at any level)
		double d = (rndadv != 0 ? freq * (adv + 0.5 * rndadv) : inc) + (pm - prev_pm);
		m = fabs(d) * wf;
		double re, im;
		wt_reselect(t, m, sc, &sel);
		wt_value_dispatch(t, u, &sel, mode, ks, &re, &im);

		if (corners) {
			// Corners between the previous sample and this one: usually
			// found while correcting the previous sample, unless its next
			// phase modulation was extrapolated (between buffers, only if
			// the phase continued without a jump)
			double d_back = prev_inc + (pm - prev_pm);
			if (i > 0 && d_back == pending_d) {
				re += pending_re;
				im += pending_im;
			} else if (primed && (i > 0 || fabs(wt_wrap(prev_e + d_back - e + 0.5, 1.0) - 0.5) < 1e-6)) {
				// The corners of the previous sample's warp, level, and
				// scan, as the pending correction would have used (fixes-7)
				double bre, bim, are, aim;
				if (i == 0 && s->prev_w == s->prev_w) {
					wt_corner_step(t, prev_e, d_back, s->prev_w, s->prev_m, s->prev_sc, mode, ks, &bre, &bim, &are, &aim);
				} else {
					wt_corner_step(t, prev_e, d_back, w, m, sc, mode, ks, &bre, &bim, &are, &aim);
				}
				re += are;
				im += aim;
			}

			// Corners between this sample and the next (phase modulation
			// for the last sample is extrapolated)
			double next_pm;
			if (i + 1 < length) {
				next_pm = pmptr ? pmptr[(i + 1) * pmptr_step] : pm;
			} else {
				next_pm = pm + (pm - (i > 0 || primed ? prev_pm : pm));
			}
			double d_fwd = inc + (next_pm - pm);
			double bre, bim;
			wt_corner_step(t, e, d_fwd, w, m, sc, mode, ks, &bre, &bim, &pending_re, &pending_im);
			re += bre;
			im += bim;
			pending_d = d_fwd;
		}

		if (dc) {
			re -= wt_half_mean(t, sc) * (2.0 * w - 1.0);
		}

		wt_store(out, t->cs, i, re, im, g, off);
		prev_pm = pm;
		prev_e = e;
		prev_inc = inc;
		primed = 1;

		if (rndadv != 0) {
			phi = wt_wrap(phi + inc, 1.0); // noise: block-size independent (as fast_sound.c)
		} else if (running) {
			phi = mb_wrap_phase(phi + inc);
		} else {
			mb_grid_phase_next(&grid);
		}
	}

	if (constant) {
		s->phi = mb_grid_phase_now(&grid);
		s->grid = grid;
	} else {
		s->phi = wt_wrap(phi, 1.0);
	}
	s->rng = rng;
	if (length > 0) {
		s->prev_pm = prev_pm;
		s->primed = 1;
		s->prev_e = prev_e;
		s->prev_inc = prev_inc;
		s->prev_w = w;
		s->prev_m = m;
		s->prev_sc = sc;
	}
}

#endif
