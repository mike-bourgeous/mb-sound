/*
 * MB::Sound::FastFilter: analog-style filter kernels (the four-pole and the
 * state-variable filter, ruby_svf below).
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
 * Self-oscillation curves (curve 2: linear below the onset, 3: dB below the
 * onset; fp_self_osc_gain): the bottom FP_SELF_OSC_ONSET (0.9) of the knob
 * is the linear or dB curve, compressed and reaching the oscillation edge
 * k = 4 at the onset, and above it k rises as 4 + (k_max - 4) x^2 (x = 0..1
 * over the rest of the knob), so the oscillation's amplitude (about
 * proportional to sqrt(k - 4) near the edge) grows roughly linearly with
 * the knob instead of jumping in.
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

// Self-oscillation curves: the resonance where oscillation starts, and the
// loop gain there (the analog filter's oscillation edge).
#define FP_SELF_OSC_ONSET 0.9
#define FP_SELF_OSC_EDGE 4.0

// Resonance curve numbers (FourPole::RESONANCE_CURVES and
// SELF_OSCILLATE_CURVES in Ruby).
#define FP_CURVE_LINEAR 0
#define FP_CURVE_DB 1
#define FP_CURVE_SELF_OSC_LINEAR 2
#define FP_CURVE_SELF_OSC_DB 3

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

// 1 / i! for i = 0..13 (FourPole::EXP_TAYLOR in Ruby).
static const double fp_exp_taylor[14] = {
	1.0, 1.0, 0.5, 0.16666666666666666, 0.041666666666666664, 0.0083333333333333332,
	0.0013888888888888889, 0.00019841269841269841, 2.4801587301587302e-05,
	2.7557319223985893e-06, 2.7557319223985888e-07, 2.505210838544172e-08,
	2.08767569878681e-09, 1.6059043836821613e-10,
};

// 2^y for y >= 0: a degree 13 Taylor series of e^(f ln 2) for the fraction
// f (relative error about 1e-13), scaled by 2^floor(y).
static inline double fp_exp2(double y)
{
	double n = floor(y);
	double x = (y - n) * FP_LN2;
	double p = fp_exp_taylor[13];
	for (int i = 12; i >= 0; i--) {
		p = p * x + fp_exp_taylor[i];
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

// The self-oscillation curves' loop gain k for resonance r (0..1) and top
// loop gain k_max (see the file comment): the linear (db 0) or dB (db 1)
// curve scaled to k = 4 at FP_SELF_OSC_ONSET, then a square rise to k_max.
static inline double fp_self_osc_gain(double r, int db, double k_max)
{
	if (r <= FP_SELF_OSC_ONSET) {
		double x = r / FP_SELF_OSC_ONSET;
		return (db ? fp_resonance_curve(x) : x) * FP_SELF_OSC_EDGE;
	}
	double x = (r - FP_SELF_OSC_ONSET) / (1.0 - FP_SELF_OSC_ONSET);
	return FP_SELF_OSC_EDGE + (k_max - FP_SELF_OSC_EDGE) * (x * x);
}

// The loop gain k for resonance r (0..1) on curve +curve+.
static inline double fp_loop_gain(double r, int curve, double k_max)
{
	switch (curve) {
		case FP_CURVE_DB:
			return fp_resonance_curve(r) * k_max;
		case FP_CURVE_SELF_OSC_LINEAR:
			return fp_self_osc_gain(r, 0, k_max);
		case FP_CURVE_SELF_OSC_DB:
			return fp_self_osc_gain(r, 1, k_max);
		default:
			return r * k_max;
	}
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
 * 0 (linear), 1 (dB), 2 (self-oscillation over linear), or 3
 * (self-oscillation over dB; +k_max+ is then the loop gain at r = 1);
 * +drive_mode+ 0 (input), 1 (stages), or 2
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
	if (curve < FP_CURVE_LINEAR || curve > FP_CURVE_SELF_OSC_DB) {
		rb_raise(rb_eArgError, "Resonance curve must be 0 (linear), 1 (dB), 2 (self-oscillating linear), or 3 (self-oscillating dB)");
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
	// (the loop gain only when the resonance changes)
	double last_fc = NAN, last_res = NAN;
	double g = 0, G = 0, G4 = 0, one = 1, k = 0, inv = 1, in_gain = 1;

	for (size_t i = 0; i < length; i++) {
		double fc = fc_ptr ? fc_ptr[i * fc_step] : fc_scalar;
		double res = res_ptr ? res_ptr[i * res_step] : res_scalar;

		if (fc != last_fc || res != last_res) {
			if (res != last_res) {
				last_res = res;
				if (!(res >= 0.0)) {
					res = 0.0;
				} else if (res > 1.0) {
					res = 1.0;
				}
				k = fp_loop_gain(res, curve, k_max);
				in_gain = 1.0 + comp * k;
			}

			if (fc != last_fc) {
				last_fc = fc;
				if (!(fc >= FP_MIN_CUTOFF)) {
					fc = FP_MIN_CUTOFF;
				} else if (fc > fc_max) {
					fc = fc_max;
				}
				g = fp_tan(fc * pi_over_rate);
				G = g / (1.0 + g);
				one = 1.0 - G;
				double G2 = G * G;
				G4 = G2 * G2;
			}

			inv = 1.0 / (1.0 + k * G4);
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

/*
 * svf: a linear trapezoidal state-variable filter (Andrew Simper's
 * "Cytomic" SVF, "Linear Trap Optimised 2"), with output mixes for the
 * RBJ cookbook responses (the same bilinear transform with the cutoff
 * prewarped, so static responses match MB::Sound::Filter::Cookbook).
 *
 * Its two states are integrator (capacitor) states rather than past
 * samples, so changing the cutoff, Q, or gain on any sample keeps the
 * output continuous: no thumps when a cutoff dives quickly to low values
 * (the direct form biquad's past outputs don't match new coefficients).
 *
 * Per change of cutoff fc, quality Q, or linear gain G:
 *   g = tan(pi fc / rate) (fp_tan), k = 1 / Q
 *   a1 = 1 / (1 + g (g + k)), a2 = g a1, a3 = g a2
 * and per sample (ic1, ic2 the states):
 *   v3 = x - ic2
 *   v1 = a1 ic1 + a2 v3          (band)
 *   v2 = ic2 + a2 ic1 + a3 v3    (low)
 *   ic1 = 2 v1 - ic1, ic2 = 2 v2 - ic2
 *   y = m0 x + m1 v1 + m2 v2
 *
 * Output mixes (m0, m1, m2), with A = sqrt(G) (the cookbook's
 * 10^(dB / 40)):
 *   lowpass (0, 0, 1); highpass (1, -k, -1); bandpass, 0 dB peak (0, k G, 0);
 *   bandpass_skirt, peak Q (0, G, 0); notch (1, -k, 0); allpass (1, -2k, 0);
 *   peak: k = 1 / (Q A), (1, k (G - 1), 0);
 *   lowshelf: g / sqrt(A), (1, k (A - 1), G - 1);
 *   highshelf: g sqrt(A), (G, k (1 - A) A, 1 - G).
 *
 * Exact Ruby mirror: MB::Sound::Filter::SVF.process_ruby (same operations;
 * the extension is built with -ffp-contract=off).
 */

// Filter types (MB::Sound::Filter::SVF::FILTER_TYPES, the same order as
// Cookbook::FILTER_TYPES)
#define SVF_LOWPASS 0
#define SVF_HIGHPASS 1
#define SVF_BANDPASS 2
#define SVF_NOTCH 3
#define SVF_ALLPASS 4
#define SVF_PEAK 5
#define SVF_LOWSHELF 6
#define SVF_HIGHSHELF 7
#define SVF_BANDPASS_SKIRT 8

// Lowest cutoff in Hz (NaN and negative values too), like FP_MIN_CUTOFF
#define SVF_MIN_CUTOFF 1.0
// Lowest quality and linear gain (NaN too)
#define SVF_MIN_QUALITY 1e-10
#define SVF_MIN_GAIN 1e-10

/*
 *   svf(buffer, cutoff, quality, gain, type, state, sample_rate)
 *
 * Filters +buffer+ (SFloat; modified in place if marked inplace).
 * +cutoff+ (Hz), +quality+, and +gain+ (linear; used by bandpass, peak,
 * and shelves) are Numerics or NArrays of the buffer's length (read as
 * float32).  +state+ is [ic1, ic2], updated.
 */
static VALUE ruby_svf(VALUE self, VALUE buffer, VALUE cutoff, VALUE quality, VALUE gain, VALUE type_v, VALUE state, VALUE rate_v)
{
	int type = NUM2INT(type_v);
	if (type < SVF_LOWPASS || type > SVF_BANDPASS_SKIRT) {
		rb_raise(rb_eArgError, "SVF filter type must be 0..8");
	}
	double rate = NUM2DBL(rate_v);
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}
	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 2) {
		rb_raise(rb_eArgError, "SVF state must have two elements");
	}
	double ic1 = fp_state_value(state, 0);
	double ic2 = fp_state_value(state, 1);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	double fc_scalar, q_scalar, g_scalar;
	const float *fc_ptr, *q_ptr, *g_ptr;
	size_t fc_step, q_step, g_step;
	mb_read_signal_input(&cutoff, length, "Cutoff", &fc_scalar, &fc_ptr, &fc_step);
	mb_read_signal_input(&quality, length, "Quality", &q_scalar, &q_ptr, &q_step);
	if (NIL_P(gain)) {
		gain = DBL2NUM(1.0);
	}
	mb_read_signal_input(&gain, length, "Gain", &g_scalar, &g_ptr, &g_step);

	double pi_over_rate = M_PI / rate;
	double fc_max = rate * FP_MAX_CUTOFF_RATIO;

	// Coefficients, recomputed only when an input changes
	double last_fc = NAN, last_q = NAN, last_g = NAN;
	double a1 = 1, a2 = 0, a3 = 0, m0 = 0, m1 = 0, m2 = 0;

	for (size_t i = 0; i < length; i++) {
		double fc = fc_ptr ? fc_ptr[i * fc_step] : fc_scalar;
		double q = q_ptr ? q_ptr[i * q_step] : q_scalar;
		double G = g_ptr ? g_ptr[i * g_step] : g_scalar;

		if (fc != last_fc || q != last_q || G != last_g) {
			last_fc = fc;
			last_q = q;
			last_g = G;

			if (!(fc >= SVF_MIN_CUTOFF)) {
				fc = SVF_MIN_CUTOFF;
			} else if (fc > fc_max) {
				fc = fc_max;
			}
			if (!(q >= SVF_MIN_QUALITY)) {
				q = SVF_MIN_QUALITY;
			}
			if (!(G >= SVF_MIN_GAIN)) {
				G = SVF_MIN_GAIN;
			}

			double g = fp_tan(fc * pi_over_rate);
			double k = 1.0 / q;
			double A;

			switch (type) {
				case SVF_HIGHPASS:
					m0 = 1.0; m1 = -k; m2 = -1.0;
					break;
				case SVF_BANDPASS:
					m0 = 0.0; m1 = k * G; m2 = 0.0;
					break;
				case SVF_BANDPASS_SKIRT:
					m0 = 0.0; m1 = G; m2 = 0.0;
					break;
				case SVF_NOTCH:
					m0 = 1.0; m1 = -k; m2 = 0.0;
					break;
				case SVF_ALLPASS:
					m0 = 1.0; m1 = -2.0 * k; m2 = 0.0;
					break;
				case SVF_PEAK:
					A = sqrt(G);
					k = 1.0 / (q * A);
					m0 = 1.0; m1 = k * (G - 1.0); m2 = 0.0;
					break;
				case SVF_LOWSHELF:
					A = sqrt(G);
					g = g / sqrt(A);
					m0 = 1.0; m1 = k * (A - 1.0); m2 = G - 1.0;
					break;
				case SVF_HIGHSHELF:
					A = sqrt(G);
					g = g * sqrt(A);
					m0 = G; m1 = k * (1.0 - A) * A; m2 = 1.0 - G;
					break;
				default:
					m0 = 0.0; m1 = 0.0; m2 = 1.0;
					break;
			}

			a1 = 1.0 / (1.0 + g * (g + k));
			a2 = g * a1;
			a3 = g * a2;
		}

		double x = data[i];
		double v3 = x - ic2;
		double v1 = a1 * ic1 + a2 * v3;
		double v2 = ic2 + a2 * ic1 + a3 * v3;
		ic1 = 2.0 * v1 - ic1;
		ic2 = 2.0 * v2 - ic2;
		data[i] = m0 * x + m1 * v1 + m2 * v2;
	}

	if (!isfinite(ic1) || fabs(ic1) < FP_FLUSH) {
		ic1 = 0.0;
	}
	if (!isfinite(ic2) || fabs(ic2) < FP_FLUSH) {
		ic2 = 0.0;
	}
	rb_ary_store(state, 0, rb_float_new(ic1));
	rb_ary_store(state, 1, rb_float_new(ic2));

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);
	RB_GC_GUARD(cutoff);
	RB_GC_GUARD(quality);
	RB_GC_GUARD(gain);

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

// Exposes the self-oscillation curves' loop gain for specs.
static VALUE ruby_self_osc_gain(VALUE self, VALUE r, VALUE db, VALUE k_max)
{
	return rb_float_new(fp_self_osc_gain(NUM2DBL(r), RTEST(db), NUM2DBL(k_max)));
}

void Init_fast_filter(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_filter = rb_define_module_under(sound, "FastFilter");

	rb_define_module_function(fast_filter, "four_pole", ruby_four_pole, -1);
	rb_define_module_function(fast_filter, "svf", ruby_svf, 7);
	rb_define_module_function(fast_filter, "tan", ruby_tan, 1);
	rb_define_module_function(fast_filter, "tanh", ruby_tanh, 1);
	rb_define_module_function(fast_filter, "secant", ruby_secant, 2);
	rb_define_module_function(fast_filter, "resonance_curve", ruby_resonance_curve, 1);
	rb_define_module_function(fast_filter, "self_osc_gain", ruby_self_osc_gain, 3);
}
