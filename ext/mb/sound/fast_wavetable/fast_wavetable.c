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

#define WT_MAX_LEVELS 32
#define WT_GUARD 16 // Wavetable::GUARD
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
	if (RARRAY_LEN(spec) != 15) {
		rb_raise(rb_eArgError, "A wavetable kernel spec has 15 elements");
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

// The frames around +scan+ (0..1, clamped): *fa, *fb (-1 for one frame),
// and the blend *fs.
static inline __attribute__((always_inline)) void wt_frames(long count, double scan, long *fa, long *fb, double *fs)
{
	if (count == 1) {
		*fa = 0;
		*fb = -1;
		*fs = 0;
		return;
	}

	double f = scan * (double)(count - 1);
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
// redo the choice only when m or the scan changes.
struct wt_sel {
	double m, scan;
	_Bool valid;
	int k;
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
	wt_frames(t->frames, scan, &sel->fa, &sel->fb, &sel->fs);

	int n = t->nlevels;
	int k = 0;
	if (n > 1) {
		while (k < n - 1 && m > t->hi[k]) {
			k++;
		}
	}
	sel->k = k;
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

// The table's value at +u+ with the levels and frames of +sel+.
static inline __attribute__((always_inline)) void wt_value_sel(const struct wt_table *t, double u, const struct wt_sel *sel, int mode, int cs, const struct wt_sinc *ks, double *re, double *im)
{
	if (sel->two) {
		double re1, im1, re2, im2;
		wt_level_value(t, sel->k, u, sel->fa, sel->fb, sel->fs, mode, cs, ks, &re1, &im1);
		wt_level_value(t, sel->k + 1, u, sel->fa, sel->fb, sel->fs, mode, cs, ks, &re2, &im2);
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
	wt_frames(t->frames, scan, &fa, &fb, &fs);
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

/*
 * Band-limited warp corners.  A phase warp (width w != 0.5) bends the phase
 * at e = w (the table's middle, u = 0.5) and at the wrap (u = 0), so the
 * waveform's slope jumps there by T'(u) times the change in the warp's
 * slope (T' per cycle of the table, k1 = 0.5 / w before the knee, k2 =
 * 0.5 / (1 - w) after).  As in FastSynth.oscillate_bl, each crossing adds
 * a 2-point PolyBLAMP to the samples before and after it, at its sub-sample
 * time.  The table is continuous, so there are no value jumps.  T' is a
 * central difference of the interpolated table (WT_SLOPE_DELTA).
 */
#define WT_EPS 1e-9
#define WT_SLOPE_DELTA 1e-5

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

// The table's slope per cycle at +u+ (real and imaginary parts).
static inline void wt_table_slope(const struct wt_table *t, double u, double m, double sc, int mode, const struct wt_sinc *ks, double *re, double *im)
{
	double are, aim, bre, bim;
	wt_value(t, wt_wrap(u + WT_SLOPE_DELTA, 1.0), m, sc, mode, ks, &are, &aim);
	wt_value(t, wt_wrap(u - WT_SLOPE_DELTA, 1.0), m, sc, mode, ks, &bre, &bim);
	*re = (are - bre) / (2.0 * WT_SLOPE_DELTA);
	*im = (aim - bim) / (2.0 * WT_SLOPE_DELTA);
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
 *             phase_mod, width, scan, interpolation, remove_dc, sinc)
 *
 * The phase (state[0], cycles) advances like FastSound.phasor and
 * FastSynth.oscillate_bl: sample i reads phase phi + (increments 0...i)
 * (i * increment for a constant frequency), plus phase_mod / 2pi, warped
 * like oscillate_bl when +width+ isn't nil.  Levels are picked from the
 * motion per sample (increment plus the change in phase modulation) times
 * the warp's steeper slope.  With a warp and band-limited levels, the
 * warp's corners get PolyBLAMP corrections (see wt_corner_step).  tstate is
 * [position, last phase modulation, primed, last phase, last increment].
 */
static VALUE ruby_oscillate(VALUE self, VALUE buffer, VALUE spec, VALUE frequency, VALUE advance,
		VALUE gain, VALUE offset, VALUE state, VALUE tstate, VALUE phase_mod, VALUE width, VALUE scan,
		VALUE interp, VALUE remove_dc, VALUE sinc)
{
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
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	complex float *freqptr;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr);

	double pm;
	complex float *pmptr;
	mb_read_signal_input(&phase_mod, length, "Phase modulation", &pm, &pmptr);

	_Bool warped = !NIL_P(width);
	double w;
	complex float *wptr;
	if (!warped) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr);
	w = wt_clamp_width(w);

	double sc;
	complex float *scptr;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr);

	_Bool dc = RTEST(remove_dc) && warped;
	_Bool primed = NUM2INT(rb_ary_entry(tstate, 2)) != 0;
	double prev_pm = primed ? NUM2DBL(rb_ary_entry(tstate, 1)) : pm;
	double prev_e = NUM2DBL(rb_ary_entry(tstate, 3));
	double prev_inc = NUM2DBL(rb_ary_entry(tstate, 4));
	_Bool corners = warped && isfinite(t.hi[0]); // band-limited levels
	double pending_re = 0, pending_im = 0, pending_d = 0;

	_Bool constant = !freqptr;
	double steps = 0;
	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = crealf(freqptr[i]);
		if (pmptr) pm = crealf(pmptr[i]);
		if (wptr) w = wt_clamp_width(crealf(wptr[i]));
		if (scptr) sc = crealf(scptr[i]);

		double inc = freq * adv;
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

		double d = inc + (pm - prev_pm) * WT_INV_2PI;
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
				next_pm = pmptr ? crealf(pmptr[i + 1]) : pm;
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
	complex float *phptr;
	mb_read_signal_input(&phase, length, "Phase", &ph, &phptr);

	double inc = 0;
	complex float *incptr = NULL;
	if (!automatic && increments != Qfalse) {
		mb_read_signal_input(&increments, length, "Increments", &inc, &incptr);
	}

	double sc;
	complex float *scptr;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr);

	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (phptr) ph = crealf(phptr[i]);
		if (incptr) inc = crealf(incptr[i]);
		if (scptr) sc = crealf(scptr[i]);

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
	complex float *freqptr;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr);

	double ls = t.loop_start;
	double len = t.loop_end - t.loop_start;

	_Bool constant = !freqptr;
	double steps = 0, psteps = 0;
	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = crealf(freqptr[i]);

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
 * Hard and soft sync for cycle-mode tables, band-limited with minBLEP like
 * FastSynth.oscillate_sync: a sync pulse v at a sample resets the phase
 * (hard) or reverses its direction (soft) 1 - |v| samples earlier, and the
 * jump in the table's value and slope there adds a minimum-phase
 * band-limited step and ramp (tables from BandLimit.minblep_tables) into a
 * ring of the following samples.  The table itself is band-limited, so its
 * wrap needs no correction.  Slopes are central differences of the
 * interpolated table (WT_SLOPE_DELTA cycles each way).
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

// Adds an event +t+ samples before the current sample with jumps +dv+ in
// value and +ds+ in slope per sample to the ring (the same as sync_event
// in fast_synth.c).
static inline void wt_sync_event(double *acc, size_t pos, const double *blep, const double *blamp, size_t os, size_t taps, double t, double dv, double ds)
{
	if (dv == 0 && ds == 0) {
		return;
	}

	for (size_t j = 0; j < taps; j++) {
		double tt = t + j;
		acc[(pos + j) % taps] += dv * wt_sync_table(blep, os, taps, tt) + ds * wt_sync_table(blamp, os, taps, tt);
	}
}

// The table's (real) value at phase +p+ warped by +w+.
static inline double wt_shape(const struct wt_table *t, double p, double w, double m, double sc, int mode, const struct wt_sinc *ks)
{
	double u = w != 0.5 ? (p < w ? p * (0.5 / w) : 0.5 + (p - w) * (0.5 / (1.0 - w))) : p;
	double re, im;
	wt_value(t, u, m, sc, mode, ks, &re, &im);
	return re;
}

// The slope per cycle of wt_shape at +p+.
static inline double wt_slope(const struct wt_table *t, double p, double w, double m, double sc, int mode, const struct wt_sinc *ks)
{
	double a = wt_shape(t, wt_wrap(p + WT_SLOPE_DELTA, 1.0), w, m, sc, mode, ks);
	double b = wt_shape(t, wt_wrap(p - WT_SLOPE_DELTA, 1.0), w, m, sc, mode, ks);
	return (a - b) / (2.0 * WT_SLOPE_DELTA);
}

/*
 * A synced wavetable oscillator (see Wavetable#sync):
 *   sync(buffer, spec, frequency, advance, gain, offset, sync_state, ring,
 *        pulses, soft, width, scan, interpolation, remove_dc, blep, blamp,
 *        oversample, taps, band_limit, sinc)
 *
 * +sync_state+ and +ring+ are as for FastSynth.oscillate_sync ([phase,
 * last increment, direction, ring position, primed] and a DFloat of
 * +taps+ pending corrections).  Real tables only.
 */
static VALUE ruby_sync(int argc, VALUE *argv, VALUE self)
{
	if (argc != 20) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 20)", argc);
	}

	VALUE buffer = argv[0], spec = argv[1], frequency = argv[2], sync_state = argv[6], ring = argv[7];
	VALUE pulses = argv[8], width = argv[10], scan = argv[11], blep_v = argv[14], blamp_v = argv[15], sinc = argv[19];

	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0 || t.cs != 1) {
		rb_raise(rb_eArgError, "FastWavetable.sync needs a real cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(argv[12], sinc, &t, &ks);

	double adv = NUM2DBL(argv[3]);
	double g = NUM2DBL(argv[4]);
	double off = NUM2DBL(argv[5]);
	_Bool soft = RTEST(argv[9]);
	_Bool warped = !NIL_P(width);
	_Bool dc = RTEST(argv[13]) && warped;
	size_t os = NUM2SIZET(argv[16]);
	size_t taps = NUM2SIZET(argv[17]);
	_Bool bl = RTEST(argv[18]);

	Check_Type(sync_state, T_ARRAY);
	if (RARRAY_LEN(sync_state) != 5) {
		rb_raise(rb_eArgError, "Sync state must have five elements");
	}
	double p = NUM2DBL(rb_ary_entry(sync_state, 0));
	double prev_inc = NUM2DBL(rb_ary_entry(sync_state, 1));
	double dir = NUM2DBL(rb_ary_entry(sync_state, 2));
	size_t pos = NUM2SIZET(rb_ary_entry(sync_state, 3));
	_Bool primed = NUM2INT(rb_ary_entry(sync_state, 4)) != 0;

	if (taps < 1 || CLASS_OF(ring) != numo_cDFloat || RNARRAY_NDIM(ring) != 1 || RNARRAY_SHAPE(ring)[0] != taps || !RTEST(nary_check_contiguous(ring))) {
		rb_raise(rb_eArgError, "Ring must be a contiguous DFloat of taps elements");
	}
	double *acc = (double *)(nary_get_pointer_for_write(ring) + nary_get_offset(ring));
	pos %= taps;

	size_t table_len = taps * os + 1;
	if (CLASS_OF(blep_v) != numo_cDFloat || RNARRAY_SHAPE(blep_v)[0] != table_len || !RTEST(nary_check_contiguous(blep_v)) ||
			CLASS_OF(blamp_v) != numo_cDFloat || RNARRAY_SHAPE(blamp_v)[0] != table_len || !RTEST(nary_check_contiguous(blamp_v))) {
		rb_raise(rb_eArgError, "Tables must be contiguous DFloats of taps * oversample + 1 elements");
	}
	const double *blep = (const double *)(nary_get_pointer_for_read(blep_v) + nary_get_offset(blep_v));
	const double *blamp = (const double *)(nary_get_pointer_for_read(blamp_v) + nary_get_offset(blamp_v));

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	complex float *freqptr;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr);

	double pulse;
	complex float *pulseptr;
	mb_read_signal_input(&pulses, length, "Sync", &pulse, &pulseptr);
	if (!pulseptr) {
		pulse = 0;
	}

	double w;
	complex float *wptr;
	if (!warped) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr);
	w = wt_clamp_width(w);

	double sc;
	complex float *scptr;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr);

	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = crealf(freqptr[i]);
		if (pulseptr) pulse = crealf(pulseptr[i]);
		if (wptr) w = wt_clamp_width(crealf(wptr[i]));
		if (scptr) sc = crealf(scptr[i]);

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
				double v0 = wt_shape(&t, p, w, m, sc, mode, &ks);
				double s0 = wt_slope(&t, p, w, m, sc, mode, &ks);
				if (soft) {
					dir = -dir;
					double nvel = -vel;
					if (bl) wt_sync_event(acc, pos, blep, blamp, os, taps, d, 0, s0 * (nvel - vel));
					vel = nvel;
				} else {
					dir = 1.0;
					double nvel = prev_inc;
					p = 0;
					double v1 = wt_shape(&t, p, w, m, sc, mode, &ks);
					double s1 = wt_slope(&t, p, w, m, sc, mode, &ks);
					if (bl) wt_sync_event(acc, pos, blep, blamp, os, taps, d, v1 - v0, s1 * nvel - s0 * vel);
					vel = nvel;
				}

				p = wt_wrap(p + vel * d, 1.0);
			} else {
				p = wt_wrap(p + vel, 1.0);
			}
		}

		double v = wt_shape(&t, p, w, m, sc, mode, &ks);
		v += acc[pos];
		acc[pos] = 0;
		pos = (pos + 1) % taps;

		if (dc) {
			v -= wt_half_mean(&t, sc) * (2.0 * w - 1.0);
		}

		out[i] = v * g + off;

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
	RB_GC_GUARD(blep_v);
	RB_GC_GUARD(blamp_v);
	RB_GC_GUARD(buffer);

	return buffer;
}

void Init_fast_wavetable(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_wavetable_module = rb_define_module_under(sound, "FastWavetable");

	rb_define_module_function(fast_wavetable_module, "oscillate", ruby_oscillate, 14);
	rb_define_module_function(fast_wavetable_module, "lookup", ruby_lookup, 9);
	rb_define_module_function(fast_wavetable_module, "play", ruby_play, 11);
	rb_define_module_function(fast_wavetable_module, "sync", ruby_sync, -1);
}
