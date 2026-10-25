/*
 * The struck resonator kernels of MB::Sound::FastResonator.ping and .modes
 * (see fast_resonator.c for the arguments and GraphNode::Resonator /
 * GraphNode::ModalResonator for the sound), shared with the plan layer
 * executor (fast_plan's OP_RESONATOR, plan_resonator.c) so a planned
 * resonator runs exactly the same arithmetic.  The Ruby mirrors are
 * GraphNode::Resonator.process_ruby and GraphNode::ModalResonator.process_ruby.
 *
 * fast_resonator is built with -ffp-contract=off and fast_plan isn't, so the
 * kernels turn contraction off for clang by pragma; GCC with -std=c99 (both
 * extensions) doesn't contract.
 */
#ifndef MB_RESONATOR_H
#define MB_RESONATOR_H

#include <math.h>
#include <stddef.h>

#include "mb_ext_helpers.h"

#if defined(__clang__)
#define MB_RESONATOR_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define MB_RESONATOR_NO_CONTRACT
#endif

// ln(1000): the decay factor reaches -60 dB after +decay+ samples.
#define MB_RES_LN_1000 6.907755278982137

// States smaller than this (in both parts) are flushed to zero so the
// ringing ends instead of running into subnormal numbers.
#define MB_RES_FLUSH 1e-30

// The most modes a modal bank may have (coefficients live on the stack).
#define MB_RES_MODES_MAX 128

// Values per mode in the mode table: ratio, offset (Hz), amplitude, decay
// share.
#define MB_RES_MODE_FIELDS 4

// Modes at or above this share of the sample rate are silent (they would
// fold back below Nyquist), as are modes at or below 0 Hz.
#define MB_RES_MODE_CEILING 0.45

// One ping resonator (FastResonator.ping): +n+ samples into +y+ from the
// input +xs+, frequency +fs_hz+ (Hz), and decay +ds+ (samples to -60 dB),
// on the state z = [zr, zi], at sample rate +rate+, output phase (cp, sp).
static inline void mb_res_ping(float *y, const struct mb_signal *xs, const struct mb_signal *fs_hz, const struct mb_signal *ds,
		double *z, double rate, double cp, double sp, size_t n)
{
	MB_RESONATOR_NO_CONTRACT
	double zr = z[0];
	double zi = z[1];

	// Coefficients are recomputed only when the frequency or decay changes
	// (NAN never compares equal, so the first sample computes them).
	double last_f = NAN, last_d = NAN;
	double c = 0, s = 0;

	for (size_t i = 0; i < n; i++) {
		double x = mb_signal_at(xs, i);
		double f = mb_signal_at(fs_hz, i);
		double d = mb_signal_at(ds, i);

		if (f != last_f || d != last_d) {
			double w = 2.0 * M_PI * f / rate;
			double r = d > 0 ? exp(-MB_RES_LN_1000 / d) : 0.0;
			c = r * cos(w);
			s = r * sin(w);
			last_f = f;
			last_d = d;
		}

		double nr = c * zr - s * zi + x;
		double ni = s * zr + c * zi;
		if (fabs(nr) < MB_RES_FLUSH && fabs(ni) < MB_RES_FLUSH) {
			nr = 0.0;
			ni = 0.0;
		}
		zr = nr;
		zi = ni;

		y[i] = (float)(zi * cp + zr * sp);
	}

	z[0] = zr;
	z[1] = zi;
}

// A modal bank (FastResonator.modes): +m+ modes (at most MB_RES_MODES_MAX)
// of the flat table +table+ (MB_RES_MODE_FIELDS values per mode), each a
// ping at f * ratio + offset Hz falling 60 dB in d * share samples, summed
// times their amplitudes in double in mode order; +z+ holds 2 values per
// mode.
static inline void mb_res_modes(float *y, const struct mb_signal *xs, const struct mb_signal *fs_hz, const struct mb_signal *ds,
		const double *table, size_t m, double *z, double rate, size_t n)
{
	MB_RESONATOR_NO_CONTRACT
	double coef[2 * MB_RES_MODES_MAX];
	double radius[MB_RES_MODES_MAX];
	double last_f = NAN, last_d = NAN;

	for (size_t i = 0; i < n; i++) {
		double x = mb_signal_at(xs, i);
		double f = mb_signal_at(fs_hz, i);
		double d = mb_signal_at(ds, i);

		// Decay factors only when the decay changes (a gliding pitch
		// recomputes only the rotations)
		_Bool new_d = d != last_d;
		if (new_d) {
			for (size_t k = 0; k < m; k++) {
				double dk = d * table[k * MB_RES_MODE_FIELDS + 3];
				radius[k] = dk > 0 ? exp(-MB_RES_LN_1000 / dk) : 0.0;
			}
			last_d = d;
		}

		if (new_d || f != last_f) {
			for (size_t k = 0; k < m; k++) {
				const double *mode = table + k * MB_RES_MODE_FIELDS;
				double fk = f * mode[0] + mode[1];
				double r = radius[k];
				if (fk > 0 && fk < MB_RES_MODE_CEILING * rate && r > 0) {
					double w = 2.0 * M_PI * fk / rate;
					coef[2 * k] = r * cos(w);
					coef[2 * k + 1] = r * sin(w);
				} else {
					coef[2 * k] = 0.0;
					coef[2 * k + 1] = 0.0;
				}
			}
			last_f = f;
		}

		double sum = 0.0;
		for (size_t k = 0; k < m; k++) {
			double c = coef[2 * k];
			double s = coef[2 * k + 1];
			double zr = z[2 * k];
			double zi = z[2 * k + 1];
			double nr = c * zr - s * zi + x;
			double ni = s * zr + c * zi;
			if (fabs(nr) < MB_RES_FLUSH && fabs(ni) < MB_RES_FLUSH) {
				nr = 0.0;
				ni = 0.0;
			}
			z[2 * k] = nr;
			z[2 * k + 1] = ni;
			sum += table[k * MB_RES_MODE_FIELDS + 2] * ni;
		}

		y[i] = (float)sum;
	}
}

#endif
