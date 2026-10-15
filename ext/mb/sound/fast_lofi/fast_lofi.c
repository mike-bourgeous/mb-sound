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

#define DECIMATE_STATE_LENGTH 4

// Phases this close below a whole cycle count as reaching it, so rates that
// divide the sample rate hold exactly every N samples despite rounding.
#define DECIMATE_EDGE 1e-9

// The next uniform random number in 0...1 from the splitmix64 state *s (53
// bits; the same generator as noise_random in mb_osc_shapes.h, mirrored by
// MB::Sound::Tone.noise_random).
static inline double lofi_random(uint64_t *s)
{
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	z ^= z >> 31;
	return (double)(z >> 11) * 0x1.0p-53;
}

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

	double phase = st[0];
	float held = (float)st[1];
	double factor = st[2];
	float prev = (float)st[3];

	for (size_t i = 0; i < length; i++) {
		if (phase >= 1.0 - DECIMATE_EDGE) {
			phase -= mb_floor(phase + DECIMATE_EDGE);
			prev = held;
			held = (float)mb_signal_at(&xs, i);
			if (jitter > 0) {
				double u = lofi_random(rp);
				double spread = jitter * (2.0 * u - 1.0);
				factor = 1.0 + spread;
			}
		}
		if (mode == 1) {
			double t = phase < 1.0 ? phase : 1.0;
			op[i] = (float)((double)prev + ((double)held - (double)prev) * t);
		} else {
			op[i] = held;
		}

		double inc = mb_signal_at(&rs, i) / fs;
		if (!(inc > 0)) {
			inc = 0;
		} else if (inc > 1.0) {
			inc = 1.0;
		}
		phase += inc * factor;
	}

	st[0] = phase;
	st[1] = held;
	st[2] = factor;
	st[3] = prev;

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
