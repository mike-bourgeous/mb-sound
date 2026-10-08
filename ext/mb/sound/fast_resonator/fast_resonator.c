/*
 * Struck resonator ("ping") kernel for MB::Sound::GraphNode::Resonator.
 *
 * The resonator is a complex one-pole filter: every sample the state
 * z = zr + i zi is rotated by the angle 2 pi f / fs, shrunk by the decay
 * factor r = exp(-ln(1000) / decay_samples) (-60 dB after decay_samples),
 * and the input added to its real part:
 *
 *     z[n] = r e^(i w[n]) z[n - 1] + x[n]
 *     y[n] = Im(z[n] e^(i phi)) = zi cos(phi) + zr sin(phi)
 *
 * so a unit impulse rings as a sine of amplitude 1 starting at phase phi.
 * Rotating the state changes only its angle, never its size, so the
 * frequency (and the decay) may change every sample with no jump in level
 * (a direct-form biquad swept the same way pumps its ringing level).
 *
 * MB::Sound::FastResonator.ping(out, input, freq, decay, state, rate,
 * cos_phi, sin_phi) fills +out+; its exact Ruby mirror is
 * MB::Sound::GraphNode::Resonator.process_ruby, which does the same double
 * operations in the same order (built with -ffp-contract=off so no FMAs
 * change the rounding), so specs compare them for exact equality.
 */
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

// ln(1000): the decay factor reaches -60 dB after +decay+ samples.
#define RES_LN_1000 6.907755278982137

// States smaller than this (in both parts) are flushed to zero so the
// ringing ends instead of running into subnormal numbers.
#define RES_FLUSH 1e-30

/*
 * call-seq:
 *   MB::Sound::FastResonator.ping(out, input, freq, decay, state, rate, cos_phi, sin_phi) -> out
 *
 * +out+ is a contiguous Numo::SFloat whose length is the sample count.
 * +input+ (the excitation), +freq+ (Hz), and +decay+ (samples to -60 dB)
 * are each a Numeric or an NArray of that length (read as float32 values;
 * see mb_read_signal_input; nil input is silence).  +state+ is a contiguous
 * 2-element Numo::DFloat [zr, zi], updated in place.  +rate+ is the sample
 * rate.  Decays of 0 or less silence the resonator.
 */
static VALUE ruby_ping(VALUE self, VALUE out, VALUE input, VALUE freq, VALUE decay, VALUE state, VALUE rate, VALUE cos_phi, VALUE sin_phi)
{
	if (CLASS_OF(out) != numo_cSFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "Output must be a contiguous 1D Numo::SFloat");
	}
	if (CLASS_OF(state) != numo_cDFloat || RNARRAY_NDIM(state) != 1 || RNARRAY_SHAPE(state)[0] != 2 ||
			!RTEST(nary_check_contiguous(state))) {
		rb_raise(rb_eArgError, "State must be a contiguous 2-element Numo::DFloat");
	}

	size_t n = RNARRAY_SHAPE(out)[0];

	double x_scalar, f_scalar, d_scalar;
	const float *x_ptr, *f_ptr, *d_ptr;
	size_t x_step, f_step, d_step;
	mb_read_signal_input(&input, n, "Input", &x_scalar, &x_ptr, &x_step);
	mb_read_signal_input(&freq, n, "Frequency", &f_scalar, &f_ptr, &f_step);
	mb_read_signal_input(&decay, n, "Decay", &d_scalar, &d_ptr, &d_step);

	double fs = NUM2DBL(rate);
	if (!(fs > 0)) {
		rb_raise(rb_eArgError, "Sample rate must be positive");
	}
	double cp = NUM2DBL(cos_phi);
	double sp = NUM2DBL(sin_phi);

	float *y = mb_sfloat_ptr(out);
	double *z = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));
	double zr = z[0];
	double zi = z[1];

	// Coefficients are recomputed only when the frequency or decay changes
	// (NAN never compares equal, so the first sample computes them).
	double last_f = NAN, last_d = NAN;
	double c = 0, s = 0;

	for (size_t i = 0; i < n; i++) {
		double x = x_ptr ? x_ptr[i * x_step] : x_scalar;
		double f = f_ptr ? f_ptr[i * f_step] : f_scalar;
		double d = d_ptr ? d_ptr[i * d_step] : d_scalar;

		if (f != last_f || d != last_d) {
			double w = 2.0 * M_PI * f / fs;
			double r = d > 0 ? exp(-RES_LN_1000 / d) : 0.0;
			c = r * cos(w);
			s = r * sin(w);
			last_f = f;
			last_d = d;
		}

		double nr = c * zr - s * zi + x;
		double ni = s * zr + c * zi;
		if (fabs(nr) < RES_FLUSH && fabs(ni) < RES_FLUSH) {
			nr = 0.0;
			ni = 0.0;
		}
		zr = nr;
		zi = ni;

		y[i] = (float)(zi * cp + zr * sp);
	}

	z[0] = zr;
	z[1] = zi;

	RB_GC_GUARD(input);
	RB_GC_GUARD(freq);
	RB_GC_GUARD(decay);
	RB_GC_GUARD(state);
	RB_GC_GUARD(out);

	return out;
}

void Init_fast_resonator(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_resonator = rb_define_module_under(sound, "FastResonator");

	rb_define_module_function(fast_resonator, "ping", ruby_ping, 8);
}
