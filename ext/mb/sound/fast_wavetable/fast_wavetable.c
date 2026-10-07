/*
 * MB::Sound::FastWavetable: band-limited wavetable kernels (see
 * MB::Sound::Wavetable for the design).
 * (C)2025-2026 Mike Bourgeous
 *
 * A table is a set of levels (mipmaps), brightest first, each a 2D SFloat
 * or SComplex NArray of [frames, count + 2 * guard] samples: one cycle per
 * frame in cycle mode (wrapped around in the guard samples), or the attack
 * of a sampled sound (sample mode; a looped sound has separate loop levels
 * holding one period of the loop each).  The Ruby side describes a table
 * with Wavetable#kernel_spec.
 *
 * Each sample:
 * - picks levels from the increment per sample m (cycles, or source samples
 *   in sample mode): the first level k with m <= hi[k], crossfaded linearly
 *   into level k + 1 while m is above lo[k];
 * - in each level, blends the two frames around the scan position (0..1)
 *   tap by tap and interpolates between samples (none, linear, cubic,
 *   Niemitalo's optimal 4-point 4th-order for 4x oversampling, or the
 *   Kaiser-windowed sinc of Wavetable::SINC_KERNEL).
 *
 * Complex levels interpolate their real and imaginary parts separately with
 * the same real arithmetic.  The Ruby mirrors (MB::Sound::Wavetable::
 * KernelRuby) do the same operations in the same order, and the extension
 * is built with -ffp-contract=off, so both give identical samples.
 */
#include <math.h>
#include <complex.h>

#include <ruby.h>

#include "numo/narray.h"
#include "mb_ext_helpers.h"

#define WT_MAX_LEVELS 64
#define WT_DERIV_ORDERS 2 // value and slope (phase warp corners)
#define WT_GUARD 16 // Wavetable::GUARD
#define WT_MAX_TAPS 64 // sync residual taps (BandLimit::SYNC_TAPS)
#define WT_INV_2PI (1.0 / (2.0 * M_PI))
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

static const double *wt_dfloat(VALUE v, long length, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || RNARRAY_SHAPE(v)[0] < (size_t)length) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D DFloat of at least %ld values", name, length);
	}
	return (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

// Reads an Array of level NArrays into +levels+, returning the count.
static int wt_read_levels(VALUE datas, VALUE counts, struct wt_level *levels, long rows, long guard, VALUE *klass)
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
static void wt_read_table(VALUE spec, struct wt_table *t)
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

static void wt_read_sinc(VALUE kernel, struct wt_sinc *k)
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
static int wt_read_interp(VALUE interp, VALUE sinc, const struct wt_table *t, struct wt_sinc *k)
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
static void wt_ensure_output(VALUE *buffer, const struct wt_table *t, _Bool *was_inplace)
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

static double wt_read_state(VALUE state, long length, const char *name)
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
static void wt_harmonic_derivs(const double *c, long harmonics, double u, int orders, double weight, double *dre, double *dim)
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
static void wt_spectral_derivs(const struct wt_table *t, double u, const struct wt_sel *sel, int orders, double *dre, double *dim)
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
 * (i * increment for a constant frequency), plus phase_mod / 2pi, warped
 * like oscillate_bl when +width+ isn't nil.  Levels are picked from the
 * motion per sample (increment plus the change in phase modulation) times
 * the warp's steeper slope.  With a warp and band-limited levels, the
 * warp's corners get PolyBLAMP corrections (see wt_corner_step).  tstate is
 * [position, last phase modulation, primed, last phase, last increment].
 * A nonzero +random_advance+ adds noise to the increments (as
 * FastSound.phasor; +noise+ is the generator state, Tone::State#noise).
 */
static VALUE ruby_oscillate(int argc, VALUE *argv, VALUE self)
{
	if (argc != 14 && argc != 16) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 14 or 16)", argc);
	}
	VALUE buffer = argv[0], spec = argv[1], frequency = argv[2], advance = argv[3], gain = argv[4], offset = argv[5];
	VALUE state = argv[6], tstate = argv[7], phase_mod = argv[8], width = argv[9], scan = argv[10];
	VALUE interp = argv[11], remove_dc = argv[12], sinc = argv[13];
	VALUE random_advance = argc > 14 ? argv[14] : Qnil;
	VALUE noise = argc > 15 ? argv[15] : Qnil;

	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0) {
		rb_raise(rb_eArgError, "FastWavetable.oscillate needs a cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(interp, sinc, &t, &ks);

	double phi = wt_read_state(state, 1, "Phase state");
	wt_read_state(tstate, 5, "Wavetable state");
	double adv = NUM2DBL(advance);
	double rndadv = NIL_P(random_advance) ? 0 : NUM2DBL(random_advance);
	uint64_t rng = 0;
	if (rndadv != 0) {
		Check_Type(noise, T_ARRAY);
		if (RARRAY_LEN(noise) != 1) {
			rb_raise(rb_eArgError, "Noise state must have exactly one Integer element");
		}
		rng = NUM2ULL(rb_ary_entry(noise, 0));
	}
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	const float *freqptr = NULL;
	size_t freqptr_step = 1;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqptr_step);

	double pm;
	const float *pmptr = NULL;
	size_t pmptr_step = 1;
	mb_read_signal_input(&phase_mod, length, "Phase modulation", &pm, &pmptr, &pmptr_step);

	_Bool warped = !NIL_P(width);
	double w;
	const float *wptr = NULL;
	size_t wptr_step = 1;
	if (!warped) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr, &wptr_step);
	w = wt_clamp_width(w);

	double sc;
	const float *scptr = NULL;
	size_t scptr_step = 1;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr, &scptr_step);

	_Bool dc = RTEST(remove_dc) && warped;
	_Bool primed = NUM2INT(rb_ary_entry(tstate, 2)) != 0;
	double prev_pm = primed ? NUM2DBL(rb_ary_entry(tstate, 1)) : pm;
	double prev_e = NUM2DBL(rb_ary_entry(tstate, 3));
	double prev_inc = NUM2DBL(rb_ary_entry(tstate, 4));
	_Bool corners = warped && isfinite(t.hi[0]); // band-limited levels
	double pending_re = 0, pending_im = 0, pending_d = 0;

	_Bool constant = !freqptr && rndadv == 0;
	double steps = 0;
	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = freqptr[i * freqptr_step];
		if (pmptr) pm = pmptr[i * pmptr_step];
		if (wptr) w = wt_clamp_width(wptr[i * wptr_step]);
		if (scptr) sc = scptr[i * scptr_step];

		double inc = wt_increment(freq, adv, rndadv, &rng);
		if (constant) {
			steps = inc * i;
		}

		double e = wt_wrap(phi + steps, 1.0);
		if (pm != 0) {
			e = wt_wrap(e + pm * WT_INV_2PI, 1.0);
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
		double d = (rndadv != 0 ? freq * (adv + 0.5 * rndadv) : inc) + (pm - prev_pm) * WT_INV_2PI;
		double m = fabs(d) * wf;
		double re, im;
		wt_reselect(&t, m, sc, &sel);
		wt_value_dispatch(&t, u, &sel, mode, &ks, &re, &im);

		if (corners) {
			// Corners between the previous sample and this one: usually
			// found while correcting the previous sample, unless its next
			// phase modulation was extrapolated (between buffers, only if
			// the phase continued without a jump)
			double d_back = prev_inc + (pm - prev_pm) * WT_INV_2PI;
			if (i > 0 && d_back == pending_d) {
				re += pending_re;
				im += pending_im;
			} else if (primed && (i > 0 || fabs(wt_wrap(prev_e + d_back - e + 0.5, 1.0) - 0.5) < 1e-6)) {
				double bre, bim, are, aim;
				wt_corner_step(&t, prev_e, d_back, w, m, sc, mode, &ks, &bre, &bim, &are, &aim);
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
			double d_fwd = inc + (next_pm - pm) * WT_INV_2PI;
			double bre, bim;
			wt_corner_step(&t, e, d_fwd, w, m, sc, mode, &ks, &bre, &bim, &pending_re, &pending_im);
			re += bre;
			im += bim;
			pending_d = d_fwd;
		}

		if (dc) {
			re -= wt_half_mean(&t, sc) * (2.0 * w - 1.0);
		}

		wt_store(out, t.cs, i, re, im, g, off);
		prev_pm = pm;
		prev_e = e;
		prev_inc = inc;
		primed = 1;

		if (!constant) {
			steps += inc;
		}
	}

	if (constant) {
		steps = freq * adv * length;
	}
	if (rndadv != 0) {
		rb_ary_store(noise, 0, ULL2NUM(rng));
	}
	rb_ary_store(state, 0, rb_float_new(wt_wrap(phi + steps, 1.0)));
	if (length > 0) {
		rb_ary_store(tstate, 1, rb_float_new(prev_pm));
		rb_ary_store(tstate, 2, INT2NUM(1));
		rb_ary_store(tstate, 3, rb_float_new(prev_e));
		rb_ary_store(tstate, 4, rb_float_new(prev_inc));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(noise);
	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(frequency);
	RB_GC_GUARD(phase_mod);
	RB_GC_GUARD(width);
	RB_GC_GUARD(scan);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Phase-driven wavetable lookup (see Wavetable#lookup):
 *   lookup(buffer, spec, phase, increments, scan, interpolation, wrap, sinc,
 *          lstate)
 *
 * Reads the table at +phase+ (cycles), handling phases outside 0...1 by
 * +wrap+: 0 wrap, 1 bounce, 2 clamp, 3 zero, or 4 shape (the phase is a
 * signal from -1 to 1 spread across the whole cycle, clamped at the ends).
 *
 * Levels follow |increments| (cycles per sample; false for 0, the
 * brightest level).  With nil increments the speed comes from the phase
 * itself: the change from the previous sample (wrapped to -0.5..0.5 for
 * :wrap, halved for :shape), whose peak is held for WT_HOLD samples and
 * then released by WT_RELEASE per sample.  +lstate+ is [last phase,
 * primed, held peak, hold samples left].
 */
static VALUE ruby_lookup(VALUE self, VALUE buffer, VALUE spec, VALUE phase, VALUE increments, VALUE scan, VALUE interp, VALUE wrap, VALUE sinc, VALUE lstate)
{
	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0) {
		rb_raise(rb_eArgError, "FastWavetable.lookup needs a cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(interp, sinc, &t, &ks);
	int wrapmode = NUM2INT(wrap);
	if (wrapmode < WT_WRAP || wrapmode > WT_SHAPE) {
		rb_raise(rb_eArgError, "Invalid wrapping mode code %d", wrapmode);
	}

	_Bool automatic = NIL_P(increments);
	double prev = 0, peak = 0;
	long hold = 0;
	_Bool primed = 0;
	if (automatic) {
		Check_Type(lstate, T_ARRAY);
		if (RARRAY_LEN(lstate) != 4) {
			rb_raise(rb_eArgError, "Lookup state must have four elements");
		}
		prev = NUM2DBL(rb_ary_entry(lstate, 0));
		primed = NUM2INT(rb_ary_entry(lstate, 1)) != 0;
		peak = NUM2DBL(rb_ary_entry(lstate, 2));
		hold = NUM2LONG(rb_ary_entry(lstate, 3));
	}

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double ph;
	const float *phptr = NULL;
	size_t phptr_step = 1;
	mb_read_signal_input(&phase, length, "Phase", &ph, &phptr, &phptr_step);

	double inc = 0;
	const float *incptr = NULL;
	size_t incptr_step = 1;
	if (!automatic && increments != Qfalse) {
		mb_read_signal_input(&increments, length, "Increments", &inc, &incptr, &incptr_step);
	}

	double sc;
	const float *scptr = NULL;
	size_t scptr_step = 1;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr, &scptr_step);

	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (phptr) ph = phptr[i * phptr_step];
		if (incptr) inc = incptr[i * incptr_step];
		if (scptr) sc = scptr[i * scptr_step];

		double m;
		if (automatic) {
			double d = 0;
			if (primed) {
				d = ph - prev;
				if (wrapmode == WT_WRAP) {
					d = d - wt_floor(d + 0.5);
				} else if (wrapmode == WT_SHAPE) {
					d = d * 0.5;
				}
				d = fabs(d);
			}
			if (d >= peak) {
				peak = d;
				hold = WT_HOLD;
			} else if (hold > 0) {
				hold--;
			} else {
				double r = peak * WT_RELEASE;
				peak = r > d ? r : d;
			}
			prev = ph;
			primed = 1;
			m = peak;
		} else {
			m = fabs(inc);
		}

		double u;
		switch (wrapmode) {
			case WT_WRAP:
				u = wt_wrap(ph, 1.0);
				break;
			case WT_BOUNCE: {
				double b = wt_wrap(ph, 2.0);
				u = b > 1 ? 2.0 - b : b;
				break;
			}
			case WT_CLAMP:
				u = ph < 0 ? 0.0 : (ph > 1 ? 1.0 : ph);
				break;
			case WT_SHAPE:
				u = (ph + 1.0) * 0.5;
				u = u < 0 ? 0.0 : (u > 1 ? 1.0 : u);
				break;
			default:
				if (ph < 0 || ph >= 1) {
					wt_store(out, t.cs, i, 0, 0, 1, 0);
					continue;
				}
				u = ph;
				break;
		}

		double re, im;
		wt_reselect(&t, m, sc, &sel);
		wt_value_dispatch(&t, u, &sel, mode, &ks, &re, &im);
		wt_store(out, t.cs, i, re, im, 1, 0);
	}

	if (automatic && length > 0) {
		rb_ary_store(lstate, 0, rb_float_new(prev));
		rb_ary_store(lstate, 1, INT2NUM(1));
		rb_ary_store(lstate, 2, rb_float_new(peak));
		rb_ary_store(lstate, 3, LONG2NUM(hold));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(phase);
	RB_GC_GUARD(increments);
	RB_GC_GUARD(scan);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Sample-mode player (see Wavetable#play):
 *   play(buffer, spec, frequency, advance, speed, gain, offset, state,
 *        tstate, interpolation, sinc)
 *
 * The position in source samples (tstate[0]) advances by frequency * speed
 * per sample (positions within a buffer are the start plus a running sum,
 * like the phase), wrapping back into the loop (if any) when it reaches
 * the loop's end; the phase in state[0] advances by frequency * advance as
 * for any tone.  Positions outside the sound read silence.
 */
static VALUE ruby_play(VALUE self, VALUE buffer, VALUE spec, VALUE frequency, VALUE advance, VALUE speed,
		VALUE gain, VALUE offset, VALUE state, VALUE tstate, VALUE interp, VALUE sinc)
{
	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 1) {
		rb_raise(rb_eArgError, "FastWavetable.play needs a sample-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(interp, sinc, &t, &ks);

	double phi = wt_read_state(state, 1, "Phase state");
	double pos = wt_read_state(tstate, 3, "Wavetable state");
	double adv = NUM2DBL(advance);
	double spd = NUM2DBL(speed);
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	const float *freqptr = NULL;
	size_t freqptr_step = 1;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqptr_step);

	double ls = t.loop_start;
	double len = t.loop_end - t.loop_start;

	_Bool constant = !freqptr;
	double steps = 0, psteps = 0;
	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = freqptr[i * freqptr_step];

		double inc = freq * adv;
		double sp = freq * spd;
		if (constant) {
			steps = inc * i;
			psteps = sp * i;
		}

		double p = pos + psteps;
		if (t.has_loop && p >= t.loop_end) {
			p = ls + wt_wrap(p - ls, len);
		}

		double re, im;
		wt_reselect(&t, fabs(sp), 0, &sel);
		wt_value_dispatch(&t, p, &sel, mode, &ks, &re, &im);
		wt_store(out, t.cs, i, re, im, g, off);

		if (!constant) {
			steps += inc;
			psteps += sp;
		}
	}

	if (constant) {
		steps = freq * adv * length;
		psteps = freq * spd * length;
	}
	rb_ary_store(state, 0, rb_float_new(wt_wrap(phi + steps, 1.0)));
	double p = pos + psteps;
	if (t.has_loop && p >= t.loop_end) {
		p = ls + wt_wrap(p - ls, len);
	}
	rb_ary_store(tstate, 0, rb_float_new(p));
	if (length > 0) {
		rb_ary_store(tstate, 2, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(frequency);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Hard and soft sync for cycle-mode tables, band-limited like
 * FastSynth.oscillate_sync: a sync pulse v at a sample resets the phase
 * (hard) or reverses its direction (soft) 1 - |v| samples earlier, and
 * minimum-phase band-limited residuals for the switch add into a ring of
 * the following samples.  The table itself is band-limited, so its wrap
 * needs no correction.
 *
 * FastSynth's shapes are piecewise linear, so a step (minBLEP) and a ramp
 * (minBLAMP) correct their edges exactly.  A table is a sum of harmonics,
 * and a sync event switches each harmonic from one sinusoid (amplitude A0
 * at the event, frequency f0 cycles per sample) to another (A1, f1).  So
 * each harmonic gets its own exact residual: the minimum-phase band-limited
 * switch-on of a complex exponential minus the naive one,
 *   Q(f, t) = e^(2 pi i f t) (G(f, t) - 1),
 *   G(f, t) = (integral over 0..t of h(s) e^(-2 pi i f s) ds) / H(f),
 * with h the minBLEP's impulse (BandLimit.minblep_tables) and H(f) its
 * whole transform, so the residual settles to zero (G(0, t) is the
 * minBLEP's step).  G is tabulated (Wavetable.sync_residuals) for |f| up to
 * 0.5 in rows and t up to +taps+ samples at +os+ points per sample, read
 * bilinearly (G(-f) = conj(G(f))).  The correction adds A1 Q(f1, t) -
 * A0 Q(f0, t) (real parts for real tables).  Truncated Taylor
 * corrections (value, slope, curvature, ...) can't do this near Nyquist,
 * where a harmonic changes too much per sample (they made the synced saw
 * table overshoot to several times full scale at high pitches).
 *
 * Synced tones read the table's sync levels (Wavetable#kernel_spec with
 * sync: true): every harmonic stays below Wavetable#sync_ceiling, inside
 * the minBLEP's passband, where H(f) can be divided out, and finely spaced
 * levels crossfade continuously so brightness doesn't step.
 *
 * The played (interpolated) value jump differs from the harmonic sums by
 * the interpolation error; that difference gets a plain minBLEP, so the
 * corrections cancel the played jump exactly.  Complex tables correct their
 * real and imaginary parts alike (the ring holds taps real corrections,
 * then taps imaginary).
 */

// Linear interpolation into a residual table +t+ samples after an event
// (the same as sync_table in fast_synth.c).
static inline double wt_sync_table(const double *table, size_t os, size_t taps, double t)
{
	double x = t * os;
	if (x < 0 || x >= (double)(taps * os)) {
		return 0;
	}

	size_t idx = (size_t)x;
	double frac = x - idx;
	return table[idx] + (table[idx + 1] - table[idx]) * frac;
}

// The residual table of Wavetable.sync_residuals: +rows+ rows of G for
// frequencies 0..0.5 cycles per sample, each +os+ + 2 fractional offsets
// (t = p / os + j) of +taps+ complex values (the taps of one offset are
// contiguous).
struct wt_residuals {
	const double *g;
	long rows;
};

// Adds the residual of a complex exponential of amplitude (are, aim) and
// frequency +f+ (cycles per sample) switched on +d+ samples before the
// ring's current sample (at +pos+) to the ring +acc+.  +rre+/+rim+ hold
// e^(2 pi i f (d + j)) for each tap j.
static void wt_add_q(double *acc, size_t pos, const struct wt_residuals *rs, size_t os, size_t taps, int cs,
		double f, double d, const double *rre, const double *rim, double are, double aim)
{
	// The nearest row: G(f', t) e^(2 pi i f t) for f' near f is still
	// band-limited (shifted by under half a row) and settles exactly with
	// the naive part, so rows only need to be close
	double af = fabs(f);
	if (af > 0.5) {
		af = 0.5;
	}
	long r = (long)(af * 2.0 * (double)(rs->rows - 1) + 0.5);

	double y = d * (double)os;
	long i0 = (long)y;
	double ft = y - (double)i0;
	double sgn = f < 0 ? -1.0 : 1.0;

	const double *a = rs->g + 2 * ((r * (long)(os + 2) + i0) * (long)taps);
	const double *b = a + 2 * taps;
	size_t k = pos;

	for (size_t j = 0; j < taps; j++) {
		double gre = a[2 * j] + (b[2 * j] - a[2 * j]) * ft - 1.0;
		double gim = (a[2 * j + 1] + (b[2 * j + 1] - a[2 * j + 1]) * ft) * sgn;
		double qre = gre * rre[j] - gim * rim[j];
		double qim = gre * rim[j] + gim * rre[j];

		acc[k] += are * qre - aim * qim;
		if (cs == 2) {
			acc[taps + k] += are * qim + aim * qre;
		}

		k++;
		if (k == taps) {
			k = 0;
		}
	}
}

// Advances the rotations +rre+/+rim+ (one per tap) by +bre+/+bim+.
static inline void wt_rotate(double *rre, double *rim, const double *bre, const double *bim, size_t taps)
{
	for (size_t j = 0; j < taps; j++) {
		double nr = rre[j] * bre[j] - rim[j] * bim[j];
		double ni = rre[j] * bim[j] + rim[j] * bre[j];
		rre[j] = nr;
		rim[j] = ni;
	}
}

// Fills +bre+/+bim+ with e^(2 pi i f (d + j)) for taps j (a recurrence
// from the first) and sets +rre+/+rim+ to 1.
static inline void wt_rotations(double f, double d, size_t taps, double *bre, double *bim, double *rre, double *rim)
{
	double cr = cos(WT_TWO_PI * f * d), ci = sin(WT_TWO_PI * f * d);
	double tr = cos(WT_TWO_PI * f), ti = sin(WT_TWO_PI * f);
	for (size_t j = 0; j < taps; j++) {
		bre[j] = cr;
		bim[j] = ci;
		rre[j] = 1.0;
		rim[j] = 0.0;
		double nr = cr * tr - ci * ti;
		double ni = cr * ti + ci * tr;
		cr = nr;
		ci = ni;
	}
}

// Adds a minBLEP residual for a jump of (dre, dim) +d+ samples before the
// current sample.
static void wt_add_step(double *acc, size_t pos, const double *blep, size_t os, size_t taps, int cs, double d, double dre, double dim)
{
	if (dre == 0 && dim == 0) {
		return;
	}
	for (size_t j = 0; j < taps; j++) {
		double r = wt_sync_table(blep, os, taps, d + j);
		size_t k = (pos + j) % taps;
		acc[k] += dre * r;
		if (cs == 2) {
			acc[taps + k] += dim * r;
		}
	}
}

// The gain of harmonic +h+ in a level with +harmonics+ harmonics (1, or 0
// above them).
static inline double wt_harmonic_gain(long h, long harmonics)
{
	return h > harmonics ? 0.0 : 1.0;
}

// Adds the residuals of a sync event +d+ samples before the current sample
// to the ring: every harmonic of the levels and frames of +sel+ switches
// from phase +u0+ (cycles, warped) moving +f0+ cycles per sample (the
// fundamental's frequency) to phase +u1+ moving +f1+.  +v0re+/+v0im+ and
// +v1re+/+v1im+ are the played values before and after.
static void wt_sync_spectral(const struct wt_table *t, const struct wt_sel *sel, double u0, double f0, double u1, double f1,
		double v0re, double v0im, double v1re, double v1im, double d, const struct wt_residuals *rs, const double *blep,
		size_t os, size_t taps, double *acc, size_t pos, int cs, double limit)
{
	double s0re = 0, s0im = 0, s1re = 0, s1im = 0;

	if (t->spectra != NULL) {
		long ha = t->harmonics[sel->k];
		long hb = sel->two ? t->harmonics[sel->k + 1] : 0;
		long hmax = ha > hb ? ha : hb;
		double x = sel->two ? sel->x : 0.0;
		const double *ca = t->spectra + sel->fa * t->spec_cols * 2;
		const double *cb = sel->fb < 0 ? NULL : t->spectra + sel->fb * t->spec_cols * 2;
		_Bool same = f0 == f1;

		double c0 = cos(WT_TWO_PI * u0), sn0 = sin(WT_TWO_PI * u0);
		double c1 = cos(WT_TWO_PI * u1), sn1 = sin(WT_TWO_PI * u1);
		double e0r = 1.0, e0i = 0.0, e1r = 1.0, e1i = 0.0;

		// e^(2 pi i h f (d + j)) for each tap j, by recurrence over
		// harmonics (independent per tap)
		double b1r[WT_MAX_TAPS], b1i[WT_MAX_TAPS], r1r[WT_MAX_TAPS], r1i[WT_MAX_TAPS];
		double b0r[WT_MAX_TAPS], b0i[WT_MAX_TAPS], r0r[WT_MAX_TAPS], r0i[WT_MAX_TAPS];
		wt_rotations(f1, d, taps, b1r, b1i, r1r, r1i);
		if (!same) {
			wt_rotations(f0, d, taps, b0r, b0i, r0r, r0i);
		}

		for (long h = 1; h <= hmax; h++) {
			// Harmonics moving faster than +limit+ (a fast phase warp
			// segment) get only the plain minBLEP of their value jump
			double hf = (double)h;
			if (fabs(hf * f1) > limit || fabs(hf * f0) > limit) {
				break;
			}

			double nr = e0r * c0 - e0i * sn0;
			double ni = e0r * sn0 + e0i * c0;
			e0r = nr;
			e0i = ni;
			nr = e1r * c1 - e1i * sn1;
			ni = e1r * sn1 + e1i * c1;
			e1r = nr;
			e1i = ni;

			wt_rotate(r1r, r1i, b1r, b1i, taps);
			if (!same) {
				wt_rotate(r0r, r0i, b0r, b0i, taps);
			}

			double wgt = sel->two ?
				(1.0 - x) * wt_harmonic_gain(h, ha) + x * wt_harmonic_gain(h, hb) :
				wt_harmonic_gain(h, ha);
			if (wgt == 0) {
				continue;
			}

			double cr = ca[2 * h];
			double ci = ca[2 * h + 1];
			if (cb) {
				cr = cr * (1.0 - sel->fs) + cb[2 * h] * sel->fs;
				ci = ci * (1.0 - sel->fs) + cb[2 * h + 1] * sel->fs;
			}
			cr = cr * wgt;
			ci = ci * wgt;

			double a0r = cr * e0r - ci * e0i;
			double a0i = cr * e0i + ci * e0r;
			double a1r = cr * e1r - ci * e1i;
			double a1i = cr * e1i + ci * e1r;
			s0re += a0r;
			s0im += a0i;
			s1re += a1r;
			s1im += a1i;

			if (same) {
				wt_add_q(acc, pos, rs, os, taps, cs, hf * f1, d, r1r, r1i, a1r - a0r, a1i - a0i);
			} else {
				wt_add_q(acc, pos, rs, os, taps, cs, hf * f1, d, r1r, r1i, a1r, a1i);
				wt_add_q(acc, pos, rs, os, taps, cs, hf * f0, d, r0r, r0i, -a0r, -a0i);
			}
		}
	}

	// The rest of the played jump (interpolation error; all of it without
	// spectra)
	wt_add_step(acc, pos, blep, os, taps, cs, d, (v1re - v0re) - (s1re - s0re), (v1im - v0im) - (s1im - s0im));
}

// The warped phase of +p+ for width +w+, and the warp's slope there.
static inline double wt_warp_slope(double p, double w, double *k)
{
	if (w == 0.5) {
		*k = 1.0;
		return p;
	}
	*k = p < w ? 0.5 / w : 0.5 / (1.0 - w);
	return p < w ? p * (0.5 / w) : 0.5 + (p - w) * (0.5 / (1.0 - w));
}

/*
 * A synced wavetable oscillator (see Wavetable#sync):
 *   sync(buffer, spec, frequency, advance, gain, offset, sync_state, ring,
 *        pulses, soft, width, scan, interpolation, remove_dc, residuals,
 *        blep, oversample, taps, band_limit, limit, sinc)
 *
 * +sync_state+ is as for FastSynth.oscillate_sync ([phase, last increment,
 * direction, ring position, primed]); +ring+ is a DFloat of +taps+ pending
 * corrections (twice that for complex tables).  +residuals+ is the 2D
 * DComplex of Wavetable.sync_residuals ([rows, taps * oversample + 1]) and
 * +blep+ the minBLEP residual (BandLimit.minblep_tables); harmonics faster
 * than +limit+ cycles per sample (Wavetable::SYNC_RESIDUAL_LIMIT) get only
 * a minBLEP for their value jump.  +spec+ is
 * normally the table's sync spec (Wavetable#kernel_spec with sync: true).
 */
static VALUE ruby_sync(int argc, VALUE *argv, VALUE self)
{
	if (argc != 21) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 21)", argc);
	}

	VALUE buffer = argv[0], spec = argv[1], frequency = argv[2], sync_state = argv[6], ring = argv[7];
	VALUE pulses = argv[8], width = argv[10], scan = argv[11], residuals = argv[14], blep_v = argv[15], sinc = argv[20];

	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0) {
		rb_raise(rb_eArgError, "FastWavetable.sync needs a cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(argv[12], sinc, &t, &ks);
	int cs = t.cs;

	double adv = NUM2DBL(argv[3]);
	double g = NUM2DBL(argv[4]);
	double off = NUM2DBL(argv[5]);
	_Bool soft = RTEST(argv[9]);
	_Bool warped = !NIL_P(width);
	_Bool dc = RTEST(argv[13]) && warped;
	size_t os = NUM2SIZET(argv[16]);
	size_t taps = NUM2SIZET(argv[17]);
	_Bool bl = RTEST(argv[18]);
	double limit = NUM2DBL(argv[19]);

	Check_Type(sync_state, T_ARRAY);
	if (RARRAY_LEN(sync_state) != 5) {
		rb_raise(rb_eArgError, "Sync state must have five elements");
	}
	double p = NUM2DBL(rb_ary_entry(sync_state, 0));
	double prev_inc = NUM2DBL(rb_ary_entry(sync_state, 1));
	double dir = NUM2DBL(rb_ary_entry(sync_state, 2));
	size_t pos = NUM2SIZET(rb_ary_entry(sync_state, 3));
	_Bool primed = NUM2INT(rb_ary_entry(sync_state, 4)) != 0;

	if (taps < 1 || taps > WT_MAX_TAPS || os < 1 || CLASS_OF(ring) != numo_cDFloat || RNARRAY_NDIM(ring) != 1 || RNARRAY_SHAPE(ring)[0] != taps * cs || !RTEST(nary_check_contiguous(ring))) {
		rb_raise(rb_eArgError, "Ring must be a contiguous DFloat of taps (complex tables: 2 * taps) elements");
	}
	double *acc = (double *)(nary_get_pointer_for_write(ring) + nary_get_offset(ring));
	pos %= taps;

	size_t table_len = taps * os + 1;
	if (CLASS_OF(blep_v) != numo_cDFloat || RNARRAY_NDIM(blep_v) != 1 || RNARRAY_SHAPE(blep_v)[0] != table_len || !RTEST(nary_check_contiguous(blep_v))) {
		rb_raise(rb_eArgError, "The minBLEP table must be a contiguous DFloat of taps * oversample + 1 elements");
	}
	const double *blep = (const double *)(nary_get_pointer_for_read(blep_v) + nary_get_offset(blep_v));
	if (CLASS_OF(residuals) != numo_cDComplex || RNARRAY_NDIM(residuals) != 3 || RNARRAY_SHAPE(residuals)[0] < 2 ||
			RNARRAY_SHAPE(residuals)[1] != os + 2 || RNARRAY_SHAPE(residuals)[2] != taps || !RTEST(nary_check_contiguous(residuals))) {
		rb_raise(rb_eArgError, "Sync residuals must be a contiguous 3D DComplex of [rows (at least 2), oversample + 2, taps]");
	}
	struct wt_residuals rs = {
		.g = (const double *)(nary_get_pointer_for_read(residuals) + nary_get_offset(residuals)),
		.rows = (long)RNARRAY_SHAPE(residuals)[0],
	};

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	const float *freqptr = NULL;
	size_t freqptr_step = 1;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqptr_step);

	double pulse;
	const float *pulseptr = NULL;
	size_t pulseptr_step = 1;
	mb_read_signal_input(&pulses, length, "Sync", &pulse, &pulseptr, &pulseptr_step);
	if (!pulseptr) {
		pulse = 0;
	}

	double w;
	const float *wptr = NULL;
	size_t wptr_step = 1;
	if (!warped) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr, &wptr_step);
	w = wt_clamp_width(w);

	double sc;
	const float *scptr = NULL;
	size_t scptr_step = 1;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr, &scptr_step);

	struct wt_sel sel;
	sel.valid = 0;

	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = freqptr[i * freqptr_step];
		if (pulseptr) pulse = pulseptr[i * pulseptr_step];
		if (wptr) w = wt_clamp_width(wptr[i * wptr_step]);
		if (scptr) sc = scptr[i * scptr_step];

		double wf = 1.0;
		if (w != 0.5) {
			double k1 = 0.5 / w;
			double k2 = 0.5 / (1.0 - w);
			wf = k1 > k2 ? k1 : k2;
		}
		double m = fabs(freq * adv) * wf;

		if (primed) {
			double vel = dir * prev_inc;

			if (pulse != 0) {
				double d = 1.0 - fabs(pulse); // the event is d samples before this sample
				if (d < 0) d = 0;
				if (d > 1) d = 1;

				p = wt_wrap(p + vel * (1.0 - d), 1.0);
				double k0, k1;
				double u0 = wt_warp_slope(p, w, &k0);
				double v0re = 0, v0im = 0, v1re = 0, v1im = 0;
				if (bl) {
					wt_reselect(&t, m, sc, &sel);
					wt_value_sel(&t, u0, &sel, mode, cs, &ks, &v0re, &v0im);
				}

				double nvel;
				if (soft) {
					dir = -dir;
					nvel = -vel;
				} else {
					dir = 1.0;
					nvel = prev_inc;
					p = 0;
				}

				if (bl) {
					double u1 = wt_warp_slope(p, w, &k1);
					if (soft) {
						v1re = v0re;
						v1im = v0im;
					} else {
						wt_value_sel(&t, u1, &sel, mode, cs, &ks, &v1re, &v1im);
					}
					wt_sync_spectral(&t, &sel, u0, vel * k0, u1, nvel * k1, v0re, v0im, v1re, v1im, d, &rs, blep, os, taps, acc, pos, cs, limit);
				}
				vel = nvel;

				p = wt_wrap(p + vel * d, 1.0);
			} else {
				p = wt_wrap(p + vel, 1.0);
			}
		}

		double re, im;
		double u = w != 0.5 ? (p < w ? p * (0.5 / w) : 0.5 + (p - w) * (0.5 / (1.0 - w))) : p;
		wt_reselect(&t, m, sc, &sel);
		wt_value_dispatch(&t, u, &sel, mode, &ks, &re, &im);
		re += acc[pos];
		acc[pos] = 0;
		if (cs == 2) {
			im += acc[taps + pos];
			acc[taps + pos] = 0;
		}
		pos = (pos + 1) % taps;

		if (dc) {
			re -= wt_half_mean(&t, sc) * (2.0 * w - 1.0);
		}

		wt_store(out, cs, i, re, im, g, off);

		prev_inc = freq * adv;
		primed = 1;
	}

	if (length > 0) {
		rb_ary_store(sync_state, 0, rb_float_new(p));
		rb_ary_store(sync_state, 1, rb_float_new(prev_inc));
		rb_ary_store(sync_state, 2, rb_float_new(dir));
		rb_ary_store(sync_state, 3, SIZET2NUM(pos));
		rb_ary_store(sync_state, 4, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(frequency);
	RB_GC_GUARD(pulses);
	RB_GC_GUARD(width);
	RB_GC_GUARD(scan);
	RB_GC_GUARD(ring);
	RB_GC_GUARD(residuals);
	RB_GC_GUARD(blep_v);
	RB_GC_GUARD(buffer);

	return buffer;
}

// Complex.polar(a, angle) exactly as Ruby computes it for Floats:
// (a, 0.0) for a zero magnitude or angle, (-a, 0.0) at pi, (0.0, a) at pi / 2,
// else a cos and a sin.
static inline void wt_polar(double a, double angle, double *re, double *im)
{
	if (a == 0 || angle == 0) {
		*re = a;
		*im = 0.0;
	} else if (angle == M_PI) {
		*re = -a;
		*im = 0.0;
	} else if (angle == M_PI_2) {
		*re = 0.0;
		*im = a;
	} else {
		*re = a * cos(angle);
		*im = a * sin(angle);
	}
}

/*
 * call-seq: MB::Sound::FastWavetable.harmonic_spectra(out, amplitudes, phases) -> out
 *
 * Fills the zeroed contiguous DComplex +out+ ([rows, harmonics + 1]) with
 * the spectra of sine harmonics: +amplitudes+ and +phases+ (radians, or nil
 * for 0) are Arrays of +rows+ Arrays of Floats (equal lengths per row,
 * checked by the caller), column h is Complex.polar(a, p - pi / 2).  The
 * Ruby mirror is Wavetable::Builder.spectra_from_harmonics_ruby.
 */
static VALUE ruby_harmonic_spectra(VALUE self, VALUE out, VALUE amplitudes, VALUE phases)
{
	Check_Type(amplitudes, T_ARRAY);
	if (!NIL_P(phases)) {
		Check_Type(phases, T_ARRAY);
	}
	long rows = RARRAY_LEN(amplitudes);
	if (CLASS_OF(out) != numo_cDComplex || RNARRAY_NDIM(out) != 2 || !RTEST(nary_check_contiguous(out)) ||
			(long)RNARRAY_SHAPE(out)[0] != rows || (!NIL_P(phases) && RARRAY_LEN(phases) != rows)) {
		rb_raise(rb_eArgError, "Output must be a contiguous DComplex of [rows, harmonics + 1]");
	}
	size_t cols = RNARRAY_SHAPE(out)[1];
	double *o = (double *)(nary_get_pointer_for_write(out) + nary_get_offset(out));

	for (long r = 0; r < rows; r++) {
		VALUE arow = rb_ary_entry(amplitudes, r);
		Check_Type(arow, T_ARRAY);
		VALUE prow = NIL_P(phases) ? Qnil : rb_ary_entry(phases, r);
		if (!NIL_P(prow)) {
			Check_Type(prow, T_ARRAY);
		}
		long n = RARRAY_LEN(arow);
		if ((size_t)n + 1 > cols || (!NIL_P(prow) && RARRAY_LEN(prow) != n)) {
			rb_raise(rb_eArgError, "Row %ld doesn't fit the output", r);
		}

		for (long i = 0; i < n; i++) {
			double a = NUM2DBL(rb_ary_entry(arow, i));
			double p = NIL_P(prow) ? 0.0 : NUM2DBL(rb_ary_entry(prow, i));
			double *c = o + (r * cols + i + 1) * 2;
			wt_polar(a, p - M_PI / 2, c, c + 1);
		}
	}

	RB_GC_GUARD(amplitudes);
	RB_GC_GUARD(phases);
	return out;
}

/*
 * call-seq: MB::Sound::FastWavetable.half_means(out, spectra) -> out
 *
 * Fills the contiguous DFloat +out+ ([rows]) with the half means of the
 * contiguous DComplex +spectra+ ([rows, harmonics + 1]): the sum over odd h
 * of the real part of 2i c_h / (pi h), in harmonic order, with the products
 * as Ruby's Complex arithmetic does them (0 * re is a zero with re's sign).
 * The Ruby mirror is Wavetable::Builder.half_means_ruby.
 */
static VALUE ruby_half_means(VALUE self, VALUE out, VALUE spectra)
{
	if (CLASS_OF(spectra) != numo_cDComplex || RNARRAY_NDIM(spectra) != 2 || !RTEST(nary_check_contiguous(spectra)) ||
			CLASS_OF(out) != numo_cDFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out)) ||
			RNARRAY_SHAPE(out)[0] != RNARRAY_SHAPE(spectra)[0]) {
		rb_raise(rb_eArgError, "Spectra must be a contiguous DComplex [rows, harmonics + 1] and out a DFloat [rows]");
	}
	size_t rows = RNARRAY_SHAPE(spectra)[0], cols = RNARRAY_SHAPE(spectra)[1];
	const double *sp = (const double *)(nary_get_pointer_for_read(spectra) + nary_get_offset(spectra));
	double *o = (double *)(nary_get_pointer_for_write(out) + nary_get_offset(out));

	for (size_t r = 0; r < rows; r++) {
		double sum = 0.0;
		for (size_t h = 1; h < cols; h += 2) {
			double re = sp[(r * cols + h) * 2];
			double im = sp[(r * cols + h) * 2 + 1];
			double z = isnan(re) ? re * 0.0 : copysign(0.0, re);
			sum += (z - 2.0 * im) / (M_PI * (double)h);
		}
		o[r] = sum;
	}

	RB_GC_GUARD(spectra);
	return out;
}

void Init_fast_wavetable(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_wavetable_module = rb_define_module_under(sound, "FastWavetable");

	rb_define_module_function(fast_wavetable_module, "oscillate", ruby_oscillate, -1);
	rb_define_module_function(fast_wavetable_module, "lookup", ruby_lookup, 9);
	rb_define_module_function(fast_wavetable_module, "play", ruby_play, 11);
	rb_define_module_function(fast_wavetable_module, "sync", ruby_sync, -1);
	rb_define_module_function(fast_wavetable_module, "harmonic_spectra", ruby_harmonic_spectra, 3);
	rb_define_module_function(fast_wavetable_module, "half_means", ruby_half_means, 2);
}
