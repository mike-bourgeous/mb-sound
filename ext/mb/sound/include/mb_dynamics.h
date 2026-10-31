/*
 * The compander kernel of MB::Sound::FastDynamics.compand (compressors,
 * expanders, gates, ducking, companders; see fast_dynamics.c for the
 * arguments and design/notes/dynamics.md for the algorithm), shared with
 * the plan layer executor (fast_plan's OP_DYNAMICS, plan_dynamics.c) so a
 * planned compressor runs exactly the same arithmetic.  The Ruby mirror is
 * MB::Sound::GraphNode::Dynamics.process_ruby.
 *
 * fast_dynamics is built with -ffp-contract=off and fast_plan isn't, so the
 * kernel turns contraction off for clang by pragma; GCC with -std=c99 (both
 * extensions) doesn't contract.
 */
#ifndef MB_DYNAMICS_H
#define MB_DYNAMICS_H

#include <math.h>

#include "mb_ext_helpers.h"

#if defined(__clang__)
#define MB_DYN_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define MB_DYN_NO_CONTRACT
#endif

// Detector levels below these read as DYN_FLOOR_DB.
#define DYN_FLOOR_DB -200.0
#define DYN_FLOOR_LIN 1e-10
#define DYN_FLOOR_SQ 1e-20

// Smoothed gains this close to their target land on it.
#define DYN_SNAP 1e-12

// Per-detector state entries for compand (mean square, smoothed gain dB,
// hold counter).
#define DYN_DET_STATE 3

// Compand settings (see ruby_compand).
enum dyn_param {
	DP_MODE, // 0 peak, 1 RMS
	DP_MIN_GAIN, // dB
	DP_MAX_GAIN, // dB
	DP_MAKEUP, // dB
	DP_HOLD_UP, // 1: hold delays rising gain (compressors), 0: falling (gates)
	DP_LINK, // 1: one detector for every channel
	DP_LOOKAHEAD, // whole samples of audio delay
	DP_AUTO_MAKEUP, // 1: the makeup follows DT_SHIFT and DT_SCALE (half the gain change at 0 dBFS back), 0: DP_MAKEUP
	DP_COUNT
};

// Compand signal inputs (see ruby_compand): times in samples, then the
// live controls (delays-2, 2026-10-31), read every sample.  A curve built
// for one threshold and ratio moves with them: the gain at detector level
// L is (curve(L - shift) - (L - shift)) * scale, so shift 0 and scale 1
// (numbers) give the curve's own gains exactly.
enum dyn_time {
	DT_RMS,
	DT_DOWN,
	DT_UP,
	DT_BOOST, // fall time while the gain is above 0 dB (an upward boost)
	DT_HOLD,
	DT_SHIFT, // dB the curve moves up (a threshold change)
	DT_SCALE, // factor on the curve's gain change (a ratio change)
	DT_MIX, // parallel mix, clamped to 0..1: gain = mix * gain + (1 - mix)
	DT_COUNT
};

// The exp(-1 / t) one-pole coefficient for a time constant of +t+ samples
// (0 for instant).
static inline double mb_dyn_coef(double t)
{
	return t > 0 ? exp(-1.0 / t) : 0.0;
}

// Evaluates the transfer curve (+nseg+ rows of [x0, y0, b, c, d]) at +x+:
// the last segment whose x0 <= x (the first for x below every x0).
static inline double mb_dyn_curve(const double *seg, long nseg, double x)
{
	MB_DYN_NO_CONTRACT
	long lo = 0;
	long hi = nseg - 1;
	while (lo < hi) {
		long mid = (lo + hi + 1) / 2;
		if (seg[mid * 5] <= x) {
			lo = mid;
		} else {
			hi = mid - 1;
		}
	}
	const double *s = seg + lo * 5;
	double dx = x - s[0];
	return s[1] + dx * (s[2] + dx * (s[3] + dx * s[4]));
}

/*
 * Runs the compander for +n+ samples: +nch+ outputs +out+ (float), inputs
 * +in+ (one per channel), +nside+ detector signals +side+ (linked: any
 * number feeding one detector; else one per channel), DT_COUNT times +tim+
 * in samples, DP_COUNT settings +par+, +nseg+ curve segments +seg+, the
 * state +st+ (DYN_DET_STATE per detector, then the delay position), and
 * the lookahead delay +dl+ (nch * lookahead samples, or NULL without
 * lookahead).  The caller checks the sizes.
 */
static inline void mb_dyn_compand(float *const *out, long nch, const struct mb_signal *in, const struct mb_signal *side, long nside,
		const struct mb_signal *tim, const double *par, const double *seg, long nseg, double *st, double *dl, long n)
{
	MB_DYN_NO_CONTRACT
	int rms = par[DP_MODE] != 0;
	double min_gain = par[DP_MIN_GAIN];
	double max_gain = par[DP_MAX_GAIN];
	double makeup = par[DP_MAKEUP];
	int hold_up = par[DP_HOLD_UP] != 0;
	int link = par[DP_LINK] != 0;
	long la = (long)par[DP_LOOKAHEAD];
	int auto_makeup = par[DP_AUTO_MAKEUP] != 0;
	long ndet = link ? 1 : nch;
	double gain[ndet];

	long pos = (long)st[ndet * DYN_DET_STATE];
	if (la > 0 && (pos < 0 || pos >= la)) {
		pos = 0;
	}

	// Coefficients and gains are recomputed only when their inputs change
	// (NAN never compares equal, so the first sample computes them).
	double last_t[DT_COUNT] = { NAN, NAN, NAN, NAN, NAN };
	double coef[DT_COUNT] = { 0, 0, 0, 0, 0 };
	double last_gdb = NAN;
	double last_mix = NAN;
	double last_glin = 1.0;
	double last_shift = NAN;
	double last_scale = NAN;

	for (long i = 0; i < n; i++) {
		for (long t = 0; t < DT_HOLD; t++) {
			double v = mb_signal_at(&tim[t], i);
			if (v != last_t[t]) {
				last_t[t] = v;
				coef[t] = mb_dyn_coef(v);
			}
		}
		double hold = mb_signal_at(&tim[DT_HOLD], i);
		double shift = mb_signal_at(&tim[DT_SHIFT], i);
		double scale = mb_signal_at(&tim[DT_SCALE], i);
		double mix = mb_signal_at(&tim[DT_MIX], i);
		if (!(mix >= 0.0)) {
			mix = 0.0;
		} else if (mix > 1.0) {
			mix = 1.0;
		}
		if (auto_makeup && (shift != last_shift || scale != last_scale)) {
			// Half the gain change at 0 dBFS back, as
			// DynamicsMethods#dyn_makeup computes it for numbers
			double g0 = (mb_dyn_curve(seg, nseg, -shift) + shift) * scale;
			if (g0 < min_gain) {
				g0 = min_gain;
			}
			if (g0 > max_gain) {
				g0 = max_gain;
			}
			makeup = -0.5 * g0;
		}
		last_shift = shift;
		last_scale = scale;

		for (long d = 0; d < ndet; d++) {
			double *ds = st + d * DYN_DET_STATE;

			double m = 0.0;
			long first = link ? 0 : d;
			long last = link ? nside : d + 1;
			for (long c = first; c < last; c++) {
				double v = mb_signal_at(&side[c], i);
				v = rms ? v * v : fabs(v);
				if (v > m) {
					m = v;
				}
			}

			double level;
			if (rms) {
				ds[0] = ds[0] * coef[DT_RMS] + (1.0 - coef[DT_RMS]) * m;
				level = ds[0] > DYN_FLOOR_SQ ? 10.0 * log10(ds[0]) : DYN_FLOOR_DB;
			} else {
				level = m > DYN_FLOOR_LIN ? 20.0 * log10(m) : DYN_FLOOR_DB;
			}

			double x = level - shift;
			double g = (mb_dyn_curve(seg, nseg, x) - x) * scale;
			if (g < min_gain) {
				g = min_gain;
			}
			if (g > max_gain) {
				g = max_gain;
			}

			// The held direction (rising for compressors, falling for
			// gates) waits for the hold counter, which restarts while
			// the gain is steady or moving the other way.
			double gs = ds[1];
			int held = hold_up ? g > gs : g < gs;
			if (held && ds[2] > 0) {
				ds[2] -= 1.0;
			} else {
				if (g < gs && gs > 0) {
					// A boost (gain above 0 dB) falls at its own speed
					gs = g + (gs - g) * coef[DT_BOOST];
				} else if (g != gs) {
					gs = g + (gs - g) * (g < gs ? coef[DT_DOWN] : coef[DT_UP]);
				}
				if (!held) {
					ds[2] = hold;
				}
			}
			if (fabs(gs - g) < DYN_SNAP) {
				gs = g;
			}
			ds[1] = gs;

			double gdb = gs + makeup;
			if (gdb != last_gdb || mix != last_mix) {
				last_gdb = gdb;
				last_mix = mix;
				last_glin = mix * pow(10.0, gdb / 20.0) + (1.0 - mix);
			}
			gain[d] = last_glin;
		}

		for (long c = 0; c < nch; c++) {
			double x = mb_signal_at(&in[c], i);
			if (la > 0) {
				double *slot = dl + c * la + pos;
				double y = *slot;
				*slot = x;
				x = y;
			}
			out[c][i] = (float)(x * gain[link ? 0 : c]);
		}
		if (la > 0) {
			pos = pos + 1 == la ? 0 : pos + 1;
		}
	}

	st[ndet * DYN_DET_STATE] = (double)pos;
}

#endif
