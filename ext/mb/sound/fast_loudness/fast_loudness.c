/*
 * Loudness measurement kernels (ITU-R BS.1770-4) for MB::Sound::Loudness.
 *
 * MB::Sound::FastLoudness.true_peak(ext, n, phases) runs a polyphase
 * interpolation filter (one row of taps per phase, e.g. BS.1770-4 Annex 2's
 * 4 x 12 taps) over n samples and returns the largest absolute oversampled
 * value.  Its exact Ruby mirror is
 * MB::Sound::Loudness::TruePeak.oversampled_max_ruby; both accumulate each
 * output as ((0 + h[0] x[i]) + h[1] x[i-1]) + ... in double precision, in
 * the same order, so specs compare them for exact equality (built with
 * -ffp-contract=off so no FMAs change the rounding).
 *
 * MB::Sound::FastLoudness.peak_sumsq(x, gain) gives the peak and the sum of
 * squares of a Numo::SFloat times +gain+ in one pass (the terminal UI's bus
 * and send meters, MB::Sound::UI::BusMeter); its exact Ruby mirror is
 * MB::Sound::UI::BusMeter.peak_sumsq_ruby.
 *
 * MB::Sound::FastLoudness.meter_block(buf, ext, x, phases, result) is one
 * buffer of the UI's master meter (peak, sum of squares, true peak with a
 * history kept in +ext+) without allocating; its exact mirror is
 * MB::Sound::UI::MasterMeter's Numo path.
 */
#include <math.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

// Returns a contiguous Numo::DFloat with +ndim+ dimensions, raising
// ArgumentError for other types.
static VALUE tp_dfloat(VALUE v, int ndim, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat) {
		rb_raise(rb_eArgError, "%s must be a Numo::DFloat", name);
	}
	if (!RTEST(nary_check_contiguous(v))) {
		v = nary_dup(v);
	}

	narray_t *na;
	GetNArray(v, na);
	if (NA_NDIM(na) != ndim) {
		rb_raise(rb_eArgError, "%s must have %d dimension%s", name, ndim, ndim == 1 ? "" : "s");
	}

	return v;
}

// The largest absolute oversampled value of +n+ samples at +x+ + (taps -
// 1), each preceded by taps - 1 earlier samples (see true_peak).
static double oversampled_max(const double *x, long n, const double *coeffs, long phase_count, long taps)
{
	long history = taps - 1;
	double max = 0.0;
	for (long p = 0; p < phase_count; p++) {
		const double *h = coeffs + p * taps;
		for (long i = 0; i < n; i++) {
			// x[history + i] is the current sample; tap k reads k back.
			const double *xi = x + history + i;
			double y = 0.0;
			for (long k = 0; k < taps; k++) {
				y += xi[-k] * h[k];
			}
			y = fabs(y);
			if (y > max) {
				max = y;
			}
		}
	}
	return max;
}

/*
 * call-seq:
 *   MB::Sound::FastLoudness.true_peak(ext, n, phases) -> Float
 *
 * +phases+ is a Numo::DFloat of shape [phase count, taps].  +ext+ is a
 * Numo::DFloat of (taps - 1) earlier samples followed by +n+ new samples.
 * Returns the largest absolute value of every phase over the +n+ new
 * samples (0.0 for n == 0).
 */
static VALUE ruby_true_peak(VALUE self, VALUE ext, VALUE n_value, VALUE phases)
{
	long n = NUM2LONG(n_value);
	if (n < 0) {
		rb_raise(rb_eArgError, "Sample count must not be negative (got %ld)", n);
	}

	ext = tp_dfloat(ext, 1, "Samples");
	phases = tp_dfloat(phases, 2, "Phases");

	narray_t *na;
	GetNArray(phases, na);
	long phase_count = (long)NA_SHAPE(na)[0];
	long taps = (long)NA_SHAPE(na)[1];
	if (phase_count < 1 || taps < 1) {
		rb_raise(rb_eArgError, "Phases must have at least one phase and one tap");
	}
	long history = taps - 1;

	GetNArray(ext, na);
	if ((long)NA_SIZE(na) < n + history) {
		rb_raise(rb_eArgError, "Need %ld samples (%ld history + %ld), got %ld", n + history, history, n, (long)NA_SIZE(na));
	}

	const double *x = (const double *)(nary_get_pointer_for_read(ext) + nary_get_offset(ext));
	const double *coeffs = (const double *)(nary_get_pointer_for_read(phases) + nary_get_offset(phases));

	double max = oversampled_max(x, n, coeffs, phase_count, taps);

	RB_GC_GUARD(ext);
	RB_GC_GUARD(phases);

	return DBL2NUM(max);
}

/*
 * call-seq:
 *   MB::Sound::FastLoudness.peak_sumsq(x, gain) -> [peak, sumsq]
 *
 * +x+ is a one-dimensional Numo::SFloat (a view is fine).  Each sample is
 * read as a float, widened to double, and multiplied by +gain+; returns the
 * largest absolute product and the sum of the products' squares, added in
 * order from the first sample, in double precision.
 */
static VALUE ruby_peak_sumsq(VALUE self, VALUE x, VALUE gain_value)
{
	double gain = NUM2DBL(gain_value);
	if (CLASS_OF(x) != numo_cSFloat) {
		rb_raise(rb_eArgError, "Samples must be a Numo::SFloat");
	}
	if (!RTEST(nary_check_contiguous(x))) {
		x = nary_dup(x);
	}

	narray_t *na;
	GetNArray(x, na);
	long n = (long)NA_SIZE(na);
	const float *data = (const float *)(nary_get_pointer_for_read(x) + nary_get_offset(x));

	double peak = 0.0;
	double sumsq = 0.0;
	for (long i = 0; i < n; i++) {
		double y = (double)data[i] * gain;
		double a = fabs(y);
		if (a > peak) {
			peak = a;
		}
		sumsq += y * y;
	}

	RB_GC_GUARD(x);

	return rb_ary_new_from_args(2, DBL2NUM(peak), DBL2NUM(sumsq));
}

/*
 * call-seq:
 *   MB::Sound::FastLoudness.meter_block(buf, ext, x, phases, result) -> result
 *
 * One buffer of the terminal UI's master meter (MB::Sound::UI::MasterMeter)
 * without allocating: +buf+ is a contiguous 1D Numo::SFloat of n samples,
 * +ext+ a contiguous Numo::DFloat holding (taps - 1) earlier samples at its
 * start and room for n more, +x+ a contiguous Numo::DFloat of n values,
 * +phases+ as for true_peak, and +result+ an Array.  Widens +buf+ to
 * double into +x+ and after the history in +ext+, stores [peak, sum of
 * squares, true peak] of the n samples in +result+ (as Numo's x.abs.max,
 * (x * x).sum in order, and true_peak), then moves the last taps - 1
 * samples of +ext+ to its start for the next buffer.  The exact mirror is
 * MasterMeter's Ruby path (MasterMeter.native = false).
 */
static VALUE ruby_meter_block(VALUE self, VALUE buf, VALUE ext, VALUE x, VALUE phases, VALUE result)
{
	Check_Type(result, T_ARRAY);
	if (CLASS_OF(buf) != numo_cSFloat || RNARRAY_NDIM(buf) != 1 || !RTEST(nary_check_contiguous(buf))) {
		rb_raise(rb_eArgError, "Samples must be a contiguous Numo::SFloat");
	}
	if (CLASS_OF(ext) != numo_cDFloat || RNARRAY_NDIM(ext) != 1 || !RTEST(nary_check_contiguous(ext)) ||
			CLASS_OF(x) != numo_cDFloat || RNARRAY_NDIM(x) != 1 || !RTEST(nary_check_contiguous(x))) {
		rb_raise(rb_eArgError, "History and output must be contiguous Numo::DFloats");
	}
	phases = tp_dfloat(phases, 2, "Phases");

	narray_t *na;
	GetNArray(phases, na);
	long phase_count = (long)NA_SHAPE(na)[0];
	long taps = (long)NA_SHAPE(na)[1];
	if (phase_count < 1 || taps < 1) {
		rb_raise(rb_eArgError, "Phases must have at least one phase and one tap");
	}
	long history = taps - 1;
	long n = (long)RNARRAY_SIZE(buf);
	if ((long)RNARRAY_SIZE(x) != n || (long)RNARRAY_SIZE(ext) < n + history) {
		rb_raise(rb_eArgError, "Need %ld output values and %ld history values (got %ld and %ld)",
				n, n + history, (long)RNARRAY_SIZE(x), (long)RNARRAY_SIZE(ext));
	}

	const float *in = (const float *)(nary_get_pointer_for_read(buf) + nary_get_offset(buf));
	double *e = (double *)(nary_get_pointer_for_write(ext) + nary_get_offset(ext));
	double *xo = (double *)(nary_get_pointer_for_write(x) + nary_get_offset(x));
	const double *coeffs = (const double *)(nary_get_pointer_for_read(phases) + nary_get_offset(phases));

	double peak = 0.0;
	double sumsq = 0.0;
	for (long i = 0; i < n; i++) {
		double v = (double)in[i];
		xo[i] = v;
		e[history + i] = v;
		double a = fabs(v);
		if (a > peak || i == 0) {
			peak = a;
		}
		sumsq += v * v;
	}

	double tp = oversampled_max(e, n, coeffs, phase_count, taps);
	memmove(e, e + n, (size_t)history * sizeof(double));

	rb_ary_store(result, 0, DBL2NUM(peak));
	rb_ary_store(result, 1, DBL2NUM(sumsq));
	rb_ary_store(result, 2, DBL2NUM(tp));

	RB_GC_GUARD(buf);
	RB_GC_GUARD(ext);
	RB_GC_GUARD(x);
	RB_GC_GUARD(phases);

	return result;
}

/*
 * call-seq:
 *   MB::Sound::FastLoudness.sum_squares(x) -> Float
 *
 * Numo's (x * x).sum for a contiguous 1D Numo::DFloat (squares added in
 * order from the first value), without the temporary product.
 */
static VALUE ruby_sum_squares(VALUE self, VALUE x)
{
	if (CLASS_OF(x) != numo_cDFloat || RNARRAY_NDIM(x) != 1 || !RTEST(nary_check_contiguous(x))) {
		rb_raise(rb_eArgError, "Values must be a contiguous one-dimensional Numo::DFloat");
	}
	long n = (long)RNARRAY_SIZE(x);
	const double *v = (const double *)(nary_get_pointer_for_read(x) + nary_get_offset(x));
	double sum = 0.0;
	for (long i = 0; i < n; i++) {
		sum += v[i] * v[i];
	}
	RB_GC_GUARD(x);
	return DBL2NUM(sum);
}

void Init_fast_loudness(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_loudness = rb_define_module_under(sound, "FastLoudness");

	rb_define_module_function(fast_loudness, "true_peak", ruby_true_peak, 3);
	rb_define_module_function(fast_loudness, "peak_sumsq", ruby_peak_sumsq, 2);
	rb_define_module_function(fast_loudness, "meter_block", ruby_meter_block, 5);
	rb_define_module_function(fast_loudness, "sum_squares", ruby_sum_squares, 1);
}
