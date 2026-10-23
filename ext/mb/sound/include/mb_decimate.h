/*
 * The decimator kernel of MB::Sound::FastLofi.decimate (see fast_lofi.c for
 * the arguments and GraphNode::Decimator for the sound), shared with the
 * plan layer executor (fast_plan's OP_DECIMATE, plan_lofi.c) so a planned
 * decimator runs exactly the same arithmetic.  The Ruby mirror is
 * MB::Sound::GraphNode::Decimator.process_ruby.
 *
 * fast_lofi is built with -ffp-contract=off and fast_plan isn't, so the
 * kernel turns contraction off for clang by pragma; GCC with -std=c99 (both
 * extensions) doesn't contract.
 */
#ifndef MB_DECIMATE_H
#define MB_DECIMATE_H

#include <stdint.h>
#include <stddef.h>

#include "mb_ext_helpers.h"

#if defined(__clang__)
#define MB_DECIMATE_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define MB_DECIMATE_NO_CONTRACT
#endif

// The length of a decimator's state: [phase, held value, period factor,
// previous held value].
#define MB_DECIMATE_STATE_LENGTH 4

// Phases this close below a whole cycle count as reaching it, so rates that
// divide the sample rate hold exactly every N samples despite rounding.
#define MB_DECIMATE_EDGE 1e-9

// The next uniform random number in 0...1 from the splitmix64 state *s (53
// bits; the same generator as noise_random in mb_osc_shapes.h, mirrored by
// MB::Sound::Tone.noise_random).
static inline double mb_decimate_random(uint64_t *s)
{
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	z ^= z >> 31;
	return (double)(z >> 11) * 0x1.0p-53;
}

// Decimates +length+ samples of the input +xs+ into +op+ at the hold rate
// +rs+ (Hz) for sample rate +fs+, on the state +st+ (MB_DECIMATE_STATE_LENGTH
// doubles) and random state *rp, with +jitter+ (0..0.95) and +mode+ (0
// hold, 1 linear).  See fast_lofi.c.
static inline void mb_decimate(float *op, const struct mb_signal *xs, const struct mb_signal *rs, double *st, uint64_t *rp,
		double fs, double jitter, int mode, size_t length)
{
	MB_DECIMATE_NO_CONTRACT
	double phase = st[0];
	float held = (float)st[1];
	double factor = st[2];
	float prev = (float)st[3];

	for (size_t i = 0; i < length; i++) {
		if (phase >= 1.0 - MB_DECIMATE_EDGE) {
			phase -= mb_floor(phase + MB_DECIMATE_EDGE);
			prev = held;
			held = (float)mb_signal_at(xs, i);
			if (jitter > 0) {
				double u = mb_decimate_random(rp);
				double spread = jitter * (2.0 * u - 1.0);
				factor = 1.0 + spread;
			}
		}
		if (mode == 1) {
			double t = phase < 1.0 ? phase : 1.0;
			op[i] = (float)((double)prev + ((double)held - (double)prev) * t);
		} else {
			op[i] = held;
		}

		double inc = mb_signal_at(rs, i) / fs;
		if (!(inc > 0)) {
			inc = 0;
		} else if (inc > 1.0) {
			inc = 1.0;
		}
		phase += inc * factor;
	}

	st[0] = phase;
	st[1] = held;
	st[2] = factor;
	st[3] = prev;
}

#endif
