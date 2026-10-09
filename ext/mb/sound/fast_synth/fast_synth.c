/*
 * MB::Sound::FastSynth: synthesis kernels.  Band-limited oscillators
 * (PolyBLEP / PolyBLAMP), and at the end a feedback sine (FM operator
 * self-feedback, ruby_feedback_sine).
 *
 * A naive waveform with jumps (ramp, square) or corners (triangle) aliases,
 * because those edges contain harmonics far above Nyquist.  The band-limited
 * waveform equals the naive one plus a short correction around each edge,
 * scaled by the size of the jump in value (a BLEP: band-limited step) or in
 * slope (a BLAMP: band-limited ramp).  The 2-point polynomial versions used
 * here touch only the sample before and the sample after each edge, placed
 * at the edge's exact sub-sample time.
 *
 * Edges are found on the "effective phase" e = phase + phase_mod (both in
 * cycles), moving by d = increment + change in phase_mod per sample,
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
#include "mb_bl_osc.h"

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

// Reads and checks the [phi] state array of a phasor (cycles).
static double bl_read_phi(VALUE state)
{
	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 1) {
		rb_raise(rb_eArgError, "State array must have exactly one numeric element");
	}
	return NUM2DBL(rb_ary_entry(state, 0));
}

/*
 * A band-limited oscillator (like ruby_oscillate, without random advance):
 *   oscillate_bl(buffer, wave_type, frequency, phase_mod, advance, gain,
 *                offset, state, bl_state, fade_lo, fade_hi)
 *
 * +phase_mod+ is in cycles.  +state+ is the phasor's [phi]; +bl_state+ is
 * [last effective phase, last increment, last phase_mod, primed (1; 0 for a tone's first sample, which
 * is corrected as if the tone had always run; 2 after a phase jump, which
 * skips the correction)], carried between buffers so the first sample of a
 * buffer is corrected for an edge just before it.
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

	struct mb_bl_state st;
	st.phi = bl_read_phi(state);
	double adv = NUM2DBL(advance);
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);
	double lo = NUM2DBL(fade_lo);
	double hi = NUM2DBL(fade_hi);

	Check_Type(bl_state, T_ARRAY);
	if (RARRAY_LEN(bl_state) != 4) {
		rb_raise(rb_eArgError, "Band-limiting state must have four elements");
	}
	st.prev_e = NUM2DBL(rb_ary_entry(bl_state, 0));
	st.prev_inc = NUM2DBL(rb_ary_entry(bl_state, 1));
	st.prev_pm = NUM2DBL(rb_ary_entry(bl_state, 2));
	st.primed = NUM2INT(rb_ary_entry(bl_state, 3));

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	struct mb_signal freq, pm, w;
	mb_signal_input(&frequency, length, "Frequency", &freq);
	mb_signal_input(&phase_mod, length, "Phase modulation", &pm);
	if (NIL_P(width)) {
		width = DBL2NUM(0.5);
	}
	mb_signal_input(&width, length, "Width", &w);

	mb_bl_oscillate(wt, out, length, &freq, &pm, &w, adv, g, off, lo, hi, RTEST(remove_dc), &st);

	rb_ary_store(state, 0, rb_float_new(st.phi));

	if (length > 0) {
		rb_ary_store(bl_state, 0, rb_float_new(st.prev_e));
		rb_ary_store(bl_state, 1, rb_float_new(st.prev_inc));
		rb_ary_store(bl_state, 2, rb_float_new(st.prev_pm));
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
 * A sine's segments are complex exponentials e^(2 pi i (u + g t)) instead
 * (u the shape's phase, g its frequency in cycles per sample), which h
 * scales by H(g); switching one on adds the residual E(g, t) e^(...),
 * tabulated over g (MB::Sound::BandLimit.sync_sine_table), and switching
 * one off subtracts it.  So synced sines (and their warps) are exact too.
 * (A three-term expansion of a sine's jumps failed above a few kHz.)
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

// Rows per cycle per sample of the sine residual table
// (BandLimit::SYNC_SINE_ROWS_PER_CYCLE).
#define SYNC_SINE_ROWS_PER_CYCLE 256

// The sine residual table (MB::Sound::BandLimit.sync_sine_table): +rows+
// rows of +len+ complex values (re, im interleaved), and the moment m1 the
// table's rows are multiplied by e^(2 pi i g m1) with.
struct sync_sine {
	const double *e;
	size_t rows, len, os, taps;
	double m1;
};

// The shape's phase *u (cycles) of the segment of a sine warped by +w+ at
// phase +p+ (on the left side of a breakpoint there with +left+), and its
// frequency *g (cycles per sample) at +vel+.
static inline void sync_sine_segment(double w, double p, _Bool left, double vel, double *u, double *g)
{
	_Bool first = left ? p <= w : p < w;
	double k = first ? 0.5 / w : 0.5 / (1.0 - w);
	*u = first ? p * k : 0.5 + (p - w) * k;
	*g = vel * k;
}

// The sine residual table at frequency +g+ (cycles per sample, either sign)
// and +t+ samples after the switch, interpolated linearly in both.
static inline void sync_sine_lookup(const struct sync_sine *sn, double g, double t, double *re, double *im)
{
	double gr = fabs(g) * SYNC_SINE_ROWS_PER_CYCLE;
	double x = t * sn->os;
	if (gr >= (double)(sn->rows - 1) || x < 0 || x >= (double)(sn->taps * sn->os)) {
		*re = 0.0;
		*im = 0.0;
		return;
	}

	size_t r = (size_t)gr;
	double fg = gr - r;
	size_t idx = (size_t)x;
	double ft = x - idx;
	const double *e00 = sn->e + (r * sn->len + idx) * 2;
	const double *e10 = e00 + sn->len * 2;
	double are = e00[0] + (e00[2] - e00[0]) * ft;
	double aim = e00[1] + (e00[3] - e00[1]) * ft;
	double bre = e10[0] + (e10[2] - e10[0]) * ft;
	double bim = e10[1] + (e10[3] - e10[1]) * ft;
	*re = are + (bre - are) * fg;
	*im = aim + (bim - aim) * fg;
	if (g < 0) {
		*im = -*im;
	}
}

// Adds (+sign+ 1) or removes (-1) the residual of a sine segment at phase
// +u+ and frequency +g+ switched on +t+ samples before the current sample.
static inline void sync_sine_switch(double *acc, size_t pos, const struct sync_sine *sn, double t, double u, double g, double sign)
{
	// e^(i psi) for psi = 2 pi (u + g (t + j - m1)), rotated by a complex
	// multiply per tap
	size_t taps = sn->taps;
	double psi = 2.0 * M_PI * (u + g * (t - sn->m1));
	double dpsi = 2.0 * M_PI * g;
	double cr = cos(psi), ci = sin(psi);
	double sr = cos(dpsi), si = sin(dpsi);
	for (size_t j = 0; j < taps; j++) {
		double re, im;
		sync_sine_lookup(sn, g, t + j, &re, &im);
		acc[(pos + j) % taps] += sign * (re * ci + im * cr);

		double nr = cr * sr - ci * si;
		ci = cr * si + ci * sr;
		cr = nr;
	}
}

// A sine segment at phase +u+ and frequency +g+, filtered by h: the
// imaginary part of H(g) e^(2 pi i u), with H(g) = -E(g, 0).
static inline double sync_sine_value(const struct sync_sine *sn, double u, double g)
{
	double re, im;
	sync_sine_lookup(sn, g, 0.0, &re, &im);
	double psi = 2.0 * M_PI * (u - g * sn->m1);
	return -(re * sin(psi) + im * cos(psi));
}

// Moves phase *p by +vel+ cycles per sample for +dur+ samples, adding an
// event for every breakpoint crossed; the segment ends +end_t+ samples
// before the current sample.  Returns nothing; updates *p.
static inline void sync_move(enum bl_wave wt, double w, struct bl_breakpoint *bp, int nbp, double *p, double vel,
		double dur, double end_t, double *acc, size_t pos, const struct sync_tables *tb, _Bool bl,
		const struct sync_sine *sn)
{
	double move = vel * dur;
	if (bl && move != 0) {
		for (int j = 0; j < nbp; j++) {
			double f = bl_side_crossing(*p, move, bp[j].pos);
			if (f < 0) {
				continue;
			}

			double bpos = bp[j].pos;
			double t = end_t + (1.0 - f) * dur; // samples before the current sample

			if (sn) {
				// From one sine segment to the other
				double ur, gr, ul, gl;
				sync_sine_segment(w, bpos, 0, vel, &ur, &gr);
				sync_sine_segment(w, bpos == 0.0 ? 1.0 : bpos, 1, vel, &ul, &gl);
				if (gl == gr) {
					continue; // the same exponential (no warp here)
				}
				if (move > 0) {
					sync_sine_switch(acc, pos, sn, t, ul, gl, -1.0);
					sync_sine_switch(acc, pos, sn, t, ur, gr, 1.0);
				} else {
					sync_sine_switch(acc, pos, sn, t, ur, gr, -1.0);
					sync_sine_switch(acc, pos, sn, t, ul, gl, 1.0);
				}
				continue;
			}

			// Jumps from one side of the breakpoint to the other
			double r[3], l[3];
			sync_raw(wt, w, bpos, 0, vel, r);
			sync_raw(wt, w, bpos == 0.0 ? 1.0 : bpos, 1, vel, l);
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
 *                  r0, r1, r2, oversample, taps, band_limit, m1, m2,
 *                  sine_table, reset_phase)
 * +sync_state+ is [phase at the last sample (cycles), last increment,
 * direction (1 or -1), ring position, primed (0 or 1)]; the first sample of
 * an unprimed oscillator starts at the phase in sync_state[0].  +ring+ is a
 * DFloat of +taps+ pending corrections.  +pulses+ is an NArray of sync
 * pulses (or nil): a nonzero value v means a reset (+soft+ false) or a
 * reversal (+soft+ true) 1 - |v| samples before that sample.  +width+ and
 * +remove_dc+ are as for oscillate_bl.  +r0+, +r1+, +r2+, +m1+, and +m2+
 * are the residual tables and moments of h (see above;
 * MB::Sound::BandLimit.sync_tables); +band_limit+ false skips the
 * corrections and the filtering (naive sync).  +sine_table+ is
 * BandLimit.sync_sine_table for band-limited sines (nil otherwise).
 * +reset_phase+ (cycles, or nil for 0) is where hard sync events put the
 * phase: Tone resets (reset inputs, key sync, timeline jumps) are hard sync
 * events on their sample (a pulse of 1) to the reset target.  See
 * MB::Sound::BandLimit.sync_ruby.
 */
static VALUE ruby_oscillate_sync(int argc, VALUE *argv, VALUE self)
{
	if (argc != 21 && argc != 22) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 21..22)", argc);
	}

	VALUE buffer = argv[0], frequency = argv[2], sync_state = argv[6], ring = argv[7], pulses = argv[8];
	VALUE width = argv[10], r0_v = argv[12], r1_v = argv[13], r2_v = argv[14], sine_v = argv[20];

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
	double reset_phase = argc > 21 && !NIL_P(argv[21]) ? NUM2DBL(argv[21]) : 0.0;

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

	struct sync_sine sine_tab;
	const struct sync_sine *sn = NULL;
	if (bl && wt == BL_SINE && !NIL_P(sine_v)) {
		if (CLASS_OF(sine_v) != numo_cDComplex || RNARRAY_NDIM(sine_v) != 2 || RNARRAY_SHAPE(sine_v)[0] < 2 ||
				RNARRAY_SHAPE(sine_v)[1] != table_len || !RTEST(nary_check_contiguous(sine_v))) {
			rb_raise(rb_eArgError, "Sine table must be a contiguous 2D DComplex of [rows (at least 2), taps * oversample + 1]");
		}
		sine_tab = (struct sync_sine){
			.e = (const double *)(nary_get_pointer_for_read(sine_v) + nary_get_offset(sine_v)),
			.rows = RNARRAY_SHAPE(sine_v)[0],
			.len = table_len,
			.os = os,
			.taps = taps,
			.m1 = m1,
		};
		sn = &sine_tab;
	}

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

				sync_move(wt, w, bp, nbp, &p, vel, 1.0 - d, d, acc, pos, &tb, bl, sn);

				// Jumps from the old direction or phase to the new
				double a0[3], a1[3], u0 = 0, g0 = 0;
				sync_raw(wt, w, p, 0, vel, a0);
				if (sn) {
					sync_sine_segment(w, p, 0, vel, &u0, &g0);
				}
				double nvel;
				if (soft) {
					dir = -dir;
					nvel = -vel;
				} else {
					dir = 1.0;
					nvel = prev_inc;
					p = reset_phase;
				}
				sync_raw(wt, w, p, 0, nvel, a1);
				if (sn) {
					double u1, g1;
					sync_sine_segment(w, p, 0, nvel, &u1, &g1);
					sync_sine_switch(acc, pos, sn, d, u0, g0, -1.0);
					sync_sine_switch(acc, pos, sn, d, u1, g1, 1.0);
				} else if (bl) {
					sync_event(acc, pos, &tb, d, a1[0] - a0[0], a1[1] - a0[1], a1[2] - a0[2]);
				}
				vel = nvel;

				sync_move(wt, w, bp, nbp, &p, vel, d, 0, acc, pos, &tb, bl, sn);
			} else {
				sync_move(wt, w, bp, nbp, &p, vel, 1.0, 0, acc, pos, &tb, bl, sn);
			}
		}

		// The current segment, filtered by h (see above)
		double v;
		if (sn) {
			double u, gs;
			sync_sine_segment(w, p, 0, vel, &u, &gs);
			v = sync_sine_value(sn, u, gs);
		} else {
			double a[3];
			sync_raw(wt, w, p, 0, vel, a);
			v = a[0] - tb.m1 * a[1] + tb.half_m2 * a[2];
		}
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
	RB_GC_GUARD(sine_v);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Operator self-feedback: a sine whose phase is modulated by its own last
 * two outputs, averaged (as the DX7 does, which tames the period-two
 * "hunting" a one-sample loop has at high feedback):
 *
 *     m[i] = (feedback[i] * 2pi) * ((y[i-1] + y[i-2]) * 0.5)
 *     y[i] = sin(phase[i] * 2pi + pm[i] * 2pi + m[i]) * level[i]
 *     out[i] = (y[i] - dc[i]) * gain + offset
 *
 * dc[i] (when +remove_dc+ is true; else 0) is the feedback sine's DC
 * offset (its mean grows with the amount, e.g. -0.25 at 0.32 cycles), tracked
 * by a one-pole lowpass whose cutoff follows the pitch (FB_DC_RATIO times
 * the frequency, from |increment|), so subtracting it is a one-pole
 * highpass at a fixed fraction of the fundamental: the same phase shift
 * at every pitch (atan(FB_DC_RATIO) at the fundamental), LFOs included,
 * and the estimate settles in a few cycles.  It is applied to the output
 * only; the loop feeds back y[i] with its DC.
 *
 * The loop is per sample (each sample depends on the last), inside the
 * kernel rather than through a graph loop, so the cost per sample is the
 * same whatever the feedback amount (one sin plus a few multiplies).
 * +level+ is the operator's in-loop output level (e.g. an envelope), so
 * feedback follows it like an FM synth's operator; +gain+ and +offset+
 * (Tone#at) are applied outside the loop.
 *
 * +frequency+ (Hz), +phase_mod+ (cycles, or nil), +feedback+ (cycles per
 * unit of averaged output), and +level+ are Numerics or NArrays (read as
 * float32); the phase modulation and feedback are converted to radians per
 * sample (times 2pi, exact for 0).  +state+ is [phase in cycles]; the phase arithmetic is that of
 * FastSound.oscillate (phase i = wrap(phi + sum of increments 0...i)), so
 * with feedback 0 and level 1 the samples are a plain sine's.
 * +fb_state+ is [y[n-1], y[n-2], dc] (doubles), carried between buffers.
 *
 * Every product and sum is its own statement so no compiler fuses a
 * multiply-add (clang contracts within expressions by default), keeping
 * the Ruby mirror (Tone#feedback_ruby) exact.
 */
#define FB_DC_RATIO (1.0 / 20.0)

static VALUE ruby_feedback_sine(VALUE self, VALUE buffer, VALUE frequency, VALUE phase_mod, VALUE advance,
		VALUE gain, VALUE offset, VALUE state, VALUE fb_state, VALUE feedback, VALUE level, VALUE remove_dc)
{
	double phi = bl_read_phi(state);
	double adv = NUM2DBL(advance);
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	Check_Type(fb_state, T_ARRAY);
	if (RARRAY_LEN(fb_state) != 3) {
		rb_raise(rb_eArgError, "Feedback state must have three elements");
	}
	double y1 = NUM2DBL(rb_ary_entry(fb_state, 0));
	double y2 = NUM2DBL(rb_ary_entry(fb_state, 1));
	double dc = NUM2DBL(rb_ary_entry(fb_state, 2));
	_Bool dc_off = RTEST(remove_dc);
	const double dc_k = 2.0 * M_PI * FB_DC_RATIO;

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

	double fb;
	const float *fbptr;
	size_t fbstep;
	mb_read_signal_input(&feedback, length, "Feedback", &fb, &fbptr, &fbstep);

	double lvl;
	const float *lvlptr;
	size_t lvlstep;
	mb_read_signal_input(&level, length, "Level", &lvl, &lvlptr, &lvlstep);

	_Bool constant = !freqptr;
	double steps = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = freqptr[i * freqstep];
		}
		if (pmptr) {
			pm = pmptr[i * pmstep];
		}
		if (fbptr) {
			fb = fbptr[i * fbstep];
		}
		if (lvlptr) {
			lvl = lvlptr[i * lvlstep];
		}

		double inc = freq * adv;
		if (constant) {
			steps = inc * i;
		}

		double ph = mb_wrap(phi + steps, 1.0);
		double radians = ph * (2.0 * M_PI);
		double avg = y1 + y2;
		avg = avg * 0.5;
		double fbr = fb * (2.0 * M_PI);
		double m = fbr * avg;
		double pmr = pm * (2.0 * M_PI);
		double arg = radians + pmr;
		arg = arg + m;
		double y = sin(arg);
		y = y * lvl;
		y2 = y1;
		y1 = y;

		double v = y;
		if (dc_off) {
			// One-pole lowpass at FB_DC_RATIO times the frequency
			double c = fabs(inc);
			c = c * dc_k;
			if (c > 1.0) {
				c = 1.0;
			}
			double d = y - dc;
			d = d * c;
			dc = dc + d;
			v = y - dc;
		}
		v = v * g;
		out[i] = v + off;

		if (!constant) {
			steps += inc;
		}
	}

	if (constant) {
		steps = freq * adv;
		steps = steps * length;
	}
	rb_ary_store(state, 0, rb_float_new(mb_wrap(phi + steps, 1.0)));
	rb_ary_store(fb_state, 0, rb_float_new(y1));
	rb_ary_store(fb_state, 1, rb_float_new(y2));
	rb_ary_store(fb_state, 2, rb_float_new(dc));

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(frequency);
	RB_GC_GUARD(phase_mod);
	RB_GC_GUARD(feedback);
	RB_GC_GUARD(level);
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
	rb_define_module_function(fast_synth, "feedback_sine", ruby_feedback_sine, 11);
}
