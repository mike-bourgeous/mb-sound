/*
 * MB::Sound::FastFilter: analog-style filter kernels.
 *
 * four_pole: a 4-pole resonant lowpass in the style of the CEM3379 (and
 * CEM3320): four one-pole OTA-C stages in a cascade with resonance feedback
 * from the last stage to the input, simulated with the topology-preserving
 * transform (trapezoidal integrators) and the feedback loop solved in closed
 * form (zero-delay feedback), after Zavalishin, "The Art of VA Filter
 * Design".
 *
 * Passband compensation: part of the input is added to the resonance path,
 * u = x (1 + c k) - k y4, so the DC gain is (1 + c k) / (1 + k); c = 0.375
 * loses 6 dB of bass at k = 4 instead of 12 dB (the CEM3379 datasheet's
 * "constant amplitude" behavior).
 *
 * The optional drive applies tanh(d u) / d to the solved input of the
 * cascade (a one-step nonlinearity that keeps the loop solution linear),
 * which also bounds the amplitude when the loop gain k exceeds 4 (self
 * oscillation).
 *
 * tan and tanh are rational approximations using only +, -, *, / so that
 * every platform (glibc, macOS libm) and the Ruby mirror,
 * MB::Sound::Filter::FourPole.process_ruby, give identical samples; the
 * extension is built with -ffp-contract=off so no multiply-adds are fused.
 * Keep the operations here and in the mirror identical.
 */

#include <stdlib.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

// Cutoff limits: at least 1 Hz, at most this fraction of the sample rate.
#define FP_MIN_CUTOFF 1.0
#define FP_MAX_CUTOFF_RATIO 0.49

// States smaller than this are flushed to zero at the end of each buffer
// (no denormals while decaying into silence).
#define FP_FLUSH 1e-30

// tan(w) for 0 <= w < pi/2: a [5/4] Pade approximation of tan(w / 2) (good
// to about 1e-16 at pi/4), then the double-angle formula.  Relative error
// under 4e-7 up to 0.49 pi.
static inline double fp_tan(double w)
{
	double y = w * 0.5;
	double y2 = y * y;
	double t = y * (945.0 - 105.0 * y2 + y2 * y2) / (945.0 - 420.0 * y2 + 15.0 * y2 * y2);
	return 2.0 * t / (1.0 - t * t);
}

// A smooth saturator close to tanh: x (27 + x^2) / (27 + 9 x^2) up to |x| = 3
// (where it reaches 1 with zero slope), then +-1.
static inline double fp_tanh(double x)
{
	if (x > 3.0) {
		return 1.0;
	}
	if (x < -3.0) {
		return -1.0;
	}
	double x2 = x * x;
	return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

static double fp_state_value(VALUE state, long idx)
{
	double v = NUM2DBL(rb_ary_entry(state, idx));
	return isfinite(v) ? v : 0.0;
}

/*
 * Filters +buffer+ (SFloat, modified in place if marked inplace):
 *   four_pole(buffer, cutoff, resonance, state, sample_rate, k_max,
 *             compensation, drive, mix)
 *
 * +cutoff+ (Hz) and +resonance+ (0..1, times +k_max+ for the loop gain k)
 * are Numerics or NArrays of the buffer's length (read as float32).
 * +state+ is a 4-element Array of the integrator states, updated.
 * +drive+ 0 is linear.  +mix+ is 5 output gains for the cascade input and
 * the four stage outputs (lowpass 4: [0, 0, 0, 0, 1]).
 */
static VALUE ruby_four_pole(VALUE self, VALUE buffer, VALUE cutoff, VALUE resonance, VALUE state,
		VALUE sample_rate, VALUE k_max_v, VALUE comp_v, VALUE drive_v, VALUE mix_v)
{
	double rate = NUM2DBL(sample_rate);
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}
	double k_max = NUM2DBL(k_max_v);
	double comp = NUM2DBL(comp_v);
	double drive = NUM2DBL(drive_v);
	if (!isfinite(k_max) || !isfinite(comp) || !(drive >= 0) || !isfinite(drive)) {
		rb_raise(rb_eArgError, "Filter parameters must be finite (and drive not negative)");
	}

	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) {
		rb_raise(rb_eArgError, "Four-pole state must have four elements");
	}
	Check_Type(mix_v, T_ARRAY);
	if (RARRAY_LEN(mix_v) != 5) {
		rb_raise(rb_eArgError, "Four-pole mix must have five elements");
	}
	double m0 = NUM2DBL(rb_ary_entry(mix_v, 0));
	double m1 = NUM2DBL(rb_ary_entry(mix_v, 1));
	double m2 = NUM2DBL(rb_ary_entry(mix_v, 2));
	double m3 = NUM2DBL(rb_ary_entry(mix_v, 3));
	double m4 = NUM2DBL(rb_ary_entry(mix_v, 4));

	double s0 = fp_state_value(state, 0);
	double s1 = fp_state_value(state, 1);
	double s2 = fp_state_value(state, 2);
	double s3 = fp_state_value(state, 3);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	double fc_scalar, res_scalar;
	complex float *fc_ptr, *res_ptr;
	mb_read_signal_input(&cutoff, length, "Cutoff", &fc_scalar, &fc_ptr);
	mb_read_signal_input(&resonance, length, "Resonance", &res_scalar, &res_ptr);

	double pi_over_rate = M_PI / rate;
	double fc_max = rate * FP_MAX_CUTOFF_RATIO;
	double inv_drive = drive > 0 ? 1.0 / drive : 0.0;

	// Coefficients, recomputed only when the cutoff or resonance changes
	double last_fc = NAN, last_res = NAN;
	double G = 0, one = 1, k = 0, inv = 1, in_gain = 1;

	for (size_t i = 0; i < length; i++) {
		double fc = fc_ptr ? crealf(fc_ptr[i]) : fc_scalar;
		double res = res_ptr ? crealf(res_ptr[i]) : res_scalar;

		if (fc != last_fc || res != last_res) {
			last_fc = fc;
			last_res = res;

			if (!(fc >= FP_MIN_CUTOFF)) {
				fc = FP_MIN_CUTOFF;
			} else if (fc > fc_max) {
				fc = fc_max;
			}
			if (!(res >= 0.0)) {
				res = 0.0;
			} else if (res > 1.0) {
				res = 1.0;
			}

			double g = fp_tan(fc * pi_over_rate);
			G = g / (1.0 + g);
			one = 1.0 - G;
			double G2 = G * G;
			k = res * k_max;
			inv = 1.0 / (1.0 + k * (G2 * G2));
			in_gain = 1.0 + comp * k;
		}

		double x = data[i];
		double sum = ((s0 * one * G + s1 * one) * G + s2 * one) * G + s3 * one;
		double u = (x * in_gain - k * sum) * inv;
		if (drive > 0) {
			u = fp_tanh(u * drive) * inv_drive;
		}

		double v, y1, y2, y3, y4;
		v = G * (u - s0);
		y1 = v + s0;
		s0 = y1 + v;
		v = G * (y1 - s1);
		y2 = v + s1;
		s1 = y2 + v;
		v = G * (y2 - s2);
		y3 = v + s2;
		s2 = y3 + v;
		v = G * (y3 - s3);
		y4 = v + s3;
		s3 = y4 + v;

		data[i] = m0 * u + m1 * y1 + m2 * y2 + m3 * y3 + m4 * y4;
	}

	double st[4] = { s0, s1, s2, s3 };
	for (int j = 0; j < 4; j++) {
		if (!isfinite(st[j]) || fabs(st[j]) < FP_FLUSH) {
			st[j] = 0.0;
		}
		rb_ary_store(state, j, rb_float_new(st[j]));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);
	RB_GC_GUARD(cutoff);
	RB_GC_GUARD(resonance);

	return buffer;
}

// Exposes the tan approximation for specs and the Ruby mirror's checks.
static VALUE ruby_tan(VALUE self, VALUE w)
{
	return rb_float_new(fp_tan(NUM2DBL(w)));
}

// Exposes the tanh approximation for specs.
static VALUE ruby_tanh(VALUE self, VALUE x)
{
	return rb_float_new(fp_tanh(NUM2DBL(x)));
}

void Init_fast_filter(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_filter = rb_define_module_under(sound, "FastFilter");

	rb_define_module_function(fast_filter, "four_pole", ruby_four_pole, 9);
	rb_define_module_function(fast_filter, "tan", ruby_tan, 1);
	rb_define_module_function(fast_filter, "tanh", ruby_tanh, 1);
}
