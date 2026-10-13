/*
 * The running phase of oscillators whose frequency is a signal (shared by
 * fast_sound, fast_synth, fast_wavetable, and fast_plan).
 *
 * A tone with a frequency signal advances its phase one sample at a time,
 * wrapping it to 0...1 every sample (mb_wrap_phase), so its output is the
 * same whatever the block sizes (fixes-6, 2026-10-13: before, each block
 * summed its increments from its start, phi + sum(inc), which rounded
 * differently by block size, -138 to -145 dB).
 *
 * A tone with a constant frequency computes each sample's phase as
 * base + inc * k, from the phase +base+ at the last point of a grid of
 * MB_PHASE_GRID samples of the tone's own time (k samples ago), and moves
 * +base+ on at each grid point (struct mb_grid_phase; fixes-7, 2026-10-13:
 * before, base was the phase at the start of each block, so the phases
 * rounded differently by block size: up to a phasor's wrap a sample apart
 * at 367/368 vs 800, a persona take's loop strikes -130 dB).  For a run of
 * 800-sample blocks starting with the tone this is what it computed
 * before.  Phase state Arrays keep [phase, base, k, inc]; a phase changed
 * from outside (a reset, a jump), another increment, or a state without
 * the grid starts a new grid there.
 *
 * Ruby mirrors: Tone.wrap_phase, Tone::GridPhase.
 */
#ifndef MB_PHASE_H
#define MB_PHASE_H

#include <math.h>
#include <ruby.h>
#include "mb_ext_helpers.h"

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

// The grid of constant-frequency phases (see the top of this file).
#define MB_PHASE_GRID 800

// A constant-frequency phase: the phase at the last grid point, the
// samples since it, and the increment per sample.
struct mb_grid_phase {
	double base;
	double k;
	double inc;
};

// Reads the grid from entries 1..3 of phase state Array +state+ (NAN if
// there aren't any).
static inline void mb_grid_phase_read(VALUE state, struct mb_grid_phase *g)
{
	if (RB_TYPE_P(state, T_ARRAY) && RARRAY_LEN(state) >= 4) {
		VALUE b = rb_ary_entry(state, 1), k = rb_ary_entry(state, 2), inc = rb_ary_entry(state, 3);
		if (RB_FLOAT_TYPE_P(b) && RB_FLOAT_TYPE_P(k) && RB_FLOAT_TYPE_P(inc)) {
			g->base = RFLOAT_VALUE(b);
			g->k = RFLOAT_VALUE(k);
			g->inc = RFLOAT_VALUE(inc);
			return;
		}
	}
	g->base = g->k = g->inc = NAN;
}

// Stores the grid into entries 1..3 of phase state Array +state+.
static inline void mb_grid_phase_write(VALUE state, const struct mb_grid_phase *g)
{
	rb_ary_store(state, 1, rb_float_new(g->base));
	rb_ary_store(state, 2, rb_float_new(g->k));
	rb_ary_store(state, 3, rb_float_new(g->inc));
}

// Continues the grid if it leads to phase +phi+ (stored by the last block)
// with increment +inc+, else starts a new one at +phi+.
static inline void mb_grid_phase_start(struct mb_grid_phase *g, double phi, double inc)
{
	if (!(g->inc == inc && g->k >= 0 && g->k < MB_PHASE_GRID && mb_wrap(g->base + inc * g->k, 1.0) == phi)) {
		g->base = phi;
		g->k = 0;
		g->inc = inc;
	}
}

// The phase now (cycles, wrapped).
static inline double mb_grid_phase_now(const struct mb_grid_phase *g)
{
	return mb_wrap(g->base + g->inc * g->k, 1.0);
}

// Moves to the next sample.
static inline void mb_grid_phase_next(struct mb_grid_phase *g)
{
	g->k += 1.0;
	if (g->k >= MB_PHASE_GRID) {
		g->base = mb_wrap(g->base + g->inc * MB_PHASE_GRID, 1.0);
		g->k = 0;
	}
}

#endif /* MB_PHASE_H */
