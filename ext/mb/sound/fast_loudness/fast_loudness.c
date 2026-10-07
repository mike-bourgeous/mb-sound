/*
 * Loudness measurement kernels (ITU-R BS.1770-4) for MB::Sound::Loudness.
 *
 * MB::Sound::FastLoudness.true_peak(ext, n) runs BS.1770-4 Annex 2's 4x
 * polyphase interpolation filter over n samples and returns the largest
 * absolute oversampled value.  Its exact Ruby mirror is
 * MB::Sound::Loudness::TruePeak.oversampled_max_ruby; both accumulate each
 * output as ((0 + h[0] x[i]) + h[1] x[i-1]) + ... in double precision, in
 * the same order, so specs compare them for exact equality (built with
 * -ffp-contract=off so no FMAs change the rounding).
 */
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#define TP_PHASES 4
#define TP_TAPS 12
#define TP_HISTORY (TP_TAPS - 1)

// Must match MB::Sound::Loudness::TruePeak::PHASES.
static const double tp_phases[TP_PHASES][TP_TAPS] = {
	{0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
	 0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500},
	{-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
	 0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375},
	{-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
	 0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875},
	{-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
	 0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750},
};

/*
 * call-seq:
 *   MB::Sound::FastLoudness.true_peak(ext, n) -> Float
 *
 * +ext+ is a Numo::DFloat of TP_HISTORY (11) earlier samples followed by
 * +n+ new samples.  Returns the largest absolute value of the four
 * interpolation phases over the +n+ new samples (0.0 for n == 0).
 */
static VALUE ruby_true_peak(VALUE self, VALUE ext, VALUE n_value)
{
	long n = NUM2LONG(n_value);
	if (n < 0) {
		rb_raise(rb_eArgError, "Sample count must not be negative (got %ld)", n);
	}

	if (CLASS_OF(ext) != numo_cDFloat) {
		rb_raise(rb_eArgError, "Samples must be a Numo::DFloat");
	}
	if (!RTEST(nary_check_contiguous(ext))) {
		ext = nary_dup(ext);
	}

	narray_t *na;
	GetNArray(ext, na);
	if (NA_NDIM(na) != 1) {
		rb_raise(rb_eArgError, "Samples must be one-dimensional");
	}
	if ((long)NA_SIZE(na) < n + TP_HISTORY) {
		rb_raise(rb_eArgError, "Need %ld samples (%d history + %ld), got %ld", n + TP_HISTORY, TP_HISTORY, n, (long)NA_SIZE(na));
	}

	const double *x = (const double *)(nary_get_pointer_for_read(ext) + nary_get_offset(ext));

	double max = 0.0;
	for (int p = 0; p < TP_PHASES; p++) {
		const double *h = tp_phases[p];
		for (long i = 0; i < n; i++) {
			// x[TP_HISTORY + i] is the current sample; tap k reads k back.
			const double *xi = x + TP_HISTORY + i;
			double y = 0.0;
			for (int k = 0; k < TP_TAPS; k++) {
				y += xi[-k] * h[k];
			}
			y = fabs(y);
			if (y > max) {
				max = y;
			}
		}
	}

	RB_GC_GUARD(ext);

	return DBL2NUM(max);
}

void Init_fast_loudness(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_loudness = rb_define_module_under(sound, "FastLoudness");

	rb_define_module_function(fast_loudness, "true_peak", ruby_true_peak, 2);
}
