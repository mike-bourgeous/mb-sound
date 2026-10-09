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

// Lowest cutoff in Hz (NaN and negative values too), like FP_MIN_CUTOFF
#define SVF_MIN_CUTOFF 1.0
// Lowest quality and linear gain (NaN too)
#define SVF_MIN_QUALITY 1e-10
#define SVF_MIN_GAIN 1e-10

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
		default:
			m0 = 0.0; m1 = 0.0; m2 = 1.0;
			break;
	}

	s->m0 = m0;
	s->m1 = m1;
	s->m2 = m2;
	s->a1 = 1.0 / (1.0 + g * (g + k));
	s->a2 = g * s->a1;
	s->a3 = g * s->a2;
}

// One sample +x+ through the filter with integrator states *ic1 and *ic2.
static inline double mb_svf_step(const struct mb_svf *s, double x, double *ic1p, double *ic2p)
{
	double ic1 = *ic1p, ic2 = *ic2p;
	double v3 = x - ic2;
	double v1 = s->a1 * ic1 + s->a2 * v3;
	double v2 = ic2 + s->a2 * ic1 + s->a3 * v3;
	*ic1p = 2.0 * v1 - ic1;
	*ic2p = 2.0 * v2 - ic2;
	return s->m0 * x + s->m1 * v1 + s->m2 * v2;
}

#endif
