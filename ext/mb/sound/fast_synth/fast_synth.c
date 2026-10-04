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
static double bl_shape(enum bl_wave wt, double u, _Bool left)
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

// The waveform at phase +p+ with width +w+.
static inline double bl_value(enum bl_wave wt, double p, double w)
{
	return bl_shape(wt, bl_warp(p, w), 0);
}

// Fills +bp+ with the breakpoints of +wt+ warped by width +w+ (positions in
// phase; jumps in value and in slope per cycle of phase), returning how
// many there are.  Points with no jump are left out.
static int bl_breakpoints(enum bl_wave wt, double w, struct bl_breakpoint *bp)
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

		if (dv == 0 && ds == 0) {
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
static double bl_crossing(double e, double d, double b)
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
static double bl_fade(double freq, double lo, double hi)
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
	complex float *freqptr;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr);

	double pm;
	complex float *pmptr;
	mb_read_signal_input(&phase_mod, length, "Phase modulation", &pm, &pmptr);

	double w;
	complex float *wptr;
	if (NIL_P(width)) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr);
	w = bl_clamp_width(w);

	_Bool dc = RTEST(remove_dc);
	double half_mean = bl_half_mean(wt);

	struct bl_breakpoint bp[BL_MAX_BREAKPOINTS];
	int nbp = bl_breakpoints(wt, w, bp);

	_Bool constant = !freqptr;
	double steps = 0;
	double e = 0, inc = 0;
	double pending = 0, pending_d = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = crealf(freqptr[i]);
		}
		if (pmptr) {
			pm = crealf(pmptr[i]);
		}
		if (wptr) {
			double new_w = bl_clamp_width(crealf(wptr[i]));
			if (new_w != w) {
				w = new_w;
				nbp = bl_breakpoints(wt, w, bp);
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
			v = bl_value(wt, e, w);
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
			next_pm = pmptr ? crealf(pmptr[i + 1]) : pm;
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
	complex float *freqptr;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr);

	_Bool constant = !freqptr;
	double steps = 0;
	double p = 0, inc = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = crealf(freqptr[i]);
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
}
