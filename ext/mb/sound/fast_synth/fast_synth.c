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

struct bl_breakpoint {
	double pos; // phase in cycles (0..1)
	double dv;  // value after minus value before (moving forward)
	double ds;  // slope after minus slope before, per cycle
};

enum bl_wave {
	BL_NONE,
	BL_RAMP,
	BL_SQUARE,
	BL_TRIANGLE,
};

static ID sym_ramp, sym_square, sym_triangle;

// Returns the band-limited wave type for the Symbol +wave_type+ (raising an
// error if it has no band-limited version).
static enum bl_wave bl_find_wave(VALUE wave_type)
{
	ID id = SYM2ID(wave_type);
	if (id == sym_ramp) return BL_RAMP;
	if (id == sym_square) return BL_SQUARE;
	if (id == sym_triangle) return BL_TRIANGLE;
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

// The naive waveform at phase +u+ (cycles, 0..1); same shapes as osc_sample.
static double bl_shape(enum bl_wave wt, double u)
{
	switch (wt) {
		case BL_RAMP:
			return u < 0.5 ? 2.0 * u : 2.0 * u - 2.0;

		case BL_SQUARE:
			return u < 0.5 ? 1.0 : -1.0;

		case BL_TRIANGLE:
			if (u < 0.25) {
				return 4.0 * u;
			} else if (u < 0.75) {
				return 2.0 - 4.0 * u;
			}
			return 4.0 * u - 4.0;

		default:
			return 0.0;
	}
}

// Fills +bp+ with the breakpoints of +wt+, returning how many there are.
static int bl_breakpoints(enum bl_wave wt, struct bl_breakpoint *bp)
{
	switch (wt) {
		case BL_RAMP:
			bp[0] = (struct bl_breakpoint){ 0.5, -2.0, 0.0 };
			return 1;

		case BL_SQUARE:
			bp[0] = (struct bl_breakpoint){ 0.0, 2.0, 0.0 };
			bp[1] = (struct bl_breakpoint){ 0.5, -2.0, 0.0 };
			return 2;

		case BL_TRIANGLE:
			bp[0] = (struct bl_breakpoint){ 0.25, 0.0, -8.0 };
			bp[1] = (struct bl_breakpoint){ 0.75, 0.0, 8.0 };
			return 2;

		default:
			return 0;
	}
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

// Returns phase +e+ moved onto any breakpoint within BL_EPS of it, so a
// sample at an edge takes the value after the edge, matching bl_crossing.
static inline double bl_snap(struct bl_breakpoint *bp, int count, double e)
{
	for (int j = 0; j < count; j++) {
		double diff = fabs(e - bp[j].pos);
		if (diff < BL_EPS || diff > 1.0 - BL_EPS) {
			return bp[j].pos;
		}
	}

	return e;
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
 * bl_fade; 0 and 0 for always on).  See MB::Sound::BandLimit.
 */
static VALUE ruby_oscillate_bl(VALUE self, VALUE buffer, VALUE wave_type, VALUE frequency, VALUE phase_mod,
		VALUE advance, VALUE gain, VALUE offset, VALUE state, VALUE bl_state, VALUE fade_lo, VALUE fade_hi)
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

	struct bl_breakpoint bp[BL_MAX_BREAKPOINTS];
	int nbp = bl_breakpoints(wt, bp);

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

		inc = freq * adv;
		if (constant) {
			steps = inc * i;
		}

		e = mb_wrap(phi + steps, 1.0);
		if (pm != 0) {
			e = mb_wrap(e + pm * BL_INV_2PI, 1.0);
		}
		e = bl_snap(bp, nbp, e);
		double v = bl_shape(wt, e);

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

	rb_define_module_function(fast_synth, "oscillate_bl", ruby_oscillate_bl, 11);
}
