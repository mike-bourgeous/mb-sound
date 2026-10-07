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
 * u = x (1 + c k) - k y4 = x - k (y4 - c x), so the DC gain is
 * (1 + c k) / (1 + k); c = 0.375 loses 6 dB of bass at k = 4 instead of
 * 12 dB (the CEM3379 datasheet's "constant amplitude" behavior).
 *
 * Resonance curve: the resonance r (0..1) gives the loop gain k = f(r) ×
 * k_max, with f(r) = r (linear) or the dB curve (fp_resonance_curve), which
 * makes the gain at the cutoff frequency (relative to DC) rise linearly in
 * dB from -12 dB at r = 0 to +33.8 dB at r = 1 (k = 3.9).
 *
 * Drive modes (all off with drive 0; tanh_d(z) = tanh(d z) / d):
 * - input: tanh_d on the solved input u of the cascade (one step after the
 *   linear loop solution).
 * - stages: every OTA stage saturates its drive current, dy/dt = wc
 *   tanh_d(x - y).  Zavalishin's "cheap" one-step method: the linear loop
 *   solution predicts each stage's input difference e, the stage's gain g
 *   becomes g tanh_d(e) / e (the secant), and the loop is solved again in
 *   closed form with those per-stage gains.
 * - feedback: a clipper (soft tanh_d, or hard: a clamp with a short
 *   quadratic knee) on the resonance feedback signal y4 - c x only (the
 *   Korg MS-20's diode clipper idea), with the same secant step: the loop
 *   gain becomes k clip_d(r) / r at the linear prediction r.
 *
 * tan, tanh, and 2^x are approximations using only +, -, *, /, floor, and
 * ldexp, so that every platform (glibc, macOS libm) and the Ruby mirror,
 * MB::Sound::Filter::FourPole.process_ruby, give identical samples; the
 * extension is built with -ffp-contract=off so no multiply-adds are fused.
 * Keep the operations here and in the mirror identical.
 */

#include <stdlib.h>
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

// Cutoff limits: at least 1 Hz, at most this fraction of the sample rate.
#define FP_MIN_CUTOFF 1.0
#define FP_MAX_CUTOFF_RATIO 0.49

// States smaller than this are flushed to zero at the end of each buffer
// (no denormals while decaying into silence).
#define FP_FLUSH 1e-30

// The resonance curve's top loop gain (the default k_max) and log2 of
// 4 (1 + k) / (4 - k) there (= log2(196)), the ratio of the gains at the
// cutoff at r = 1 and r = 0.
#define FP_CURVE_K 3.9
#define FP_CURVE_LOG2_RATIO 7.6147098441152083
#define FP_LN2 0.69314718055994529

// Drive modes and clip shapes (FourPole::DRIVE_MODES and CLIPS in Ruby).
#define FP_DRIVE_INPUT 0
#define FP_DRIVE_STAGES 1
#define FP_DRIVE_FEEDBACK 2
#define FP_CLIP_SOFT 0
#define FP_CLIP_HARD 1

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

// fp_tanh(x) / x (1 at 0): the secant gain of the soft saturator.
static inline double fp_tanh_secant(double x)
{
	double a = fabs(x);
	if (a > 3.0) {
		return 1.0 / a;
	}
	double x2 = x * x;
	return (27.0 + x2) / (27.0 + 9.0 * x2);
}

// The hard clipper's secant gain: the clipper is linear up to |x| = 0.8,
// then a quadratic knee reaching 1 with zero slope at 1.2, then +-1.
static inline double fp_hard_secant(double x)
{
	double a = fabs(x);
	if (a <= 0.8) {
		return 1.0;
	}
	if (a < 1.2) {
		double d = a - 0.8;
		return (a - d * d * 1.25) / a;
	}
	return 1.0 / a;
}

// 2^y for y >= 0: a Taylor series of e^(f ln 2) for the fraction f (good to
// about 1e-15), scaled by 2^floor(y).
static inline double fp_exp2(double y)
{
	double n = floor(y);
	double x = (y - n) * FP_LN2;
	double p = 1.0;
	for (int i = 16; i >= 1; i--) {
		p = 1.0 + x * p / i;
	}
	return ldexp(p, (int)n);
}

// The dB resonance curve: k / k_max for resonance r (0..1).  With G the
// gain at the cutoff relative to DC, (1 + k) / (4 - k) for an analog
// 4-pole (and the TPT one), G = 2^(r log2(196)) / 4 runs from 1/4 (-12 dB)
// to 49 (+33.8 dB, k = 3.9), and k = (4 G - 1) / (1 + G).
static inline double fp_resonance_curve(double r)
{
	if (!(r > 0.0)) {
		return 0.0;
	}
	if (r >= 1.0) {
		return 1.0;
	}
	double e = fp_exp2(r * FP_CURVE_LOG2_RATIO);
	return (e - 1.0) / ((1.0 + 0.25 * e) * FP_CURVE_K);
}

static double fp_state_value(VALUE state, long idx)
{
	double v = NUM2DBL(rb_ary_entry(state, idx));
	return isfinite(v) ? v : 0.0;
}

/*
 * Filters +buffer+ (SFloat, modified in place if marked inplace):
 *   four_pole(buffer, cutoff, resonance, state, sample_rate, k_max,
 *             compensation, drive, mix, curve = 0, drive_mode = 0, clip = 0)
 *
 * +cutoff+ (Hz) and +resonance+ (0..1, through the curve and times +k_max+
 * for the loop gain k) are Numerics or NArrays of the buffer's length (read
 * as float32).  +state+ is a 4-element Array of the integrator states,
 * updated.  +drive+ 0 is linear.  +mix+ is 5 output gains for the cascade
 * input and the four stage outputs (lowpass 4: [0, 0, 0, 0, 1]).  +curve+ is
 * 0 (linear) or 1 (dB); +drive_mode+ 0 (input), 1 (stages), or 2
 * (feedback); +clip+ 0 (soft) or 1 (hard), for the feedback mode.
 */
static VALUE ruby_four_pole(int argc, VALUE *argv, VALUE self)
{
	if (argc < 9 || argc > 12) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 9..12)", argc);
	}
	VALUE buffer = argv[0], cutoff = argv[1], resonance = argv[2], state = argv[3];
	double rate = NUM2DBL(argv[4]);
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}
	double k_max = NUM2DBL(argv[5]);
	double comp = NUM2DBL(argv[6]);
	double drive = NUM2DBL(argv[7]);
	VALUE mix_v = argv[8];
	if (!isfinite(k_max) || !isfinite(comp) || !(drive >= 0) || !isfinite(drive)) {
		rb_raise(rb_eArgError, "Filter parameters must be finite (and drive not negative)");
	}
	int curve = argc > 9 ? NUM2INT(argv[9]) : 0;
	int drive_mode = argc > 10 ? NUM2INT(argv[10]) : FP_DRIVE_INPUT;
	int clip = argc > 11 ? NUM2INT(argv[11]) : FP_CLIP_SOFT;
	if (curve < 0 || curve > 1) {
		rb_raise(rb_eArgError, "Resonance curve must be 0 (linear) or 1 (dB)");
	}
	if (drive_mode < FP_DRIVE_INPUT || drive_mode > FP_DRIVE_FEEDBACK) {
		rb_raise(rb_eArgError, "Drive mode must be 0 (input), 1 (stages), or 2 (feedback)");
	}
	if (clip < FP_CLIP_SOFT || clip > FP_CLIP_HARD) {
		rb_raise(rb_eArgError, "Clip must be 0 (soft) or 1 (hard)");
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
	const float *fc_ptr, *res_ptr;
	size_t fc_step, res_step;
	mb_read_signal_input(&cutoff, length, "Cutoff", &fc_scalar, &fc_ptr, &fc_step);
	mb_read_signal_input(&resonance, length, "Resonance", &res_scalar, &res_ptr, &res_step);

	double pi_over_rate = M_PI / rate;
	double fc_max = rate * FP_MAX_CUTOFF_RATIO;
	double inv_drive = drive > 0 ? 1.0 / drive : 0.0;
	_Bool driven = drive > 0;

	// Coefficients, recomputed only when the cutoff or resonance changes
	double last_fc = NAN, last_res = NAN;
	double g = 0, G = 0, G4 = 0, one = 1, k = 0, inv = 1, in_gain = 1;

	for (size_t i = 0; i < length; i++) {
		double fc = fc_ptr ? fc_ptr[i * fc_step] : fc_scalar;
		double res = res_ptr ? res_ptr[i * res_step] : res_scalar;

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

			g = fp_tan(fc * pi_over_rate);
			G = g / (1.0 + g);
			one = 1.0 - G;
			double G2 = G * G;
			G4 = G2 * G2;
			k = (curve ? fp_resonance_curve(res) : res) * k_max;
			inv = 1.0 / (1.0 + k * G4);
			in_gain = 1.0 + comp * k;
		}

		double x = data[i];
		double sum = ((s0 * one * G + s1 * one) * G + s2 * one) * G + s3 * one;
		double u = (x * in_gain - k * sum) * inv;

		// Per-stage gains (all G unless the stages saturate)
		double Ga = G, Gb = G, Gc = G, Gd = G;

		if (driven) {
			if (drive_mode == FP_DRIVE_INPUT) {
				u = fp_tanh(u * drive) * inv_drive;
			} else if (drive_mode == FP_DRIVE_FEEDBACK) {
				double r = G4 * u + sum - comp * x;
				double T = clip == FP_CLIP_HARD ? fp_hard_secant(r * drive) : fp_tanh_secant(r * drive);
				double kT = k * T;
				u = (x * (1.0 + comp * kT) - kT * sum) / (1.0 + kT * G4);
			} else {
				// Linear predictions of each stage's input difference
				double p1 = G * (u - s0) + s0;
				double p2 = G * (p1 - s1) + s1;
				double p3 = G * (p2 - s2) + s2;
				double p4 = G * (p3 - s3) + s3;
				double ga = g * fp_tanh_secant((u - p1) * drive);
				double gb = g * fp_tanh_secant((p1 - p2) * drive);
				double gc = g * fp_tanh_secant((p2 - p3) * drive);
				double gd = g * fp_tanh_secant((p3 - p4) * drive);
				Ga = ga / (1.0 + ga);
				Gb = gb / (1.0 + gb);
				Gc = gc / (1.0 + gc);
				Gd = gd / (1.0 + gd);
				double sum2 = ((s0 * (1.0 - Ga) * Gb + s1 * (1.0 - Gb)) * Gc + s2 * (1.0 - Gc)) * Gd + s3 * (1.0 - Gd);
				u = (x * in_gain - k * sum2) / (1.0 + k * (Ga * Gb * Gc * Gd));
				u = fp_tanh(u * drive) * inv_drive;
			}
		}

		double v, y1, y2, y3, y4;
		v = Ga * (u - s0);
		y1 = v + s0;
		s0 = y1 + v;
		v = Gb * (y1 - s1);
		y2 = v + s1;
		s1 = y2 + v;
		v = Gc * (y2 - s2);
		y3 = v + s2;
		s2 = y3 + v;
		v = Gd * (y3 - s3);
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

// Exposes the saturators' secant gains for specs: clip 0 soft, 1 hard.
static VALUE ruby_secant(VALUE self, VALUE x, VALUE clip)
{
	double v = NUM2DBL(x);
	return rb_float_new(NUM2INT(clip) == FP_CLIP_HARD ? fp_hard_secant(v) : fp_tanh_secant(v));
}

// Exposes the dB resonance curve (k / k_max for resonance r) for specs.
static VALUE ruby_resonance_curve(VALUE self, VALUE r)
{
	return rb_float_new(fp_resonance_curve(NUM2DBL(r)));
}

void Init_fast_filter(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_filter = rb_define_module_under(sound, "FastFilter");

	rb_define_module_function(fast_filter, "four_pole", ruby_four_pole, -1);
	rb_define_module_function(fast_filter, "tan", ruby_tan, 1);
	rb_define_module_function(fast_filter, "tanh", ruby_tanh, 1);
	rb_define_module_function(fast_filter, "secant", ruby_secant, 2);
	rb_define_module_function(fast_filter, "resonance_curve", ruby_resonance_curve, 1);
}
