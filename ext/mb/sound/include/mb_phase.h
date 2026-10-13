/*
 * The running phase of oscillators whose frequency is a signal (shared by
 * fast_sound, fast_synth, fast_wavetable, and fast_plan).
 *
 * A tone with a frequency signal advances its phase one sample at a time,
 * wrapping it to 0...1 every sample (mb_wrap_phase), so its output is the
 * same whatever the block sizes (fixes-6, 2026-10-13: before, each block
 * summed its increments from its start, phi + sum(inc), which rounded
 * differently by block size, -138 to -145 dB).  Constant frequencies keep
 * phi + inc * i, which is already the same at any block size.
 *
 * Ruby mirror: Tone.wrap_phase.
 */
#ifndef MB_PHASE_H
#define MB_PHASE_H

#include <math.h>

// Wraps +x+ (cycles) to 0...1 like Ruby's %, but never returns 1.0 (x - floor(x)
// rounds up to 1.0 for tiny negative x), so wrapping a wrapped phase gives it
// back unchanged and a phase stored between blocks continues exactly.
// Non-finite phases (a NaN or infinite frequency) give 0.
//
// The phase is on the running phase's dependency chain, so the usual cases
// (a step of less than a cycle) skip floor(); x - 1.0 and x + 1.0 are what
// x - floor(x) computes there, so the result is the same.
static inline double mb_wrap_phase(double x)
{
	double r;
	if (x >= 0.0 && x < 1.0) {
		return x;
	} else if (x >= 1.0 && x < 2.0) {
		r = x - 1.0;
	} else if (x < 0.0 && x >= -1.0) {
		r = x + 1.0;
	} else {
		r = x - floor(x);
	}
	return r < 1.0 ? r : 0.0;
}

#endif /* MB_PHASE_H */
