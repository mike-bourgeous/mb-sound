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
#include "mb_resonator.h"

// (The kernels are in mb_resonator.h, shared with the plan executor.)
#define RES_MODES_MAX MB_RES_MODES_MAX
#define RES_MODE_FIELDS MB_RES_MODE_FIELDS

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

	struct mb_signal xs, fsig, ds;
	mb_signal_input(&input, n, "Input", &xs);
	mb_signal_input(&freq, n, "Frequency", &fsig);
	mb_signal_input(&decay, n, "Decay", &ds);

	double fs = NUM2DBL(rate);
	if (!(fs > 0)) {
		rb_raise(rb_eArgError, "Sample rate must be positive");
	}
	double cp = NUM2DBL(cos_phi);
	double sp = NUM2DBL(sin_phi);

	float *y = mb_sfloat_ptr(out);
	double *z = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));
	mb_res_ping(y, &xs, &fsig, &ds, z, fs, cp, sp, n);

	RB_GC_GUARD(input);
	RB_GC_GUARD(freq);
	RB_GC_GUARD(decay);
	RB_GC_GUARD(state);
	RB_GC_GUARD(out);

	return out;
}

/*
 * call-seq:
 *   MB::Sound::FastResonator.modes(out, input, freq, decay, modes, state, rate) -> out
 *
 * A bank of struck resonators (GraphNode::ModalResonator): each mode k of
 * the flat Numo::DFloat +modes+ table (RES_MODE_FIELDS values per mode:
 * ratio, offset in Hz, amplitude, decay share) is a ping as above at
 * freq * ratio + offset Hz, falling 60 dB in decay * share samples, all
 * pinged by the same +input+; the output is the sum of each mode's ring
 * (phase 0: Im z) times its amplitude, summed in double in mode order.
 * Modes at or above MB_RES_MODE_CEILING of the sample rate, or at or below 0
 * Hz, are silent.  +state+ is a contiguous DFloat of 2 values per mode
 * [zr0, zi0, zr1, zi1, ...], updated in place.  Coefficients are recomputed
 * only when the frequency or decay changes.  Exact Ruby mirror:
 * MB::Sound::GraphNode::ModalResonator.process_ruby.
 */
static VALUE ruby_modes(VALUE self, VALUE out, VALUE input, VALUE freq, VALUE decay, VALUE modes, VALUE state, VALUE rate)
{
	if (CLASS_OF(out) != numo_cSFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "Output must be a contiguous 1D Numo::SFloat");
	}
	if (CLASS_OF(modes) != numo_cDFloat || RNARRAY_NDIM(modes) != 1 || !RTEST(nary_check_contiguous(modes))) {
		rb_raise(rb_eArgError, "Modes must be a contiguous 1D Numo::DFloat");
	}
	size_t mode_values = RNARRAY_SHAPE(modes)[0];
	if (mode_values == 0 || mode_values % RES_MODE_FIELDS != 0) {
		rb_raise(rb_eArgError, "Modes must have %d values per mode", RES_MODE_FIELDS);
	}
	size_t m = mode_values / RES_MODE_FIELDS;
	if (m > RES_MODES_MAX) {
		rb_raise(rb_eArgError, "At most %d modes (got %zu)", RES_MODES_MAX, m);
	}
	if (CLASS_OF(state) != numo_cDFloat || RNARRAY_NDIM(state) != 1 || RNARRAY_SHAPE(state)[0] != 2 * m ||
			!RTEST(nary_check_contiguous(state))) {
		rb_raise(rb_eArgError, "State must be a contiguous Numo::DFloat of 2 values per mode");
	}
	rb_check_frozen(out);
	rb_check_frozen(state);

	size_t n = RNARRAY_SHAPE(out)[0];

	struct mb_signal xs, fsig, ds;
	mb_signal_input(&input, n, "Input", &xs);
	mb_signal_input(&freq, n, "Frequency", &fsig);
	mb_signal_input(&decay, n, "Decay", &ds);

	double fs = NUM2DBL(rate);
	if (!(fs > 0)) {
		rb_raise(rb_eArgError, "Sample rate must be positive");
	}

	const double *table = (const double *)(nary_get_pointer_for_read(modes) + nary_get_offset(modes));
	float *y = mb_sfloat_ptr(out);
	double *z = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));
	mb_res_modes(y, &xs, &fsig, &ds, table, m, z, fs, n);

	RB_GC_GUARD(input);
	RB_GC_GUARD(freq);
	RB_GC_GUARD(decay);
	RB_GC_GUARD(modes);
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
	rb_define_module_function(fast_resonator, "modes", ruby_modes, 7);
}
