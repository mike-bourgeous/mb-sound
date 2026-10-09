/*
 * The four-pole lowpass (lp4) and diode ladder kernels of
 * MB::Sound::FastFilter.four_pole and .diode_ladder (see the descriptions
 * in fast_filter.c), shared with the plan layer's filter ops (fast_plan's
 * plan_filters.c) so a planned filter runs the same operations as its
 * node.  Moved here from fast_filter.c (2026-10-10).  Exact Ruby mirrors:
 * MB::Sound::Filter::FourPole.process_ruby and .diode_process_ruby; built
 * with -ffp-contract=off in every extension that includes it.
 */
#ifndef MB_FOUR_POLE_H
#define MB_FOUR_POLE_H

#include <math.h>
#include <stddef.h>

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


// The diode ladder's oscillation frequency in units of wc (sqrt(10/7)) and
// its inverse, the loop gain at the oscillation edge (901 / 49), its
// inverse, and the edge relative to lp4's (DL_EDGE_K / 4).
#define DL_INV_W180 0.8366600265340756
#define DL_EDGE_K 18.387755102040817
#define DL_INV_EDGE_K 0.05438401775804661
#define DL_SCALE 4.596938775510204

// The dB curve's top loop gain (0.975 DL_EDGE_K, like lp4's 3.9 / 4) and
// log2 of the gain ratio at the cutoff between r = 1 and r = 0
// (40 + 39 DL_EDGE_K = 757.12).
#define DL_CURVE_K 17.928061224489795
#define DL_CURVE_LOG2_RATIO 9.564382835097447

// The diode ladder's dB resonance curve: k / DL_CURVE_K for resonance r
// (0..1).  The gain at the cutoff relative to DC is G = (1 + k) / (K - k)
// (K = DL_EDGE_K); G = 2^(r log2(757.12)) / K runs from 1 / K (-25.3 dB) to
// +32.3 dB (k = DL_CURVE_K), and k = (K G - 1) / (1 + G).
static inline double dl_resonance_curve(double r)
{
	if (!(r > 0.0)) {
		return 0.0;
	}
	if (r >= 1.0) {
		return 1.0;
	}
	double e = fp_exp2(r * DL_CURVE_LOG2_RATIO);
	return (e - 1.0) / ((1.0 + e * DL_INV_EDGE_K) * DL_CURVE_K);
}

// The diode ladder's cutoff normalization (normalize = 1, the default):
// m0 - 1, where m0 = sqrt(10/7) / w12 and |D(j w12)| = 4 (the ladder alone
// is -12 dB there, like lp4 at its cutoff), and the fitted rational's
// coefficients (see dl_cutoff_scale; round 3, 2026-10-09: fitted to put
// the resonant peak at lp4's frequency from resonance 0.3 up, where round
// 2's 14.4 and 4.85 matched the -12 dB point and sounded darker).
#define DL_NORM_M0 1.8585129771571043
#define DL_NORM_B 2.1
#define DL_NORM_C 10.6

// The factor by which the normalized diode ladder raises its stages'
// frequency above the round-1 mapping (resonant peak at the cutoff) for
// loop gain k: without resonance its response falls 12 dB below DC at the
// cutoff like lp4's, and from resonance 0.3 up (dB curve) its resonant peak
// is at lp4's frequency: m = 1 + (m0 - 1) (1 - x) / (1 + b x + c x^2),
// x = k / DL_EDGE_K clamped to 0..1; 2.86 at x = 0, 1 at the oscillation
// edge (self-oscillation at the cutoff).
static inline double dl_cutoff_scale(double k)
{
	double x = k * DL_INV_EDGE_K;
	if (!(x > 0.0)) {
		x = 0.0;
	}
	if (x >= 1.0) {
		return 1.0;
	}
	return 1.0 + DL_NORM_M0 * (1.0 - x) / (1.0 + x * (DL_NORM_B + x * DL_NORM_C));
}

// The normalized diode ladder's saturation headroom for the input drive:
// the ladder passes 1 / DL_EDGE_K of the loop's input at the resonant
// frequency where lp4's cascade passes 1 / 4, so near the oscillation edge
// the saturator works at DL_SCALE times the level, and ringing and
// self-oscillation reach lp4's levels: 1 + (DL_SCALE - 1) x^2, x = k /
// DL_EDGE_K clamped to 0..1 (low resonance saturates like lp4).
static inline double dl_headroom(double k)
{
	double x = k * DL_INV_EDGE_K;
	if (!(x > 0.0)) {
		x = 0.0;
	} else if (x > 1.0) {
		x = 1.0;
	}
	return 1.0 + (DL_SCALE - 1.0) * (x * x);
}

// The normalized diode ladder's passband compensation for loop gain k,
// where lp4 has loop gain k4 at the same knob (fp_loop_gain): the c' for
// which the ladder's DC gain (1 + c' k) / (1 + k) equals lp4's (1 + c k4) /
// (1 + k4), so the bass and the level match lp4's at every resonance (the
// plain c left the diode 1-2 dB quieter from resonance 0.1 up).  k = 0
// keeps c (it multiplies k everywhere it is used).
static inline double dl_compensation(double k, double k4, double comp)
{
	if (!(k > 0.0)) {
		return comp;
	}
	double in_gain = (1.0 + k) * (1.0 + comp * k4) / (1.0 + k4);
	return (in_gain - 1.0) / k;
}

// The diode ladder's loop gain for resonance r (0..1) on +curve+: lp4's
// curves (fp_loop_gain, with the dB curve replaced by dl_resonance_curve)
// times DL_SCALE.
static inline double dl_loop_gain(double r, int curve, double k_max)
{
	switch (curve) {
		case FP_CURVE_DB:
			return dl_resonance_curve(r) * k_max * DL_SCALE;
		case FP_CURVE_SELF_OSC_LINEAR:
			return fp_self_osc_gain(r, 0, k_max) * DL_SCALE;
		case FP_CURVE_SELF_OSC_DB:
			if (r <= FP_SELF_OSC_ONSET) {
				return dl_resonance_curve(r / FP_SELF_OSC_ONSET) * FP_SELF_OSC_EDGE * DL_SCALE;
			}
			return fp_self_osc_gain(r, 1, k_max) * DL_SCALE;
		default:
			return r * k_max * DL_SCALE;
	}
}


// A four-pole or diode ladder's settings (the kernels' arguments other
// than the signals and the state).
struct mb_fp_args {
	double rate, k_max, comp, drive;
	double mix[5];      // four-pole output mix (cascade input, four stages)
	int curve, drive_mode, clip;
	int normalize;      // diode ladder only
};

// Flushes states that are not finite or below FP_FLUSH to zero (at the end
// of each buffer).
static inline void mb_fp_flush(double *st4)
{
	for (int j = 0; j < 4; j++) {
		if (!isfinite(st4[j]) || fabs(st4[j]) < FP_FLUSH) {
			st4[j] = 0.0;
		}
	}
}

// Filters +length+ samples of +in+ into +out+ (may be the same buffer) with
// the four-pole cascade (fast_filter.c's four_pole), updating the states
// +st4+ (not flushed).
static inline void mb_four_pole_run(const struct mb_fp_args *args, const float *in, float *out, size_t length,
		const struct mb_signal *fc_sig, const struct mb_signal *res_sig, double *st4)
{
	double rate = args->rate, k_max = args->k_max, comp = args->comp, drive = args->drive;
	int curve = args->curve, drive_mode = args->drive_mode, clip = args->clip;
	double m0 = args->mix[0], m1 = args->mix[1], m2 = args->mix[2], m3 = args->mix[3], m4 = args->mix[4];
	double s0 = st4[0], s1 = st4[1], s2 = st4[2], s3 = st4[3];
	struct mb_signal fc_in = *fc_sig, res_in = *res_sig;

	double pi_over_rate = M_PI / rate;
	double fc_max = rate * FP_MAX_CUTOFF_RATIO;
	double inv_drive = drive > 0 ? 1.0 / drive : 0.0;
	_Bool driven = drive > 0;

	// Coefficients, recomputed only when the cutoff or resonance changes
	// (the loop gain only when the resonance changes)
	double last_fc = NAN, last_res = NAN;
	double g = 0, G = 0, G4 = 0, one = 1, k = 0, inv = 1, in_gain = 1;

	for (size_t i = 0; i < length; i++) {
		double fc = mb_signal_at(&fc_in, i);
		double res = mb_signal_at(&res_in, i);

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
				g = mb_tan_pade(fc * pi_over_rate);
				G = g / (1.0 + g);
				one = 1.0 - G;
				double G2 = G * G;
				G4 = G2 * G2;
			}

			inv = 1.0 / (1.0 + k * G4);
		}

		double x = in[i];
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

		out[i] = (float)(m0 * u + m1 * y1 + m2 * y2 + m3 * y3 + m4 * y4);
	}

	st4[0] = s0;
	st4[1] = s1;
	st4[2] = s2;
	st4[3] = s3;
}

// Filters +length+ samples of +in+ into +out+ (may be the same buffer) with
// the diode ladder (fast_filter.c's diode_ladder), updating the states +st4+
// (not flushed).
static inline void mb_diode_ladder_run(const struct mb_fp_args *args, const float *in, float *out, size_t length,
		const struct mb_signal *fc_sig, const struct mb_signal *res_sig, double *st4)
{
	double rate = args->rate, k_max = args->k_max, comp = args->comp, drive = args->drive;
	int curve = args->curve, drive_mode = args->drive_mode, clip = args->clip, normalize = args->normalize;
	double s0 = st4[0], s1 = st4[1], s2 = st4[2], s3 = st4[3];
	struct mb_signal fc_in = *fc_sig, res_in = *res_sig;

	double pi_over_rate = M_PI / rate;
	double fc_max = rate * FP_MAX_CUTOFF_RATIO;
	double inv_drive = drive > 0 ? 1.0 / drive : 0.0;
	_Bool driven = drive > 0;

	// Coefficients, recomputed only when the cutoff or resonance changes:
	// the prewarped cutoff t, the stage frequency's scale (normalization
	// included) and the input saturator's drive and its inverse (headroom
	// included), g, the Thomas algorithm's reciprocal pivots r1..r4 and
	// back-substitution factors a1..a3, the response q1..q4 of the forward
	// pass to u, the loop gain k, and 1 / (1 + k q4)
	double last_fc = NAN, last_res = NAN;
	double t = 0, scale = DL_INV_W180, sat_drive = drive, sat_inv = inv_drive;
	double g = 0, r1 = 1, r2 = 1, r3 = 1, r4 = 1, a1 = 0, a2 = 0, a3 = 0;
	double q1 = 0, q2 = 0, q3 = 0, q4 = 0, k = 0, inv = 1, in_gain = 1, dcomp = comp;

	for (size_t i = 0; i < length; i++) {
		double fc = mb_signal_at(&fc_in, i);
		double res = mb_signal_at(&res_in, i);

		if (fc != last_fc || res != last_res) {
			if (res != last_res) {
				last_res = res;
				if (!(res >= 0.0)) {
					res = 0.0;
				} else if (res > 1.0) {
					res = 1.0;
				}
				k = dl_loop_gain(res, curve, k_max);
				if (normalize) {
					dcomp = dl_compensation(k, fp_loop_gain(res, curve, k_max), comp);
				}
				in_gain = 1.0 + dcomp * k;
				if (normalize) {
					scale = dl_cutoff_scale(k) * DL_INV_W180;
					double headroom = dl_headroom(k);
					sat_drive = drive / headroom;
					sat_inv = headroom * inv_drive;
				}
			}

			if (fc != last_fc) {
				last_fc = fc;
				if (!(fc >= FP_MIN_CUTOFF)) {
					fc = FP_MIN_CUTOFF;
				} else if (fc > fc_max) {
					fc = fc_max;
				}
				t = mb_tan_pade(fc * pi_over_rate);
			}

			g = t * scale;
			double d = 1.0 + 2.0 * g;
			r1 = 1.0 / d;
			a1 = g * r1;
			r2 = 1.0 / (d - g * a1);
			a2 = g * r2;
			r3 = 1.0 / (d - g * a2);
			a3 = g * r3;
			r4 = 1.0 / ((1.0 + g) - g * a3);
			q1 = g * r1;
			q2 = g * q1 * r2;
			q3 = g * q2 * r3;
			q4 = g * q3 * r4;

			inv = 1.0 / (1.0 + k * q4);
		}

		double x = in[i];

		// Forward pass from the states alone (u = 0)
		double p1 = s0 * r1;
		double p2 = (s1 + g * p1) * r2;
		double p3 = (s2 + g * p2) * r3;
		double p4 = (s3 + g * p3) * r4;

		double u = (x * in_gain - k * p4) * inv;
		if (driven) {
			if (drive_mode == FP_DRIVE_INPUT) {
				u = fp_tanh(u * sat_drive) * sat_inv;
			} else {
				double fb = p4 + q4 * u - dcomp * x;
				double T = clip == FP_CLIP_HARD ? fp_hard_secant(fb * drive) : fp_tanh_secant(fb * drive);
				double kT = k * T;
				u = (x * (1.0 + dcomp * kT) - kT * p4) / (1.0 + kT * q4);
			}
		}

		double y4 = p4 + q4 * u;
		double y3 = p3 + q3 * u + a3 * y4;
		double y2 = p2 + q2 * u + a2 * y3;
		double y1 = p1 + q1 * u + a1 * y2;

		s0 = 2.0 * y1 - s0;
		s1 = 2.0 * y2 - s1;
		s2 = 2.0 * y3 - s2;
		s3 = 2.0 * y4 - s3;

		out[i] = (float)(y4);
	}

	st4[0] = s0;
	st4[1] = s1;
	st4[2] = s2;
	st4[3] = s3;
}

#endif
