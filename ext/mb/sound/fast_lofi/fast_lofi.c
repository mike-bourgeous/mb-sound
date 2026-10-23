/*
 * MB::Sound::FastLofi: lo-fi kernels (deliberate aliasing).
 *
 * decimate(out, x, rate, state, rng, sample_rate, jitter, mode): a sample-rate
 * reducer ("decimator", "rate crusher") for GraphNode::Decimator.  A phase
 * accumulator advances by rate / sample_rate cycles each sample; on the
 * sample where it reaches 1 it wraps and the output takes that sample of
 * the input, holding it until the next wrap (a zero-order hold at a
 * fractional rate, with no lowpass before or after, so the input's
 * spectrum folds around the hold rate on purpose).  +x+ and +rate+ are
 * signal inputs (a Numeric or an NArray of out.length values, read as
 * float32 like the other kernels), so the rate can move every sample, e.g.
 * key-tracked from a note's frequency.  A rate at or above the sample rate
 * passes the input through (increments are capped at one cycle, so even
 * infinite rates keep the phase finite); zero, negative, or NaN rates hold
 * the last value.
 *
 * +mode+ 1 (linear, a first-order hold) ramps instead of holding: the
 * output moves in a straight line from the previous held value to the
 * newest one over each hold period (the phase, 0 at a hold and 1 at the
 * next, is the position), so the steps become corners: the images above
 * half the rate fall with sinc^2 instead of sinc (much less high ringing,
 * still folded), at the cost of one hold period of delay.  Mode 0 (the
 * default) is the zero-order hold.
 *
 * +state+ is a DFloat [phase, held value, period factor, previous held
 * value], updated in place (the phase starts at 1, so the first sample is
 * taken).  With +jitter+ > 0
 * (0..0.95) each hold period's increment is scaled by a new factor 1 +
 * jitter * (2u - 1), u uniform from the splitmix64 generator state in +rng+
 * (a one-value Numo::UInt64; the same generator as the noise oscillators).
 *
 * The Ruby mirror (GraphNode::Decimator.process_ruby) gives exactly the same
 * samples (specs check it), so keep the operations identical; built with
 * -ffp-contract=off.
 */

#include <stdint.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_decimate.h"

#define DECIMATE_STATE_LENGTH MB_DECIMATE_STATE_LENGTH

static VALUE ruby_decimate(VALUE self, VALUE out, VALUE x, VALUE rate, VALUE state, VALUE rng, VALUE sample_rate, VALUE jitter_v, VALUE mode_v)
{
	if (CLASS_OF(out) != numo_cSFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "The output must be a contiguous 1D SFloat");
	}
	if (CLASS_OF(state) != numo_cDFloat || RNARRAY_NDIM(state) != 1 || RNARRAY_SHAPE(state)[0] != DECIMATE_STATE_LENGTH ||
			!RTEST(nary_check_contiguous(state))) {
		rb_raise(rb_eArgError, "The state must be a contiguous DFloat of %d values", DECIMATE_STATE_LENGTH);
	}
	if (CLASS_OF(rng) != numo_cUInt64 || RNARRAY_NDIM(rng) != 1 || RNARRAY_SHAPE(rng)[0] != 1 || !RTEST(nary_check_contiguous(rng))) {
		rb_raise(rb_eArgError, "The random state must be a contiguous one-value UInt64");
	}
	rb_check_frozen(out);
	rb_check_frozen(state);
	rb_check_frozen(rng);

	double fs = NUM2DBL(sample_rate);
	if (!(fs > 0)) {
		rb_raise(rb_eArgError, "The sample rate must be positive");
	}
	double jitter = NUM2DBL(jitter_v);
	if (!(jitter >= 0 && jitter <= 0.95)) {
		rb_raise(rb_eArgError, "The jitter must be from 0 to 0.95");
	}
	int mode = NUM2INT(mode_v);
	if (mode != 0 && mode != 1) {
		rb_raise(rb_eArgError, "The mode must be 0 (hold) or 1 (linear)");
	}

	size_t length = RNARRAY_SHAPE(out)[0];
	struct mb_signal xs, rs;
	mb_signal_input(&x, length, "The input", &xs);
	mb_signal_input(&rate, length, "The rate", &rs);

	float *op = mb_sfloat_ptr(out);
	double *st = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));
	uint64_t *rp = (uint64_t *)(nary_get_pointer_for_write(rng) + nary_get_offset(rng));

	mb_decimate(op, &xs, &rs, st, rp, fs, jitter, mode, length);

	RB_GC_GUARD(x);
	RB_GC_GUARD(rate);

	return out;
}

void Init_fast_lofi(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_lofi = rb_define_module_under(sound, "FastLofi");

	rb_define_module_function(fast_lofi, "decimate", ruby_decimate, 8);
}
