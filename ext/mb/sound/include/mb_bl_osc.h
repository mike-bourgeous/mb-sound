/*
 * PolyBLEP/PolyBLAMP band-limited oscillator helpers and the
 * FastSynth.oscillate_bl loop (mb_bl_oscillate), shared by fast_synth.c and
 * the plan executor (fast_plan.c) so both run the same code.  Moved here
 * from fast_synth.c (2026-10-08, plan layer); see fast_synth.c's top
 * comment for how the corrections work.  Everything is static inline.
 */
#ifndef MB_BL_OSC_H
#define MB_BL_OSC_H

#include <math.h>
#include "mb_ext_helpers.h"

#define BL_MAX_BREAKPOINTS 4
#define BL_EPS 1e-9
#define BL_MIN_WIDTH 1e-4

struct bl_breakpoint {
	double pos; // phase in cycles (0..1)
	double dv;  // value after minus value before (moving forward)
	double ds;  // slope after minus slope before, per cycle
	double vr;  // value just after (at the breakpoint itself)
};

enum bl_wave {
	BL_NONE,
	BL_RAMP,
	BL_SQUARE,
	BL_TRIANGLE,
	BL_SINE,
	BL_PARABOLA,
};

// The average value of each shape's first half (the second half's is the
// negative), so a warped shape's DC offset is this times (2w - 1).
static inline double bl_half_mean(enum bl_wave wt)
{
	switch (wt) {
		case BL_SQUARE: return 1.0;
		case BL_RAMP: return 0.5;
		case BL_TRIANGLE: return 0.5;
		case BL_SINE: return 2.0 / M_PI;
		case BL_PARABOLA: return 2.0 / 3.0;
		default: return 0.0;
	}
}
// The naive waveform at phase +u+ (cycles, 0..1); same shapes as
// osc_sample.  At a breakpoint this is the value after it (approaching from
// above); with +left+ it is the value before it (approaching from below,
// with u = 1 for the end of the cycle).
static inline __attribute__((always_inline)) double bl_shape(enum bl_wave wt, double u, _Bool left)
{
	switch (wt) {
		case BL_RAMP:
			return (left ? u <= 0.5 : u < 0.5) ? 2.0 * u : 2.0 * u - 2.0;

		case BL_SQUARE:
			return (left ? u <= 0.5 : u < 0.5) ? 1.0 : -1.0;

		case BL_TRIANGLE:
			if (left ? u <= 0.25 : u < 0.25) {
				return 4.0 * u;
			} else if (left ? u <= 0.75 : u < 0.75) {
				return 2.0 - 4.0 * u;
			}
			return 4.0 * u - 4.0;

		case BL_SINE:
			return sin(u * (2.0 * M_PI));

		case BL_PARABOLA:
			if (left ? u <= 0.5 : u < 0.5) {
				double x = 1.0 - 4.0 * u;
				return 1.0 - x * x;
			} else {
				double x = 4.0 * u - 3.0;
				return x * x - 1.0;
			}

		default:
			return 0.0;
	}
}

// The slope of the naive waveform at +u+ per cycle (after a breakpoint, or
// before it with +left+, as in bl_shape).
static inline double bl_slope(enum bl_wave wt, double u, _Bool left)
{
	switch (wt) {
		case BL_RAMP:
			return 2.0;

		case BL_SQUARE:
			return 0.0;

		case BL_TRIANGLE:
			if (left ? u <= 0.25 : u < 0.25) {
				return 4.0;
			} else if (left ? u <= 0.75 : u < 0.75) {
				return -4.0;
			}
			return 4.0;

		case BL_SINE:
			return (2.0 * M_PI) * cos(u * (2.0 * M_PI));

		case BL_PARABOLA:
			if (left ? u <= 0.5 : u < 0.5) {
				return 8.0 * (1.0 - 4.0 * u);
			}
			return 8.0 * (4.0 * u - 3.0);

		default:
			return 0.0;
	}
}

// The phases (cycles) of the shape's own breakpoints, then the wrap and
// the middle (where the warp bends), returning how many there are.
static inline int bl_candidates(enum bl_wave wt, double *u)
{
	int n = 0;

	switch (wt) {
		case BL_RAMP:
			u[n++] = 0.5;
			break;

		case BL_SQUARE:
			u[n++] = 0.0;
			u[n++] = 0.5;
			break;

		case BL_TRIANGLE:
			u[n++] = 0.25;
			u[n++] = 0.75;
			break;

		default:
			break;
	}

	_Bool has0 = 0, has_half = 0;
	for (int j = 0; j < n; j++) {
		has0 |= u[j] == 0.0;
		has_half |= u[j] == 0.5;
	}
	if (!has0) u[n++] = 0.0;
	if (!has_half) u[n++] = 0.5;

	return n;
}

// Maps phase +p+ (cycles) through the warp with width +w+ (knee at w;
// identity at 0.5).
static inline double bl_warp(double p, double w)
{
	return p < w ? p * (0.5 / w) : 0.5 + (p - w) * (0.5 / (1.0 - w));
}

// Fills +bp+ with the breakpoints of +wt+ warped by width +w+ (positions in
// phase; jumps in value and in slope per cycle of phase), returning how
// many there are.  Points with no jump are left out unless +all+ (the sync
// kernel's delayed segments can jump where the shape's formula changes).
static inline int bl_breakpoints(enum bl_wave wt, double w, struct bl_breakpoint *bp, _Bool all)
{
	double cand[BL_MAX_BREAKPOINTS];
	int nc = bl_candidates(wt, cand);
	double k1 = 0.5 / w, k2 = 0.5 / (1.0 - w);
	int n = 0;

	for (int j = 0; j < nc; j++) {
		double ub = cand[j];
		double ul = ub == 0.0 ? 1.0 : ub; // approaching from below

		double kr = ub < 0.5 ? k1 : k2;
		double kl = ul <= 0.5 ? k1 : k2;

		double vr = bl_shape(wt, ub, 0);
		double dv = vr - bl_shape(wt, ul, 1);
		double ds = bl_slope(wt, ub, 0) * kr - bl_slope(wt, ul, 1) * kl;

		if (dv == 0 && ds == 0 && !all) {
			continue;
		}

		double pos = ub < 0.5 ? ub * (2.0 * w) : w + (ub - 0.5) * (2.0 * (1.0 - w));
		bp[n++] = (struct bl_breakpoint){ pos, dv, ds, vr };
	}

	return n;
}

// If moving from phase +e+ by +d+ cycles (|d| < 1, either direction) crosses
// phase +b+, returns the crossing time as a fraction of the step in (0, 1]
// (a crossing exactly at +e+ belongs to the previous step); otherwise -1.
static inline __attribute__((always_inline)) double bl_crossing(double e, double d, double b)
{
	double dist;

	// Both phases are in 0..1, so wrapping their difference is one add
	// (the same result as mb_wrap())
	if (d > 0) {
		dist = b - e;
	} else if (d < 0) {
		dist = e - b;
	} else {
		return -1;
	}
	if (dist < 0) {
		dist += 1.0;
	}

	if (dist == 0) {
		dist = 1.0;
	}

	// Edges within BL_EPS past the end of the step land on its last sample
	// (see bl_snap), so rounding can't skip an edge that falls exactly on a
	// sample (e.g. 1 kHz at 48 kHz)
	double ad = fabs(d);
	if (ad >= 1.0 || dist > ad + BL_EPS) {
		return -1;
	}

	return dist >= ad ? 1.0 : dist / ad;
}

// Like bl_crossing, but a phase on a breakpoint is always on its right
// side (the value after it going forward, as bl_snap gives it), whichever
// way the phase moves, so the phase can reverse on an edge (soft sync,
// through-zero FM, negative frequencies): a backward step starting exactly
// on +b+ crosses it at once (0), and one ending within BL_EPS of +b+ (where
// the phase snaps onto it) doesn't cross it.  Forward steps are as in
// bl_crossing.  (bl_crossing alone counted a backward step ending on an
// edge as crossing it while the snapped sample stayed on the right side,
// and the next step, starting on the edge, never crossed it: an error of
// the whole jump at every edge landing exactly on a sample.)
static inline double bl_side_crossing(double e, double d, double b)
{
	if (d >= 0) {
		return bl_crossing(e, d, b);
	}

	double dist = e - b;
	if (dist < 0) {
		dist += 1.0;
	}
	if (dist == 0) {
		return 0;
	}

	double ad = -d;
	if (ad >= 1.0 || dist >= ad - BL_EPS) {
		return -1;
	}

	return dist / ad;
}

// Returns the index of a breakpoint within BL_EPS of phase +e+, or -1.  A
// sample there is treated as exactly on the edge, taking the value after it,
// matching bl_crossing.
static inline int bl_snap(struct bl_breakpoint *bp, int count, double e)
{
	for (int j = 0; j < count; j++) {
		double diff = fabs(e - bp[j].pos);
		if (diff < BL_EPS || diff > 1.0 - BL_EPS) {
			return j;
		}
	}

	return -1;
}

// Clamps a pulse width to BL_MIN_WIDTH..(1 - BL_MIN_WIDTH).
static inline double bl_clamp_width(double w)
{
	if (!(w >= BL_MIN_WIDTH)) return BL_MIN_WIDTH; // also NaN
	if (w > 1.0 - BL_MIN_WIDTH) return 1.0 - BL_MIN_WIDTH;
	return w;
}

// The fraction of the correction to apply at +freq+ Hz: 1 if +lo+ and +hi+
// are both zero, otherwise a smoothstep from 0 at +lo+ Hz to 1 at +hi+ Hz
// (Tone#lfo uses this so slow LFOs keep their exact edges).
static inline double bl_fade(double freq, double lo, double hi)
{
	if (lo <= 0 && hi <= 0) {
		return 1.0;
	}
	if (freq <= lo) {
		return 0.0;
	}
	if (freq >= hi) {
		return 1.0;
	}

	double t = (freq - lo) / (hi - lo);
	return t * t * (3.0 - 2.0 * t);
}

// Finds the edges crossed while moving from phase +e+ by +d+ cycles, and
// returns the correction for the sample at the start of that step (the edge
// is after it).  The correction for the sample at the end of the step (the
// edge is before it) is stored in *after_corr, so each step is examined
// once.
static inline double bl_step(struct bl_breakpoint *bp, int count, double e, double d, double adv, double lo, double hi, double *after_corr)
{
	double before = 0, after = 0;
	double k = -1;

	*after_corr = 0;
	for (int j = 0; j < count; j++) {
		double f = bl_side_crossing(e, d, bp[j].pos);
		if (f < 0) {
			continue;
		}

		if (k < 0) {
			k = bl_fade(fabs(d) / adv, lo, hi);
			if (k == 0) {
				return 0;
			}
		}

		// Jumps as seen in time: moving backward reverses the value jump; the
		// slope change per sample is the change per cycle times |d|.
		double dv = d > 0 ? bp[j].dv : -bp[j].dv;
		double ds = bp[j].ds * fabs(d);

		// x: distance in samples from the edge to the sample being corrected
		double xa = f;
		double xb = 1.0 - f;
		after += k * (dv * (-0.5 * xa * xa) + ds * (xa * xa * xa / 6.0));
		before += k * (dv * (0.5 * xb * xb) + ds * (xb * xb * xb / 6.0));
	}

	*after_corr = after;
	return before;
}

// The state of a band-limited oscillator between buffers (see
// mb_bl_oscillate): the phase (cycles) and the bl_state Array's values.
struct mb_bl_state {
	double phi;
	double prev_e, prev_inc, prev_pm;
	int primed; // 1 primed, 0 a tone's first sample, 2 just after a jump
};

/*
 * The band-limited oscillator loop of FastSynth.oscillate_bl (see
 * ruby_oscillate_bl in fast_synth.c for the parameters), on +length+
 * samples of +out+, with signal inputs +freqsig+, +pmsig+, and +wsig+
 * (width; a scalar of 0.5 for none), updating *st.  Shared with the plan
 * executor (fast_plan.c), so both run the same code.
 */
static inline void mb_bl_oscillate(enum bl_wave wt, float *out, size_t length,
		const struct mb_signal *freqsig, const struct mb_signal *pmsig, const struct mb_signal *wsig,
		double adv, double g, double off, double lo, double hi, _Bool dc, struct mb_bl_state *st)
{
	double phi = st->phi;
	double prev_e = st->prev_e;
	double prev_inc = st->prev_inc;
	double prev_pm = st->prev_pm;
	int primed_v = st->primed;
	_Bool primed = primed_v == 1;
	_Bool fresh = primed_v == 0; // a tone's first sample (2: just after a phase jump)

	double freq = freqsig->scalar;
	const float *freqptr = freqsig->ptr;
	size_t freqstep = freqsig->step;

	double pm = pmsig->scalar;
	const float *pmptr = pmsig->ptr;
	size_t pmstep = pmsig->step;

	double w = wsig->scalar;
	const float *wptr = wsig->ptr;
	size_t wstep = wsig->step;
	w = bl_clamp_width(w);

	double half_mean = bl_half_mean(wt);

	struct bl_breakpoint bp[BL_MAX_BREAKPOINTS];
	int nbp = bl_breakpoints(wt, w, bp, 0);

	// Warp factors, recomputed when the width changes (the same values as
	// bl_warp; at width 0.5 the warp is skipped, which is exact)
	double k1 = 0.5 / w, k2 = 0.5 / (1.0 - w);

	_Bool constant = !freqptr;
	double steps = 0;
	double e = 0, inc = 0;
	double pending = 0, pending_d = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = freqptr[i * freqstep];
		}
		if (pmptr) {
			pm = pmptr[i * pmstep];
		}
		if (wptr) {
			double new_w = bl_clamp_width(wptr[i * wstep]);
			if (new_w != w) {
				w = new_w;
				nbp = bl_breakpoints(wt, w, bp, 0);
				k1 = 0.5 / w;
				k2 = 0.5 / (1.0 - w);
			}
		}

		inc = freq * adv;
		if (constant) {
			steps = inc * i;
		}

		e = mb_wrap(phi + steps, 1.0);
		if (pm != 0) {
			e = mb_wrap(e + pm, 1.0);
		}
		double v;
		int snapped = bl_snap(bp, nbp, e);
		if (snapped >= 0) {
			e = bp[snapped].pos;
			v = bp[snapped].vr;
		} else {
			v = bl_shape(wt, w == 0.5 ? e : (e < w ? e * k1 : 0.5 + (e - w) * k2), 0);
		}

		// Edges between the previous sample and this one: usually found
		// while correcting the previous sample, unless its next phase
		// modulation was extrapolated (between buffers, only if the phase
		// continued without a jump)
		double d_back = prev_inc + (pm - prev_pm);
		if (i > 0 && d_back == pending_d) {
			v += pending;
		} else if (primed && (i > 0 || fabs(mb_wrap(prev_e + d_back - e + 0.5, 1.0) - 0.5) < 1e-6)) {
			double after;
			bl_step(bp, nbp, prev_e, d_back, adv, lo, hi, &after);
			v += after;
		} else if (fresh && i == 0) {
			// A tone's first sample, corrected as if it had always run at
			// this frequency (a square starting on its edge at phase 0
			// plays the edge's midpoint, 0, not +1)
			double after;
			bl_step(bp, nbp, mb_wrap(e - inc, 1.0), inc, adv, lo, hi, &after);
			v += after;
		}

		// Edges between this sample and the next (phase modulation for the
		// last sample is extrapolated)
		double next_pm;
		if (i + 1 < length) {
			next_pm = pmptr ? pmptr[(i + 1) * pmstep] : pm;
		} else {
			next_pm = pm + (pm - (i > 0 || primed ? prev_pm : pm));
		}
		double d_fwd = inc + (next_pm - pm);
		v += bl_step(bp, nbp, e, d_fwd, adv, lo, hi, &pending);
		pending_d = d_fwd;

		if (dc) {
			v -= half_mean * (2.0 * w - 1.0);
		}

		out[i] = v * g + off;

		prev_e = e;
		prev_inc = inc;
		prev_pm = pm;
		primed = 1;

		if (!constant) {
			steps += inc;
		}
	}

	if (constant) {
		steps = freq * adv * length;
	}
	st->phi = mb_wrap(phi + steps, 1.0);

	if (length > 0) {
		st->prev_e = prev_e;
		st->prev_inc = prev_inc;
		st->prev_pm = prev_pm;
		st->primed = 1;
	}
}

#endif
