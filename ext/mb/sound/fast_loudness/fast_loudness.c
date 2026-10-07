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
 */
#include <math.h>

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

	RB_GC_GUARD(ext);
	RB_GC_GUARD(phases);

	return DBL2NUM(max);
}

void Init_fast_loudness(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_loudness = rb_define_module_under(sound, "FastLoudness");

	rb_define_module_function(fast_loudness, "true_peak", ruby_true_peak, 3);
}
