/*
 * The cookbook biquad of MB::FastSound (cookbook coefficients, the direct
 * form biquad step, and dynamic_biquad's per-sample loop for moving cutoffs
 * and qualities), shared with the plan layer's filter ops (fast_plan's
 * plan_biquad.c) so a planned `structure: :biquad` filter runs the same
 * operations as its node.  Moved here from fast_sound.c (2026-10-10).
 * Both extensions build it with the same flags (no -ffp-contract=off:
 * fast_sound never had it; plan_biquad.c is its own file so nothing else
 * in fast_plan changes how it is compiled).
 */
#ifndef MB_BIQUAD_H
#define MB_BIQUAD_H

#include <math.h>
#include <stddef.h>

enum filter_types {
	FILT_LOWPASS,
	FILT_HIGHPASS,
	FILT_BANDPASS,
	FILT_NOTCH,
	FILT_ALLPASS,
	FILT_PEAK,
	FILT_LOWSHELF,
	FILT_HIGHSHELF,
	FILT_BANDPASS_SKIRT,
};

// Used by cookbook()
struct biquad_coeffs {
	double b0, b1, b2;
	double a1, a2;
	double omega; // angular frequency
};

static inline _Bool double_is_tiny(double v)
{
	return v < 1e-18 && v > -1e-18;
}

// Converted from lib/mb/sound/filter/biquad.rb
static inline double biquad_filter(
		double b0, double b1, double b2,
		double a1, double a2,
		double x0, double x1, double x2,
		double y1, double y2
		)
{
	double out = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;

	// Prevent denormals
	if (double_is_tiny(out) && double_is_tiny(y1) && double_is_tiny(y2)) {
		out = 0;
	}

	return out;
}


// Pass NaN for quality/bandwidth/slope to indicate "not set".
static inline struct biquad_coeffs cookbook(enum filter_types ftype, double rate, double center, double db_gain, double quality, double bandwidth_oct, double shelf_slope)
{
	struct biquad_coeffs coeffs = {};

	double amp = 0;
	if (!isnan(db_gain)) {
		amp = pow(10.0, db_gain / 40.0);
	}

	// Used by bandpass filters
	double linear_gain = 1;
	if (!isnan(db_gain)) {
		linear_gain = pow(10.0, db_gain / 20.0);
	}

	coeffs.omega = 2.0 * M_PI * center / rate;
	double cosine = cos(coeffs.omega);
	double sine = sin(coeffs.omega);

	double alpha;
	if (!isnan(quality)) {
		alpha = sine / (2.0 * quality);
	} else if (!isnan(bandwidth_oct)) {
		alpha = sine * sinh(M_LN2 / 2.0 * bandwidth_oct * coeffs.omega / sine);
	} else if (!isnan(shelf_slope)) {
		alpha = sine * 0.5 * sqrt((amp + 1.0 / amp) * (1.0 / shelf_slope - 1) + 2);
	} else {
		alpha = sine / 2.0; // assume quality of 1.0 if nothing was given
	}

	double a0_inv, am1, ap1, asq2al;
	switch(ftype) {
		case FILT_LOWPASS:
			a0_inv = 1.0 / (1.0 + alpha);
			coeffs.a1 = -2.0 * cosine * a0_inv;
			coeffs.a2 = (1.0 - alpha) * a0_inv;
			coeffs.b0 = 0.5 * (1.0 - cosine) * a0_inv;
			coeffs.b1 = (1.0 - cosine) * a0_inv;
			coeffs.b2 = 0.5 * (1.0 - cosine) * a0_inv;
			break;

		case FILT_HIGHPASS:
			a0_inv = 1.0 / (1.0 + alpha);
			coeffs.a1 = -2.0 * cosine * a0_inv;
			coeffs.a2 = (1.0 - alpha) * a0_inv;
			coeffs.b0 = 0.5 * (1.0 + cosine) * a0_inv;
			coeffs.b1 = -(1.0 + cosine) * a0_inv;
			coeffs.b2 = 0.5 * (1.0 + cosine) * a0_inv;
			break;

		case FILT_BANDPASS:
			a0_inv = 1.0 / (1.0 + alpha);
			coeffs.a1 = -2.0 * cosine * a0_inv;
			coeffs.a2 = (1.0 - alpha) * a0_inv;
			coeffs.b0 = alpha * a0_inv * linear_gain;
			coeffs.b1 = 0;
			coeffs.b2 = -alpha * a0_inv * linear_gain;
			break;

		case FILT_BANDPASS_SKIRT:
			// Constant skirt gain (peak gain Q): b0 = sin(w0) / 2 = Q alpha
			a0_inv = 1.0 / (1.0 + alpha);
			coeffs.a1 = -2.0 * cosine * a0_inv;
			coeffs.a2 = (1.0 - alpha) * a0_inv;
			coeffs.b0 = 0.5 * sine * a0_inv * linear_gain;
			coeffs.b1 = 0;
			coeffs.b2 = -0.5 * sine * a0_inv * linear_gain;
			break;

		case FILT_NOTCH:
			a0_inv = 1.0 / (1.0 + alpha);
			coeffs.a1 = -2.0 * cosine * a0_inv;
			coeffs.a2 = (1.0 - alpha) * a0_inv;
			coeffs.b0 = a0_inv;
			coeffs.b1 = -2.0 * cosine * a0_inv;
			coeffs.b2 = a0_inv;
			break;

		case FILT_ALLPASS:
			a0_inv = 1.0 / (1.0 + alpha);
			coeffs.a1 = -2.0 * cosine * a0_inv;
			coeffs.a2 = (1.0 - alpha) * a0_inv;
			coeffs.b0 = (1.0 - alpha) * a0_inv;
			coeffs.b1 = -2.0 * cosine * a0_inv;
			coeffs.b2 = (1.0 + alpha) * a0_inv;
			break;

		case FILT_PEAK:
			a0_inv = 1.0 / (1.0 + alpha / amp);
			coeffs.a1 = -2.0 * cosine * a0_inv;
			coeffs.a2 = (1.0 - alpha / amp) * a0_inv;
			coeffs.b0 = (1.0 + alpha * amp) * a0_inv;
			coeffs.b1 = -2.0 * cosine * a0_inv;
			coeffs.b2 = (1.0 - alpha * amp) * a0_inv;
			break;

		case FILT_LOWSHELF:
			ap1 = amp + 1;
			am1 = amp - 1;
			asq2al = 2.0 * sqrt(amp) * alpha;

			a0_inv = 1.0 / (ap1 + am1 * cosine + asq2al);
			coeffs.a1 = -2.0 * (am1 + ap1 * cosine) * a0_inv;
			coeffs.a2 = (ap1 + am1 * cosine - asq2al) * a0_inv;
			coeffs.b0 = amp * (ap1 - am1 * cosine + asq2al) * a0_inv;
			coeffs.b1 = 2.0 * amp * (am1 - ap1 * cosine) * a0_inv;
			coeffs.b2 = amp * (ap1 - am1 * cosine - asq2al) * a0_inv;

			break;

		case FILT_HIGHSHELF:
			ap1 = amp + 1;
			am1 = amp - 1;
			asq2al = 2.0 * sqrt(amp) * alpha;

			a0_inv = 1.0 / (ap1 - am1 * cosine + asq2al);
			coeffs.a1 = 2.0 * (am1 - ap1 * cosine) * a0_inv;
			coeffs.a2 = (ap1 - am1 * cosine - asq2al) * a0_inv;
			coeffs.b0 = amp * (ap1 + am1 * cosine + asq2al) * a0_inv;
			coeffs.b1 = -2.0 * amp * (am1 + ap1 * cosine) * a0_inv;
			coeffs.b2 = amp * (ap1 + am1 * cosine - asq2al) * a0_inv;

			break;

		default:
			// Pass-through unity gain filter if filter type was invalid
			coeffs.b0 = 1;
			coeffs.b1 = 0;
			coeffs.b2 = 0;
			coeffs.a1 = 0;
			coeffs.a2 = 0;
	}

	return coeffs;
}

// Lowest cutoff of dynamic cookbook filters in Hz
#define DYNAMIC_MIN_CUTOFF 1.0

// FastSound.dynamic_biquad's loop: filters +length+ samples of +in+ into
// +out+ (may be the same buffer) with the cookbook filter +ftype+ for the
// cutoff and quality of each sample (floats), +g+ the gain in dB (NaN for
// none); *bqp holds the coefficients before (used only if +length+ is 0)
// and the last sample's after; +st+ is [x1, x2, y1, y2], updated.
static inline void mb_dynamic_biquad_run(enum filter_types ftype, double rate, double g, const float *in, float *out,
		const float *cut, const float *q, size_t length, struct biquad_coeffs *bqp, double *st)
{
	const double f0_max = 0.49 * rate;
	struct biquad_coeffs bq = *bqp;
	double x0;
	double x1 = st[0];
	double x2 = st[1];
	double y0;
	double y1 = st[2];
	double y2 = st[3];
	for (size_t i = 0; i < length; i++) {
		// Clamped to DYNAMIC_MIN_CUTOFF (Cookbook::DYNAMIC_MIN_CUTOFF; NaN
		// and negative cutoffs included), as FourPole clamps to 1 Hz
		double f0 = cut[i] >= DYNAMIC_MIN_CUTOFF ? fmin(cut[i], f0_max) : DYNAMIC_MIN_CUTOFF;
		double quality = fmax(q[i], 1e-10);

		bq = cookbook(ftype, rate, f0, g, quality, NAN, NAN);
		x0 = in[i];
		y0 = biquad_filter(bq.b0, bq.b1, bq.b2, bq.a1, bq.a2, x0, x1, x2, y1, y2);
		out[i] = y0;
		y2 = y1;
		y1 = y0;
		x2 = x1;
		x1 = x0;
	}
	*bqp = bq;
	st[0] = x1;
	st[1] = x2;
	st[2] = y1;
	st[3] = y2;
}

#endif
