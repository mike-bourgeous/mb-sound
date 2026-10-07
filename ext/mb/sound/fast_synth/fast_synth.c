/*
 * MB::Sound::FastSynth: synthesis kernels.  First, band-limited oscillators
 * (PolyBLEP / PolyBLAMP).
 *
 * A naive waveform with jumps (ramp, square) or corners (triangle) aliases,
 * because those edges contain harmonics far above Nyquist.  The band-limited
 * waveform equals the naive one plus a short correction around each edge,
 * scaled by the size of the jump in value (a BLEP: band-limited step) or in
 * slope (a BLAMP: band-limited ramp).  The 2-point polynomial versions used
 * here touch only the sample before and the sample after each edge, placed
 * at the edge's exact sub-sample time.
 *
 * Edges are found on the "effective phase" e = phase + phase_mod / 2pi (in
 * cycles), moving by d = increment + change in phase_mod / 2pi per sample,
 * so frequency and phase modulation (including backward, through-zero
 * motion) are band-limited too.  The correction for the sample before an
 * edge uses the motion to the next sample, which is known inside a buffer
 * and extrapolated for its last sample.
 *
 * Every shape is defined in cycles (0..1) with a list of breakpoints: the
 * phase of each edge, its jump in value, and its jump in slope (per cycle).
 *
 * Phase warp (pulse width modulation for every shape): with width w, the
 * shape's first half (0..0.5) plays over the first w of each cycle and its
 * second half over the rest, so a square becomes a pulse, a triangle a
 * skewed triangle, and a sine an asymmetric sine (like Casio's phase
 * distortion).  The warp bends the phase at the knee (w) and the wrap, so
 * those become breakpoints too (jumps in slope wherever the shape isn't
 * flat there), and the same corrections band-limit every combination.  At
 * w = 0.5 the warp is the identity, exactly.
 *
 * The Ruby mirror is MB::Sound::BandLimit (lib/mb/sound/band_limit.rb);
 * specs check that both give the same samples.
 */

#include <stdlib.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

#define BL_MAX_BREAKPOINTS 4
#define BL_INV_2PI (1.0 / (2.0 * M_PI))
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

static ID sym_ramp, sym_square, sym_triangle, sym_sine, sym_parabola;

// Returns the band-limited wave type for the Symbol +wave_type+ (raising an
// error if it has no band-limited version).
static enum bl_wave bl_find_wave(VALUE wave_type)
{
	ID id = SYM2ID(wave_type);
	if (id == sym_ramp) return BL_RAMP;
	if (id == sym_square) return BL_SQUARE;
	if (id == sym_triangle) return BL_TRIANGLE;
	if (id == sym_sine) return BL_SINE;
	if (id == sym_parabola) return BL_PARABOLA;
	rb_raise(rb_eArgError, "No band-limited version of %"PRIsVALUE, wave_type);
}

// The average value of each shape's first half (the second half's is the
// negative), so a warped shape's DC offset is this times (2w - 1).
static double bl_half_mean(enum bl_wave wt)
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

// Reads and checks the [phi] state array of a phasor (cycles).
static double bl_read_phi(VALUE state)
{
	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 1) {
		rb_raise(rb_eArgError, "State array must have exactly one numeric element");
	}
	return NUM2DBL(rb_ary_entry(state, 0));
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
static double bl_slope(enum bl_wave wt, double u, _Bool left)
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
static int bl_candidates(enum bl_wave wt, double *u)
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
static int bl_breakpoints(enum bl_wave wt, double w, struct bl_breakpoint *bp, _Bool all)
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
		double f = bl_crossing(e, d, bp[j].pos);
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

/*
 * A band-limited oscillator (like ruby_oscillate, without random advance):
 *   oscillate_bl(buffer, wave_type, frequency, phase_mod, advance, gain,
 *                offset, state, bl_state, fade_lo, fade_hi)
 *
 * +state+ is the phasor's [phi]; +bl_state+ is [last effective phase, last
 * increment, last phase_mod, primed (0 or 1)], carried between buffers so
 * the first sample of a buffer is corrected for an edge just before it.  A
 * jump in phase between buffers (a reset or sync) skips that correction.
 * +fade_lo+ and +fade_hi+ (Hz) fade the corrections in with frequency (see
 * bl_fade; 0 and 0 for always on, infinity for never: a naive waveform).
 * +width+ (Numeric, NArray, or nil for 0.5) warps the phase (see the top of
 * this file), clamped to BL_MIN_WIDTH..(1 - BL_MIN_WIDTH); if +remove_dc+
 * is true, the warped waveform's DC offset is subtracted.  See
 * MB::Sound::BandLimit.
 */
static VALUE ruby_oscillate_bl(VALUE self, VALUE buffer, VALUE wave_type, VALUE frequency, VALUE phase_mod,
		VALUE advance, VALUE gain, VALUE offset, VALUE state, VALUE bl_state, VALUE fade_lo, VALUE fade_hi,
		VALUE width, VALUE remove_dc)
{
	enum bl_wave wt = bl_find_wave(wave_type);

	double phi = bl_read_phi(state);
	double adv = NUM2DBL(advance);
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);
	double lo = NUM2DBL(fade_lo);
	double hi = NUM2DBL(fade_hi);

	Check_Type(bl_state, T_ARRAY);
	if (RARRAY_LEN(bl_state) != 4) {
		rb_raise(rb_eArgError, "Band-limiting state must have four elements");
	}
	double prev_e = NUM2DBL(rb_ary_entry(bl_state, 0));
	double prev_inc = NUM2DBL(rb_ary_entry(bl_state, 1));
	double prev_pm = NUM2DBL(rb_ary_entry(bl_state, 2));
	_Bool primed = NUM2INT(rb_ary_entry(bl_state, 3)) != 0;

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	const float *freqptr;
	size_t freqstep;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqstep);

	double pm;
	const float *pmptr;
	size_t pmstep;
	mb_read_signal_input(&phase_mod, length, "Phase modulation", &pm, &pmptr, &pmstep);

	double w;
	const float *wptr;
	size_t wstep;
	if (NIL_P(width)) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr, &wstep);
	w = bl_clamp_width(w);

	_Bool dc = RTEST(remove_dc);
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
			e = mb_wrap(e + pm * BL_INV_2PI, 1.0);
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
		double d_back = prev_inc + (pm - prev_pm) * BL_INV_2PI;
		if (i > 0 && d_back == pending_d) {
			v += pending;
		} else if (primed && (i > 0 || fabs(mb_wrap(prev_e + d_back - e + 0.5, 1.0) - 0.5) < 1e-6)) {
			double after;
			bl_step(bp, nbp, prev_e, d_back, adv, lo, hi, &after);
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
		double d_fwd = inc + (next_pm - pm) * BL_INV_2PI;
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
	rb_ary_store(state, 0, rb_float_new(mb_wrap(phi + steps, 1.0)));

	if (length > 0) {
		rb_ary_store(bl_state, 0, rb_float_new(prev_e));
		rb_ary_store(bl_state, 1, rb_float_new(prev_inc));
		rb_ary_store(bl_state, 2, rb_float_new(prev_pm));
		rb_ary_store(bl_state, 3, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(frequency);
	RB_GC_GUARD(phase_mod);
	RB_GC_GUARD(width);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Band-limited complex (analytic) oscillators from band-limited impulse
 * trains (BLIT).  An analytic waveform's derivative is a sum of complex
 * exponentials with a closed form (the Dirichlet kernel for all harmonics,
 * e^{iMx} sin(Mx) / sin(x) for the odd ones), so a ramp or square is the
 * integral of a sum that stops below Nyquist: no aliasing, and no negative
 * frequencies (the imaginary part is the real part's Hilbert transform).
 * A triangle integrates a quarter-cycle-shifted square once more.
 *
 * The integrators integrate each step at its midpoint (a slight lift of the
 * top octave: (w/2)/sin(w/2), +2.6 dB at 20 kHz), leak by BLIT_LEAK to
 * absorb rounding, and start from their exact steady state at the current
 * phase (also after a phase jump between buffers; see blit_start).  At 0 Hz
 * the output is 0.  The highest harmonic
 * fades in and out with the frequency (no clicks as harmonics come and go
 * under FM).  Only real arithmetic is used, so the Ruby mirror
 * (MB::Sound::BandLimit.blit_ruby) gives identical results.
 */

#define BLIT_LEAK (1.0 - 1e-4)
#define BLIT_MAX_CYCLES 0.49 // highest harmonic, in cycles per sample

enum blit_shape {
	BLIT_RAMP,
	BLIT_SQUARE,
	BLIT_TRIANGLE,
};

static ID sym_complex_ramp, sym_complex_square, sym_complex_triangle;

static enum blit_shape blit_find_shape(VALUE shape)
{
	ID id = SYM2ID(shape);
	if (id == sym_complex_ramp) return BLIT_RAMP;
	if (id == sym_complex_square) return BLIT_SQUARE;
	if (id == sym_complex_triangle) return BLIT_TRIANGLE;
	rb_raise(rb_eArgError, "No band-limited complex version of %"PRIsVALUE, shape);
}

// The weight of harmonic +k+ when harmonics below +h+ are allowed: 1 up to
// h - 1, fading to 0 at h (so nothing reaches h).
static inline double blit_weight(double k, double h)
{
	double w = h - k;
	return w >= 1.0 ? 1.0 : (w <= 0.0 ? 0.0 : w);
}

// Sum of e^{ikx} for k = 1..+n+, plus +frac+ times e^{i(n+1)x}.
static void blit_all(double x, double n, double frac, double *re, double *im)
{
	double s = sin(0.5 * x);
	double mag;
	if (fabs(s) < 1e-9) {
		mag = n * cos(0.5 * n * x) / cos(0.5 * x);
	} else {
		mag = sin(0.5 * n * x) / s;
	}

	double ph = 0.5 * (n + 1.0) * x;
	*re = mag * cos(ph);
	*im = mag * sin(ph);

	if (frac > 0) {
		*re += frac * cos((n + 1.0) * x);
		*im += frac * sin((n + 1.0) * x);
	}
}

// Sum of e^{ikx} over the first +m+ odd k, plus +frac+ times the next.
static void blit_odd(double x, double m, double frac, double *re, double *im)
{
	double s = sin(x);
	double mag;
	if (fabs(s) < 1e-9) {
		mag = m * cos(m * x) / cos(x);
	} else {
		mag = sin(m * x) / s;
	}

	double ph = m * x;
	*re = mag * cos(ph);
	*im = mag * sin(ph);

	if (frac > 0) {
		*re += frac * cos((2.0 * m + 1.0) * x);
		*im += frac * sin((2.0 * m + 1.0) * x);
	}
}

// The derivative (per radian) of the analytic +shape+ at +theta+ with
// harmonics up to +h+.  For a triangle this is the derivative of the
// shifted square it integrates (its own derivative is that square).
static void blit_derivative(enum blit_shape shape, double theta, double h, double *re, double *im)
{
	if (shape == BLIT_RAMP) {
		double n = fmax(floor(h - 1.0), 0.0); // harmonics at full weight
		blit_all(theta + M_PI, n, blit_weight(n + 1.0, h), re, im);
		*re *= -2.0 / M_PI;
		*im *= -2.0 / M_PI;
	} else {
		double m = fmax(floor(0.5 * (floor(h - 1.0) + 1.0)), 0.0); // odd harmonics at full weight
		double frac = blit_weight(2.0 * m + 1.0, h);
		double scale = shape == BLIT_SQUARE ? 4.0 / M_PI : 8.0 / (M_PI * M_PI);
		blit_odd(shape == BLIT_SQUARE ? theta : theta + 0.5 * M_PI, m, frac, re, im);
		*re *= scale;
		*im *= scale;
	}
}

// Complex multiply and divide on (re, im) pairs (written out, so the Ruby
// mirror can match them exactly).
static inline void blit_mul(double ar, double ai, double br, double bi, double *re, double *im)
{
	double r = ar * br - ai * bi;
	double i = ar * bi + ai * br;
	*re = r;
	*im = i;
}

static inline void blit_div(double ar, double ai, double br, double bi, double *re, double *im)
{
	double d = br * br + bi * bi;
	double r = (ar * br + ai * bi) / d;
	double i = (ai * br - ar * bi) / d;
	*re = r;
	*im = i;
}

// The integrators' steady state for the analytic +shape+ at +theta+ with
// harmonics below +h+ and a step of +delta+ radians (into y, and for a
// triangle the shifted square it integrates into g), so they start without
// a transient (a leftover offset would be amplified by a second stage).
// For each harmonic k, with E = e^{-ik delta}, the midpoint step drives
// delta * a_k k e^{-ik delta/2} into a leaky integrator 1 / (1 - leak E);
// the triangle's trapezoid stage is (delta/2)(1 + E) / (1 - leak E).
static void blit_start(enum blit_shape shape, double theta, double h, double delta, double *yre, double *yim, double *gre, double *gim)
{
	*yre = *yim = *gre = *gim = 0;

	long top = (long)ceil(h);
	for (long k = 1; k <= top; k++) {
		double w = blit_weight((double)k, h);
		if (w == 0) {
			break;
		}
		if (shape != BLIT_RAMP && k % 2 == 0) {
			continue;
		}

		double kd = k * delta;
		double er = cos(kd), ei = -sin(kd);                 // E
		double denr = 1.0 - BLIT_LEAK * er, deni = -BLIT_LEAK * ei; // 1 - leak E
		double hr = cos(0.5 * kd), hi = -sin(0.5 * kd);     // e^{-ik delta/2}
		double zr = cos(k * theta), zi = sin(k * theta);    // e^{ik theta}

		double sr, si; // this harmonic's integrator state
		if (shape == BLIT_TRIANGLE) {
			// g = sum of (8/pi^2)/k (-i) e^{ik(theta + pi/2)}: coefficient
			// b_k = (8/pi^2)/k * i^k on (-i) e^{ik theta}, derivative b_k k
			double bmag = w * 8.0 / (M_PI * M_PI * k);
			double br = 0, bi = k % 4 == 1 ? bmag : -bmag;   // i^k for odd k
			double gr, gi;
			blit_mul(br * delta * k, bi * delta * k, hr, hi, &gr, &gi);
			blit_div(gr, gi, denr, deni, &gr, &gi);

			double tr, ti;
			blit_mul(gr, gi, zr, zi, &tr, &ti);
			*gre += tr;
			*gim += ti;

			// y: (delta/2)(1 + E) / (1 - leak E) times G
			blit_mul(0.5 * delta * (1.0 + er), 0.5 * delta * ei, gr, gi, &sr, &si);
			blit_div(sr, si, denr, deni, &sr, &si);
		} else {
			double a = shape == BLIT_RAMP ? (k % 2 ? 2.0 : -2.0) / (M_PI * k) : 4.0 / (M_PI * k);
			blit_mul(w * a * delta * k, 0, hr, hi, &sr, &si);
			blit_div(sr, si, denr, deni, &sr, &si);
		}

		double tr, ti;
		blit_mul(sr, si, zr, zi, &tr, &ti);
		*yre += tr;
		*yim += ti;
	}
}

/*
 * A band-limited complex oscillator:
 *   blit(buffer (SComplex), shape, frequency, advance, gain, offset, state, blit_state)
 * +shape+ is :complex_ramp, :complex_square, or :complex_triangle (same
 * phase and scale as Oscillator's naive complex waves).  +state+ is the
 * phasor's [phi]; +blit_state+ is [y re, y im, g re, g im, last phase,
 * last increment, primed (0 or 1)].
 */
static VALUE ruby_blit(VALUE self, VALUE buffer, VALUE shape_v, VALUE frequency, VALUE advance, VALUE gain,
		VALUE offset, VALUE state, VALUE blit_state)
{
	enum blit_shape shape = blit_find_shape(shape_v);
	double phi = bl_read_phi(state);
	double adv = NUM2DBL(advance);
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	Check_Type(blit_state, T_ARRAY);
	if (RARRAY_LEN(blit_state) != 7) {
		rb_raise(rb_eArgError, "BLIT state must have seven elements");
	}
	double yre = NUM2DBL(rb_ary_entry(blit_state, 0));
	double yim = NUM2DBL(rb_ary_entry(blit_state, 1));
	double gre = NUM2DBL(rb_ary_entry(blit_state, 2));
	double gim = NUM2DBL(rb_ary_entry(blit_state, 3));
	double prev_p = NUM2DBL(rb_ary_entry(blit_state, 4));
	double prev_inc = NUM2DBL(rb_ary_entry(blit_state, 5));
	_Bool primed = NUM2INT(rb_ary_entry(blit_state, 6)) != 0;

	if (!RTEST(rb_obj_is_kind_of(buffer, numo_cSComplex)) || RNARRAY_NDIM(buffer) != 1 || !RTEST(nary_check_contiguous(buffer))) {
		rb_raise(rb_eArgError, "Buffer must be a contiguous 1D SComplex NArray");
	}
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float complex *out = (float complex *)(nary_get_pointer_for_write(buffer) + nary_get_offset(buffer));

	double freq;
	const float *freqptr;
	size_t freqstep;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqstep);

	_Bool constant = !freqptr;
	double steps = 0;
	double p = 0, inc = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = freqptr[i * freqstep];
		}

		inc = freq * adv;
		if (constant) {
			steps = inc * i;
		}

		p = mb_wrap(phi + steps, 1.0);
		double theta = p * (2.0 * M_PI);

		_Bool continued = primed && (i > 0 || fabs(mb_wrap(prev_p + prev_inc - p + 0.5, 1.0) - 0.5) < 1e-6);
		if (!continued) {
			double h = fabs(inc) > 0 ? BLIT_MAX_CYCLES / fabs(inc) : 1.0;
			blit_start(shape, theta, h, inc * (2.0 * M_PI), &yre, &yim, &gre, &gim);
		} else if (prev_inc != 0) {
			double h = BLIT_MAX_CYCLES / fabs(prev_inc);
			double dtheta = prev_inc * (2.0 * M_PI);
			double dre, dim;
			blit_derivative(shape, theta - 0.5 * dtheta, h, &dre, &dim);

			if (shape == BLIT_TRIANGLE) {
				double ngre = BLIT_LEAK * gre + dtheta * dre;
				double ngim = BLIT_LEAK * gim + dtheta * dim;
				yre = BLIT_LEAK * yre + dtheta * 0.5 * (gre + ngre);
				yim = BLIT_LEAK * yim + dtheta * 0.5 * (gim + ngim);
				gre = ngre;
				gim = ngim;
			} else {
				yre = BLIT_LEAK * yre + dtheta * dre;
				yim = BLIT_LEAK * yim + dtheta * dim;
			}
		}

		out[i] = (float)(yre * g + off) + I * (float)(yim * g);

		prev_p = p;
		prev_inc = inc;
		primed = 1;

		if (!constant) {
			steps += inc;
		}
	}

	if (constant) {
		steps = freq * adv * length;
	}
	rb_ary_store(state, 0, rb_float_new(mb_wrap(phi + steps, 1.0)));

	if (length > 0) {
		rb_ary_store(blit_state, 0, rb_float_new(yre));
		rb_ary_store(blit_state, 1, rb_float_new(yim));
		rb_ary_store(blit_state, 2, rb_float_new(gre));
		rb_ary_store(blit_state, 3, rb_float_new(gim));
		rb_ary_store(blit_state, 4, rb_float_new(prev_p));
		rb_ary_store(blit_state, 5, rb_float_new(prev_inc));
		rb_ary_store(blit_state, 6, INT2NUM(1));
	}

	RB_GC_GUARD(frequency);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Synced oscillators (hard and soft sync), band-limited with minBLEP.
 *
 * A sync input (sync pulses, see MB::Sound::Phasor.sync_pulses) resets the
 * phase to zero (hard sync) or reverses its direction (soft sync) at a
 * sub-sample time.  Resets can't be predicted, so instead of PolyBLEP (which
 * corrects the sample before an edge) this kernel is causal.  Its output is
 * the naive waveform filtered by a minimum-phase lowpass h (the derivative
 * of the minBLEP step B): no latency, and clean hard sync (-98 to -106 dB
 * in the research measurements, against -32 to -40 dB for PolyBLEP).
 *
 * Between events, each sample is h applied to the current segment of the
 * shape extended past its ends: for a polynomial segment f (in time) that
 * is f - m1 f' + (m2 / 2) f'' exactly, with m1 and m2 the first two
 * moments of h (m1 = tau, about 2.78 samples, the delay of a minimum-phase
 * step at low frequencies).  Every event (the shape's own edges, warp
 * corners, resets, reversals) adds the residuals R_n = B_n - M_n of its
 * jumps a_n in the n-th time derivative (n = 0 to 2) into a ring of the
 * following samples, where B_n is h applied to a switched-on t^n / n! and
 * M_n the same without the switch; they settle exactly on zero after
 * +taps+ samples.  So piecewise quadratics (ramp, square, triangle,
 * parabola, and their warps) come out as exactly h applied to the naive
 * waveform: harmonics and DC as the ideal's (the old kernel added the
 * undelayed segment plus a delayed step, leaving tau times each step's
 * height of DC behind: +0.82 for a ramp hard-synced at 2.37x of 3 kHz, and
 * scaled slope jumps' harmonics by 1 + 2 pi i f tau).
 *
 * A sine's segments aren't polynomials; with m1 = m2 = 0, R_0 = R, R_1 the
 * old minBLAMP residual Q = integral of R - Q(inf) B, and R_2 = 0, sines
 * keep the old undelayed scheme (a three-term expansion fails above a few
 * kHz).
 *
 * The tables (built in Ruby by MB::Sound::BandLimit.sync_tables) are
 * sampled +oversample+ times per sample over +taps+ samples and read with
 * linear interpolation.
 */

// Linear interpolation into a residual table at +t+ samples after an event.
static inline double sync_table(const double *table, size_t os, size_t taps, double t)
{
	double x = t * os;
	if (x < 0 || x >= (double)(taps * os)) {
		return 0;
	}

	size_t idx = (size_t)x;
	double frac = x - idx;
	return table[idx] + (table[idx + 1] - table[idx]) * frac;
}

// The residual tables of a synced oscillator and the moments of h.
struct sync_tables {
	const double *r0, *r1, *r2;
	size_t os, taps;
	double m1, half_m2;
};

// Adds an event +t+ samples before the current sample (0 <= t < 1+) with
// jumps +a0+ in value, +a1+ in slope per sample, and +a2+ in curvature per
// sample squared to the ring +acc+ (whose current sample is at +pos+).
static inline void sync_event(double *acc, size_t pos, const struct sync_tables *tb, double t, double a0, double a1, double a2)
{
	if (a0 == 0 && a1 == 0 && a2 == 0) {
		return;
	}

	size_t os = tb->os, taps = tb->taps;
	for (size_t j = 0; j < taps; j++) {
		double tt = t + j;
		acc[(pos + j) % taps] += a0 * sync_table(tb->r0, os, taps, tt) + a1 * sync_table(tb->r1, os, taps, tt) +
			a2 * sync_table(tb->r2, os, taps, tt);
	}
}

// The value and first two derivatives per cycle at +x+ of the segment of
// +wt+ that holds phase +u+ (after a breakpoint, or before it with +left+,
// as in bl_shape).
static inline void sync_segment(enum bl_wave wt, double u, _Bool left, double x, double *f)
{
	switch (wt) {
		case BL_RAMP:
			f[0] = (left ? u <= 0.5 : u < 0.5) ? 2.0 * x : 2.0 * x - 2.0;
			f[1] = 2.0;
			f[2] = 0.0;
			return;

		case BL_SQUARE:
			f[0] = (left ? u <= 0.5 : u < 0.5) ? 1.0 : -1.0;
			f[1] = 0.0;
			f[2] = 0.0;
			return;

		case BL_TRIANGLE:
			if (left ? u <= 0.25 : u < 0.25) {
				f[0] = 4.0 * x;
				f[1] = 4.0;
			} else if (left ? u <= 0.75 : u < 0.75) {
				f[0] = 2.0 - 4.0 * x;
				f[1] = -4.0;
			} else {
				f[0] = 4.0 * x - 4.0;
				f[1] = 4.0;
			}
			f[2] = 0.0;
			return;

		case BL_SINE:
			f[0] = sin(x * (2.0 * M_PI));
			f[1] = (2.0 * M_PI) * cos(x * (2.0 * M_PI));
			f[2] = -(4.0 * M_PI * M_PI) * f[0];
			return;

		case BL_PARABOLA:
			if (left ? u <= 0.5 : u < 0.5) {
				double y = 1.0 - 4.0 * x;
				f[0] = 1.0 - y * y;
				f[1] = 8.0 * y;
				f[2] = -32.0;
			} else {
				double y = 4.0 * x - 3.0;
				f[0] = y * y - 1.0;
				f[1] = 8.0 * y;
				f[2] = 32.0;
			}
			return;

		default:
			f[0] = 0.0;
			f[1] = 0.0;
			f[2] = 0.0;
			return;
	}
}

// The value and first two time derivatives (per sample) of +wt+ warped by
// +w+ at phase +p+ moving at +vel+ cycles per sample (on the left side of a
// breakpoint there with +left+, with p = 1 for the end of the cycle).
static inline void sync_raw(enum bl_wave wt, double w, double p, _Bool left, double vel, double *a)
{
	_Bool first = left ? p <= w : p < w;
	double k = first ? 0.5 / w : 0.5 / (1.0 - w);
	double u = first ? p * k : 0.5 + (p - w) * k;
	double g = vel * k;
	sync_segment(wt, u, left, u, a);
	a[1] *= g;
	a[2] *= g * g;
}

// Like bl_crossing, but a phase on a breakpoint is always on its right
// side (the value after it going forward), whichever way the phase moves,
// so soft sync can reverse on an edge: a backward step starting exactly on
// +b+ crosses it at once (0), and one ending within BL_EPS of +b+ (where
// the phase snaps onto it) doesn't cross it.  Forward steps are as in
// bl_crossing.
static inline double sync_crossing(double e, double d, double b)
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

// Moves phase *p by +vel+ cycles per sample for +dur+ samples, adding an
// event for every breakpoint crossed; the segment ends +end_t+ samples
// before the current sample.  Returns nothing; updates *p.
static inline void sync_move(enum bl_wave wt, double w, struct bl_breakpoint *bp, int nbp, double *p, double vel,
		double dur, double end_t, double *acc, size_t pos, const struct sync_tables *tb, _Bool bl)
{
	double move = vel * dur;
	if (bl && move != 0) {
		for (int j = 0; j < nbp; j++) {
			double f = sync_crossing(*p, move, bp[j].pos);
			if (f < 0) {
				continue;
			}

			// Jumps from one side of the breakpoint to the other
			double bpos = bp[j].pos;
			double r[3], l[3];
			sync_raw(wt, w, bpos, 0, vel, r);
			sync_raw(wt, w, bpos == 0.0 ? 1.0 : bpos, 1, vel, l);
			double t = end_t + (1.0 - f) * dur; // samples before the current sample
			if (move > 0) {
				sync_event(acc, pos, tb, t, r[0] - l[0], r[1] - l[1], r[2] - l[2]);
			} else {
				sync_event(acc, pos, tb, t, l[0] - r[0], l[1] - r[1], l[2] - r[2]);
			}
		}
	}

	// A phase within rounding of an edge is on it (the value after it),
	// matching the crossing tolerance (see bl_snap)
	*p = mb_wrap(*p + move, 1.0);
	int snapped = bl_snap(bp, nbp, *p);
	if (snapped >= 0) {
		*p = bp[snapped].pos;
	}
}

// Reads a residual table argument of +len+ elements.
static const double *sync_table_arg(VALUE table, size_t len)
{
	if (CLASS_OF(table) != numo_cDFloat || RNARRAY_NDIM(table) != 1 || RNARRAY_SHAPE(table)[0] != len ||
			!RTEST(nary_check_contiguous(table))) {
		rb_raise(rb_eArgError, "Tables must be contiguous DFloats of taps * oversample + 1 elements");
	}
	return (const double *)(nary_get_pointer_for_read(table) + nary_get_offset(table));
}

/*
 * A synced oscillator:
 *   oscillate_sync(buffer, wave_type, frequency, advance, gain, offset,
 *                  sync_state, ring, pulses, soft, width, remove_dc,
 *                  r0, r1, r2, oversample, taps, band_limit, m1, m2)
 * +sync_state+ is [phase at the last sample (cycles), last increment,
 * direction (1 or -1), ring position, primed (0 or 1)]; the first sample of
 * an unprimed oscillator starts at the phase in sync_state[0].  +ring+ is a
 * DFloat of +taps+ pending corrections.  +pulses+ is an NArray of sync
 * pulses (or nil): a nonzero value v means a reset (+soft+ false) or a
 * reversal (+soft+ true) 1 - |v| samples before that sample.  +width+ and
 * +remove_dc+ are as for oscillate_bl.  +r0+, +r1+, +r2+, +m1+, and +m2+
 * are the residual tables and moments of h (see above;
 * MB::Sound::BandLimit.sync_tables); +band_limit+ false skips the
 * corrections and the filtering (naive sync).  See
 * MB::Sound::BandLimit.sync_ruby.
 */
static VALUE ruby_oscillate_sync(int argc, VALUE *argv, VALUE self)
{
	if (argc != 20) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 20)", argc);
	}

	VALUE buffer = argv[0], frequency = argv[2], sync_state = argv[6], ring = argv[7], pulses = argv[8];
	VALUE width = argv[10], r0_v = argv[12], r1_v = argv[13], r2_v = argv[14];

	enum bl_wave wt = bl_find_wave(argv[1]);
	double adv = NUM2DBL(argv[3]);
	double g = NUM2DBL(argv[4]);
	double off = NUM2DBL(argv[5]);
	_Bool soft = RTEST(argv[9]);
	_Bool dc = RTEST(argv[11]);
	size_t os = NUM2SIZET(argv[15]);
	size_t taps = NUM2SIZET(argv[16]);
	_Bool bl = RTEST(argv[17]);
	double m1 = NUM2DBL(argv[18]);
	double m2 = NUM2DBL(argv[19]);

	Check_Type(sync_state, T_ARRAY);
	if (RARRAY_LEN(sync_state) != 5) {
		rb_raise(rb_eArgError, "Sync state must have five elements");
	}
	double p = NUM2DBL(rb_ary_entry(sync_state, 0));
	double prev_inc = NUM2DBL(rb_ary_entry(sync_state, 1));
	double dir = NUM2DBL(rb_ary_entry(sync_state, 2));
	size_t pos = NUM2SIZET(rb_ary_entry(sync_state, 3));
	_Bool primed = NUM2INT(rb_ary_entry(sync_state, 4)) != 0;

	if (CLASS_OF(ring) != numo_cDFloat || RNARRAY_SHAPE(ring)[0] != taps || !RTEST(nary_check_contiguous(ring))) {
		rb_raise(rb_eArgError, "Ring must be a contiguous DFloat of taps elements");
	}
	double *acc = (double *)(nary_get_pointer_for_write(ring) + nary_get_offset(ring));
	pos %= taps;

	size_t table_len = taps * os + 1;
	struct sync_tables tb = {
		.r0 = sync_table_arg(r0_v, table_len),
		.r1 = sync_table_arg(r1_v, table_len),
		.r2 = sync_table_arg(r2_v, table_len),
		.os = os,
		.taps = taps,
		.m1 = bl ? m1 : 0.0,
		.half_m2 = bl ? 0.5 * m2 : 0.0,
	};

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	const float *freqptr;
	size_t freqstep;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqstep);

	double pulse;
	const float *pulseptr;
	size_t pulsestep;
	mb_read_signal_input(&pulses, length, "Sync", &pulse, &pulseptr, &pulsestep);
	if (!pulseptr) {
		pulse = 0;
	}

	double w;
	const float *wptr;
	size_t wstep;
	if (NIL_P(width)) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr, &wstep);
	w = bl_clamp_width(w);
	double half_mean = bl_half_mean(wt);

	struct bl_breakpoint bp[BL_MAX_BREAKPOINTS];
	int nbp = bl_breakpoints(wt, w, bp, 1);

	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = freqptr[i * freqstep];
		}
		if (pulseptr) {
			pulse = pulseptr[i * pulsestep];
		}
		if (wptr) {
			double new_w = bl_clamp_width(wptr[i * wstep]);
			if (new_w != w) {
				w = new_w;
				nbp = bl_breakpoints(wt, w, bp, 1);
			}
		}

		// The phase velocity into this sample (for the first sample of an
		// unprimed oscillator, as if it had always run at this frequency)
		double vel = dir * (primed ? prev_inc : freq * adv);

		if (primed) {
			if (pulse != 0) {
				double d = 1.0 - fabs(pulse); // the event is d samples before this sample
				if (d < 0) d = 0;
				if (d > 1) d = 1;

				sync_move(wt, w, bp, nbp, &p, vel, 1.0 - d, d, acc, pos, &tb, bl);

				// Jumps from the old direction or phase to the new
				double a0[3], a1[3];
				sync_raw(wt, w, p, 0, vel, a0);
				double nvel;
				if (soft) {
					dir = -dir;
					nvel = -vel;
				} else {
					dir = 1.0;
					nvel = prev_inc;
					p = 0;
				}
				sync_raw(wt, w, p, 0, nvel, a1);
				if (bl) sync_event(acc, pos, &tb, d, a1[0] - a0[0], a1[1] - a0[1], a1[2] - a0[2]);
				vel = nvel;

				sync_move(wt, w, bp, nbp, &p, vel, d, 0, acc, pos, &tb, bl);
			} else {
				sync_move(wt, w, bp, nbp, &p, vel, 1.0, 0, acc, pos, &tb, bl);
			}
		}

		// The current segment, filtered by h (see above)
		double a[3];
		sync_raw(wt, w, p, 0, vel, a);
		double v = a[0] - tb.m1 * a[1] + tb.half_m2 * a[2];
		v += acc[pos];
		acc[pos] = 0;
		pos = (pos + 1) % taps;

		if (dc) {
			v -= half_mean * (2.0 * w - 1.0);
		}

		out[i] = v * g + off;

		prev_inc = freq * adv;
		primed = 1;
	}

	if (length > 0) {
		rb_ary_store(sync_state, 0, rb_float_new(p));
		rb_ary_store(sync_state, 1, rb_float_new(prev_inc));
		rb_ary_store(sync_state, 2, rb_float_new(dir));
		rb_ary_store(sync_state, 3, SIZET2NUM(pos));
		rb_ary_store(sync_state, 4, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(frequency);
	RB_GC_GUARD(pulses);
	RB_GC_GUARD(width);
	RB_GC_GUARD(ring);
	RB_GC_GUARD(r0_v);
	RB_GC_GUARD(r1_v);
	RB_GC_GUARD(r2_v);
	RB_GC_GUARD(buffer);

	return buffer;
}

void Init_fast_synth(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_synth = rb_define_module_under(sound, "FastSynth");

	sym_ramp = rb_intern("ramp");
	sym_square = rb_intern("square");
	sym_triangle = rb_intern("triangle");
	sym_sine = rb_intern("sine");
	sym_parabola = rb_intern("parabola");
	sym_complex_ramp = rb_intern("complex_ramp");
	sym_complex_square = rb_intern("complex_square");
	sym_complex_triangle = rb_intern("complex_triangle");

	rb_define_module_function(fast_synth, "oscillate_bl", ruby_oscillate_bl, 13);
	rb_define_module_function(fast_synth, "blit", ruby_blit, 8);
	rb_define_module_function(fast_synth, "oscillate_sync", ruby_oscillate_sync, -1);
}
