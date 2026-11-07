/*
 * The linear trapezoidal state-variable filter of FastFilter.svf (see the
 * description in fast_filter.c), shared by fast_filter.c and fast_loop.c
 * (SVF filters inside feedback loops) so both run the same operations.
 * Exact Ruby mirror: MB::Sound::Filter::SVF.process_ruby.  Built with
 * -ffp-contract=off in both extensions.  Moved here from fast_filter.c
 * (2026-10-09, feedback loops).
 */
#ifndef MB_SVF_H
#define MB_SVF_H

#include <math.h>

#include "mb_ext_helpers.h"

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
// First-order types (filters-acd-1, 2026-11-07): one pole (and one zero),
// run as the SVF at k = 2 (a double pole) with an output mix that cancels
// one of the poles, so they share every kernel, plan op, and loop op
#define SVF_LOWPASS1P 9
#define SVF_HIGHPASS1P 10
#define SVF_LOWSHELF1P 11
#define SVF_HIGHSHELF1P 12
#define SVF_TYPE_MAX 12
// Added to a type: the decramped design (mb_svf_decramp; only for the
// types mb_svf_type_valid accepts with it)
#define SVF_DECRAMP 16

// Lowest cutoff in Hz (NaN and negative values too), like FP_MIN_CUTOFF
#define SVF_MIN_CUTOFF 1.0
// Lowest quality and linear gain (NaN too)
#define SVF_MIN_QUALITY 1e-10
#define SVF_MIN_GAIN 1e-10

// True if +type+ is a filter type, with or without SVF_DECRAMP (decramped
// designs exist for the lowpass, highpass, bandpasses, notch, allpass, and
// the first-order lowpass and highpass).
static inline int mb_svf_type_valid(int type)
{
	if (type < 0) {
		return 0;
	}
	if (type & SVF_DECRAMP) {
		switch (type & ~SVF_DECRAMP) {
			case SVF_LOWPASS:
			case SVF_HIGHPASS:
			case SVF_BANDPASS:
			case SVF_BANDPASS_SKIRT:
			case SVF_NOTCH:
			case SVF_ALLPASS:
			case SVF_LOWPASS1P:
			case SVF_HIGHPASS1P:
				return 1;
			default:
				return 0;
		}
	}
	return type <= SVF_TYPE_MAX;
}

// Coefficients of one SVF, recomputed only when an input changes.
struct mb_svf {
	double last_fc, last_q, last_g;
	double a1, a2, a3, m0, m1, m2;
};

// Starts +s+ with no coefficients (the next mb_svf_coefficients computes
// them).
static inline void mb_svf_init(struct mb_svf *s)
{
	s->last_fc = s->last_q = s->last_g = NAN;
	s->a1 = 1;
	s->a2 = s->a3 = s->m0 = s->m1 = s->m2 = 0;
}

// The decramped design of filter +type+ (without SVF_DECRAMP; see
// mb_svf_type_valid) at +w0+ radians per sample, quality +q+, and linear gain
// +G+ (filters-acd-1, 2026-11-07): the SVF's g, k, and output mix for a
// digital response matched to the analog prototype's magnitude instead of
// the bilinear transform's, which squeezes the analog response above the
// cutoff into the space below Nyquist (the top octave falls 5-13 dB too
// fast at a 48 kHz rate).  After Martin Vicanek, "Matched Second Order
// Digital Filters" (2016): the poles are the analog poles mapped by
// z = e^(s T) (impulse invariance; a first-order type's one pole doubled),
// and the zeros are chosen for the analog magnitude at a few frequencies:
// lowpass at DC and the cutoff (one zero), highpass a double zero at DC and
// the cutoff, bandpasses a zero at DC, the slope near DC, and the peak,
// notch its zeros on the unit circle at the cutoff and DC, allpass the
// mirrored poles, lowpass1p DC and the cutoff, highpass1p a zero at DC and
// the cutoff.  The biquad (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2)
// is then written as the SVF it equals: with P = 1 + a1 + a2, M = 1 - a1 +
// a2, W = b0 + b1 + b2, V = b0 - b1 + b2, D = b0 - b2: g = sqrt(P / M),
// g k = 2 (1 - a2) / M, m0 = V / M, m1 = (2 D - g k V) / (g M), m2 = W / P -
// m0.  Exact Ruby mirror: Filter::SVF.decramp_design.
static inline void mb_svf_decramp(int type, double w0, double q, double G, double *gp, double *kp, double *m)
{
	double s1 = sin(0.5 * w0);
	double ph1 = s1 * s1;
	double ph0 = 1.0 - ph1;
	double P, M, a2;
	double p = 0.0;
	double e1 = 0.0; // a first-order type's |1 - p e^(-j w0)|^2
	double aw; // |A(e^(j w0))|^2, the poles' squared magnitude at the cutoff

	// (P, M, and aw as products of sums of positive terms: no cancellation
	// at low cutoffs, where the matched zeros come from small differences)
	if (type == SVF_LOWPASS1P || type == SVF_HIGHPASS1P) {
		p = exp(-w0);
		P = (1.0 - p) * (1.0 - p);
		M = (1.0 + p) * (1.0 + p);
		a2 = p * p;
		e1 = P + 4.0 * p * ph1;
		aw = e1 * e1;
	} else {
		double zeta = 0.5 / q;
		if (zeta < 1.0) {
			double r = exp(-zeta * w0);
			double rt = sqrt(1.0 - zeta * zeta);
			double sh = sin(0.5 * w0 * rt);
			double c = 4.0 * r * sh * sh;
			P = (1.0 - r) * (1.0 - r) + c;
			M = (1.0 + r) * (1.0 + r) - c;
			a2 = r * r;
			// (w0 -+ the poles' angle) / 2
			double sm = sin(0.5 * w0 * zeta * zeta / (1.0 + rt));
			double sp = sin(0.5 * w0 * (1.0 + rt));
			double r1 = (1.0 - r) * (1.0 - r);
			aw = (r1 + 4.0 * r * sm * sm) * (r1 + 4.0 * r * sp * sp);
		} else {
			double s = sqrt(zeta * zeta - 1.0);
			double p1 = exp(-w0 / (zeta + s));
			double p2 = exp(-w0 * (zeta + s));
			P = (1.0 - p1) * (1.0 - p2);
			M = (1.0 + p1) * (1.0 + p2);
			a2 = p1 * p2;
			aw = ((1.0 - p1) * (1.0 - p1) + 4.0 * p1 * ph1) * ((1.0 - p2) * (1.0 - p2) + 4.0 * p2 * ph1);
		}
	}

	double W, V, D;

	switch (type) {
		case SVF_HIGHPASS: {
			double h = q * sqrt(aw) / (4.0 * ph1);
			W = 0.0; V = 4.0 * h; D = 0.0;
			break;
		}
		case SVF_BANDPASS:
		case SVF_BANDPASS_SKIRT: {
			double pk = type == SVF_BANDPASS ? G : G * q;
			double sl = 2.0 * pk * P / (q * w0);
			double s0 = sl * sl;
			double r = pk * pk * aw / ph1;
			double b2 = (s0 - r) / (4.0 * ph1);
			double b1 = s0 - 4.0 * b2;
			if (!(b1 > 0.0)) {
				b1 = 0.0;
			}
			double disc = 0.25 * b1 + b2;
			W = 0.0; V = sqrt(b1); D = disc > 0.0 ? sqrt(disc) : 0.0;
			break;
		}
		case SVF_NOTCH:
			W = P; V = P * ph0 / ph1; D = 0.0;
			break;
		case SVF_ALLPASS:
			W = P; V = M; D = a2 - 1.0;
			break;
		case SVF_LOWPASS1P: {
			double c0 = P;
			double c1 = (0.5 * e1 - c0 * ph0) / ph1;
			double sc1 = c1 > 0.0 ? sqrt(c1) : 0.0;
			double z0 = 0.5 * ((1.0 - p) + sc1);
			double z1 = 0.5 * ((1.0 - p) - sc1);
			W = c0; V = sc1 * (1.0 + p); D = z0 + p * z1;
			break;
		}
		case SVF_HIGHPASS1P: {
			double c = sqrt(0.5 * e1 / (4.0 * ph1));
			W = 0.0; V = 2.0 * c * (1.0 + p); D = c * (1.0 - p);
			break;
		}
		default: { // lowpass
			double b1 = (q * q * aw - P * P * ph0) / ph1;
			double sb1 = b1 > 0.0 ? sqrt(b1) : 0.0;
			W = P; V = sb1; D = 0.5 * (P + sb1);
			break;
		}
	}

	double g = sqrt(P / M);
	double gk = 2.0 * (1.0 - a2) / M;
	*gp = g;
	*kp = gk / g;
	m[0] = V / M;
	m[1] = (2.0 * D - gk * V) / (g * M);
	m[2] = W / P - m[0];
}

// The design of filter +type+ for cutoff +fc+ (Hz), quality +q+, and
// linear gain +G+, clamped as in FastFilter.svf (+pi_over_rate+ is pi /
// sample rate, +fc_max+ the highest cutoff): the prewarped integrator gain
// *gp, damping *kp, and output mix m[0..2] (Filter::SVF.coefficients'
// g, k, m0, m1, m2; also used by the loops' pitch tracking for the
// filter's response, FastLoop.pitch_track).
static inline void mb_svf_design(int type, double fc, double q, double G, double pi_over_rate, double fc_max, double *gp, double *kp, double *m)
{
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

	if (type & SVF_DECRAMP) {
		mb_svf_decramp(type & ~SVF_DECRAMP, 2.0 * fc * pi_over_rate, q, G, gp, kp, m);
		return;
	}

	double g = mb_tan_pade(fc * pi_over_rate);
	double k = 1.0 / q;
	double A;
	double m0, m1, m2;

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
		case SVF_LOWPASS1P:
			// (s + 1) / (s + 1)^2
			k = 2.0;
			m0 = 0.0; m1 = 1.0; m2 = 1.0;
			break;
		case SVF_HIGHPASS1P:
			// s (s + 1) / (s + 1)^2
			k = 2.0;
			m0 = 1.0; m1 = -1.0; m2 = -1.0;
			break;
		case SVF_LOWSHELF1P:
			// 1 + (G - 1) / (s + 1), the pole at the cutoff for a boost and
			// at cutoff / G for a cut (its mirror image)
			k = 2.0;
			if (G < 1.0) {
				g = g / G;
			}
			m0 = 1.0; m1 = G - 1.0; m2 = G - 1.0;
			break;
		case SVF_HIGHSHELF1P:
			// G - (G - 1) / (s + 1), the pole at the cutoff for a boost and
			// at cutoff G for a cut (its mirror image)
			k = 2.0;
			if (G < 1.0) {
				g = g * G;
			}
			m0 = G; m1 = 1.0 - G; m2 = 1.0 - G;
			break;
		default:
			m0 = 0.0; m1 = 0.0; m2 = 1.0;
			break;
	}

	*gp = g;
	*kp = k;
	m[0] = m0;
	m[1] = m1;
	m[2] = m2;
}

// Updates the coefficients of +s+ for filter +type+ if the cutoff +fc+
// (Hz), quality +q+, or linear gain +G+ changed (clamped as in
// FastFilter.svf; +pi_over_rate+ is pi / sample rate, +fc_max+ the
// highest cutoff).
static inline void mb_svf_coefficients(struct mb_svf *s, int type, double fc, double q, double G, double pi_over_rate, double fc_max)
{
	if (fc == s->last_fc && q == s->last_q && G == s->last_g) {
		return;
	}

	s->last_fc = fc;
	s->last_q = q;
	s->last_g = G;

	double g, k, m[3];
	mb_svf_design(type, fc, q, G, pi_over_rate, fc_max, &g, &k, m);

	s->m0 = m[0];
	s->m1 = m[1];
	s->m2 = m[2];
	s->a1 = 1.0 / (1.0 + g * (g + k));
	s->a2 = g * s->a1;
	s->a3 = g * s->a2;
}

// One sample +x+ through a filter with coefficients a1, a2, a3 and output
// mix m0, m1, m2 (struct mb_svf's), with integrator states *ic1 and *ic2.
// Also the lane-major plan kernel's step (fast_plan's mb_plan_svf_lanes,
// several filters' samples interleaved), so both run the same operations.
static inline double mb_svf_step_with(double a1, double a2, double a3, double m0, double m1, double m2, double x, double *ic1p, double *ic2p)
{
	double ic1 = *ic1p, ic2 = *ic2p;
	double v3 = x - ic2;
	double v1 = a1 * ic1 + a2 * v3;
	double v2 = ic2 + a2 * ic1 + a3 * v3;
	*ic1p = 2.0 * v1 - ic1;
	*ic2p = 2.0 * v2 - ic2;
	return m0 * x + m1 * v1 + m2 * v2;
}

// One sample +x+ through the filter with integrator states *ic1 and *ic2.
static inline double mb_svf_step(const struct mb_svf *s, double x, double *ic1p, double *ic2p)
{
	return mb_svf_step_with(s->a1, s->a2, s->a3, s->m0, s->m1, s->m2, x, ic1p, ic2p);
}

// Filters (SVF, four-pole, diode ladder, formant) flush states below
// MB_FLUSH_MIN, or not finite, to zero on a grid of MB_FLUSH_GRID samples of
// the filter's own time (fixes-7, 2026-10-13: at the end of each buffer
// before, so tails below 1e-30 differed by buffer size), right after the
// grid point's last sample.  For a run of 800-sample buffers starting with
// the filter this flushes where the buffers ended before.  Each state
// Array keeps the samples since the last grid point after the states (a
// Float; absent in an old state: 0).
#define MB_FLUSH_GRID 800
#define MB_FLUSH_MIN 1e-30

// Flushes *x (see MB_FLUSH_GRID).
static inline void mb_flush_value(double *x)
{
	if (!isfinite(*x) || fabs(*x) < MB_FLUSH_MIN) {
		*x = 0.0;
	}
}

// The samples since the last flush grid point, from entry +idx+ of state
// Array +state+ (0 if absent or out of range).
static inline long mb_flush_count_read(VALUE state, long idx)
{
	if (RARRAY_LEN(state) > idx) {
		VALUE v = rb_ary_entry(state, idx);
		if (RB_FLOAT_TYPE_P(v)) {
			double k = RFLOAT_VALUE(v);
			if (k >= 0 && k < MB_FLUSH_GRID) {
				return (long)k;
			}
		}
	}
	return 0;
}

#endif
