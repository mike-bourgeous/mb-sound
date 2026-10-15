/*
 * MB::Sound::FastWavetable: band-limited wavetable kernels (see
 * MB::Sound::Wavetable for the design).
 * (C)2025-2026 Mike Bourgeous
 *
 * A table is a set of levels (mipmaps), brightest first, each a 2D SFloat
 * or SComplex NArray of [frames, count + 2 * guard] samples: one cycle per
 * frame in cycle mode (wrapped around in the guard samples), or the attack
 * of a sampled sound (sample mode; a looped sound has separate loop levels
 * holding one period of the loop each).  The Ruby side describes a table
 * with Wavetable#kernel_spec.
 *
 * Each sample:
 * - picks levels from the increment per sample m (cycles, or source samples
 *   in sample mode): the first level k with m <= hi[k], crossfaded linearly
 *   into level k + 1 while m is above lo[k];
 * - in each level, blends the two frames around the scan position (0..1)
 *   tap by tap and interpolates between samples (none, linear, cubic,
 *   Niemitalo's optimal 4-point 4th-order for 4x oversampling, or the
 *   Kaiser-windowed sinc of Wavetable::SINC_KERNEL).
 *
 * Complex levels interpolate their real and imaginary parts separately with
 * the same real arithmetic.  The Ruby mirrors (MB::Sound::Wavetable::
 * KernelRuby) do the same operations in the same order, and the extension
 * is built with -ffp-contract=off, so both give identical samples.
 */
#include <math.h>
#include <complex.h>

#include <ruby.h>

#include "numo/narray.h"
#include "mb_ext_helpers.h"
#include "mb_wavetable.h"

static VALUE ruby_oscillate(int argc, VALUE *argv, VALUE self)
{
	if (argc != 14 && argc != 16) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 14 or 16)", argc);
	}
	VALUE buffer = argv[0], spec = argv[1], frequency = argv[2], advance = argv[3], gain = argv[4], offset = argv[5];
	VALUE state = argv[6], tstate = argv[7], phase_mod = argv[8], width = argv[9], scan = argv[10];
	VALUE interp = argv[11], remove_dc = argv[12], sinc = argv[13];
	VALUE random_advance = argc > 14 ? argv[14] : Qnil;
	VALUE noise = argc > 15 ? argv[15] : Qnil;

	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0) {
		rb_raise(rb_eArgError, "FastWavetable.oscillate needs a cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(interp, sinc, &t, &ks);

	struct mb_wt_osc_state st;
	st.phi = wt_read_state(state, 1, "Phase state");
	mb_grid_phase_read(state, &st.grid);
	wt_read_state(tstate, 5, "Wavetable state");
	double adv = NUM2DBL(advance);
	double rndadv = NIL_P(random_advance) ? 0 : NUM2DBL(random_advance);
	st.rng = 0;
	if (rndadv != 0) {
		Check_Type(noise, T_ARRAY);
		if (RARRAY_LEN(noise) != 1) {
			rb_raise(rb_eArgError, "Noise state must have exactly one Integer element");
		}
		st.rng = NUM2ULL(rb_ary_entry(noise, 0));
	}
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	struct mb_signal f, p, w, sc;
	mb_signal_input(&frequency, length, "Frequency", &f);
	mb_signal_input(&phase_mod, length, "Phase modulation", &p);
	_Bool warped = !NIL_P(width);
	if (!warped) {
		width = DBL2NUM(0.5);
	}
	mb_signal_input(&width, length, "Width", &w);
	mb_signal_input(&scan, length, "Scan", &sc);

	st.primed = NUM2INT(rb_ary_entry(tstate, 2)) != 0;
	st.prev_pm = NUM2DBL(rb_ary_entry(tstate, 1));
	st.prev_e = NUM2DBL(rb_ary_entry(tstate, 3));
	st.prev_inc = NUM2DBL(rb_ary_entry(tstate, 4));
	mb_wt_read_corner_state(tstate, &st);

	mb_wt_oscillate(&t, mode, &ks, out, length, &f, &p, &w, warped, &sc, adv, rndadv, g, off, RTEST(remove_dc), &st);

	if (rndadv != 0) {
		rb_ary_store(noise, 0, ULL2NUM(st.rng));
	}
	rb_ary_store(state, 0, rb_float_new(st.phi));
	if (!isnan(st.grid.inc)) {
		mb_grid_phase_write(state, &st.grid);
	}
	if (length > 0) {
		rb_ary_store(tstate, 1, rb_float_new(st.prev_pm));
		rb_ary_store(tstate, 2, INT2NUM(1));
		rb_ary_store(tstate, 3, rb_float_new(st.prev_e));
		rb_ary_store(tstate, 4, rb_float_new(st.prev_inc));
		mb_wt_write_corner_state(tstate, &st);
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(noise);
	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(frequency);
	RB_GC_GUARD(phase_mod);
	RB_GC_GUARD(width);
	RB_GC_GUARD(scan);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Phase-driven wavetable lookup (see Wavetable#lookup):
 *   lookup(buffer, spec, phase, increments, scan, interpolation, wrap, sinc,
 *          lstate)
 *
 * Reads the table at +phase+ (cycles), handling phases outside 0...1 by
 * +wrap+: 0 wrap, 1 bounce, 2 clamp, 3 zero, or 4 shape (the phase is a
 * signal from -1 to 1 spread across the whole cycle, clamped at the ends).
 *
 * Levels follow |increments| (cycles per sample; false for 0, the
 * brightest level).  With nil increments the speed comes from the phase
 * itself: the change from the previous sample (wrapped to -0.5..0.5 for
 * :wrap, halved for :shape), whose peak is held for WT_HOLD samples and
 * then released by WT_RELEASE per sample.  +lstate+ is [last phase,
 * primed, held peak, hold samples left].
 */
static VALUE ruby_lookup(VALUE self, VALUE buffer, VALUE spec, VALUE phase, VALUE increments, VALUE scan, VALUE interp, VALUE wrap, VALUE sinc, VALUE lstate)
{
	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0) {
		rb_raise(rb_eArgError, "FastWavetable.lookup needs a cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(interp, sinc, &t, &ks);
	int wrapmode = NUM2INT(wrap);
	if (wrapmode < WT_WRAP || wrapmode > WT_SHAPE) {
		rb_raise(rb_eArgError, "Invalid wrapping mode code %d", wrapmode);
	}

	_Bool automatic = NIL_P(increments);
	double prev = 0, peak = 0;
	long hold = 0;
	_Bool primed = 0;
	if (automatic) {
		Check_Type(lstate, T_ARRAY);
		if (RARRAY_LEN(lstate) != 4) {
			rb_raise(rb_eArgError, "Lookup state must have four elements");
		}
		prev = NUM2DBL(rb_ary_entry(lstate, 0));
		primed = NUM2INT(rb_ary_entry(lstate, 1)) != 0;
		peak = NUM2DBL(rb_ary_entry(lstate, 2));
		hold = NUM2LONG(rb_ary_entry(lstate, 3));
	}

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double ph;
	const float *phptr = NULL;
	size_t phptr_step = 1;
	mb_read_signal_input(&phase, length, "Phase", &ph, &phptr, &phptr_step);

	double inc = 0;
	const float *incptr = NULL;
	size_t incptr_step = 1;
	if (!automatic && increments != Qfalse) {
		mb_read_signal_input(&increments, length, "Increments", &inc, &incptr, &incptr_step);
	}

	double sc;
	const float *scptr = NULL;
	size_t scptr_step = 1;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr, &scptr_step);

	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (phptr) ph = phptr[i * phptr_step];
		if (incptr) inc = incptr[i * incptr_step];
		if (scptr) sc = scptr[i * scptr_step];

		double m;
		if (automatic) {
			double d = 0;
			if (primed) {
				d = ph - prev;
				if (wrapmode == WT_WRAP) {
					d = d - wt_floor(d + 0.5);
				} else if (wrapmode == WT_SHAPE) {
					d = d * 0.5;
				}
				d = fabs(d);
			}
			if (d >= peak) {
				peak = d;
				hold = WT_HOLD;
			} else if (hold > 0) {
				hold--;
			} else {
				double r = peak * WT_RELEASE;
				peak = r > d ? r : d;
			}
			prev = ph;
			primed = 1;
			m = peak;
		} else {
			m = fabs(inc);
		}

		double u;
		switch (wrapmode) {
			case WT_WRAP:
				u = wt_wrap(ph, 1.0);
				break;
			case WT_BOUNCE: {
				double b = wt_wrap(ph, 2.0);
				u = b > 1 ? 2.0 - b : b;
				break;
			}
			case WT_CLAMP:
				u = ph < 0 ? 0.0 : (ph > 1 ? 1.0 : ph);
				break;
			case WT_SHAPE:
				u = (ph + 1.0) * 0.5;
				u = u < 0 ? 0.0 : (u > 1 ? 1.0 : u);
				break;
			default:
				if (ph < 0 || ph >= 1) {
					wt_store(out, t.cs, i, 0, 0, 1, 0);
					continue;
				}
				u = ph;
				break;
		}

		double re, im;
		wt_reselect(&t, m, sc, &sel);
		wt_value_dispatch(&t, u, &sel, mode, &ks, &re, &im);
		wt_store(out, t.cs, i, re, im, 1, 0);
	}

	if (automatic && length > 0) {
		rb_ary_store(lstate, 0, rb_float_new(prev));
		rb_ary_store(lstate, 1, INT2NUM(1));
		rb_ary_store(lstate, 2, rb_float_new(peak));
		rb_ary_store(lstate, 3, LONG2NUM(hold));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(phase);
	RB_GC_GUARD(increments);
	RB_GC_GUARD(scan);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Sample-mode player (see Wavetable#play):
 *   play(buffer, spec, frequency, advance, speed, gain, offset, state,
 *        tstate, interpolation, sinc)
 *
 * The position in source samples (tstate[0]) advances by frequency * speed
 * per sample (positions within a buffer are the start plus a running sum,
 * like the phase), wrapping back into the loop (if any) when it reaches
 * the loop's end; the phase in state[0] advances by frequency * advance as
 * for any tone.  Positions outside the sound read silence.
 */
// Wraps source position +p+ back into table +t+'s loop (if any) once it
// reaches the loop's end (FastWavetable.play).
static inline double wt_loop_position(const struct wt_table *t, double p)
{
	if (t->has_loop && p >= t->loop_end) {
		p = t->loop_start + wt_wrap(p - t->loop_start, t->loop_end - t->loop_start);
	}
	return p;
}

static VALUE ruby_play(VALUE self, VALUE buffer, VALUE spec, VALUE frequency, VALUE advance, VALUE speed,
		VALUE gain, VALUE offset, VALUE state, VALUE tstate, VALUE interp, VALUE sinc)
{
	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 1) {
		rb_raise(rb_eArgError, "FastWavetable.play needs a sample-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(interp, sinc, &t, &ks);

	double phi = wt_read_state(state, 1, "Phase state");
	double pos = wt_read_state(tstate, 3, "Wavetable state");
	double adv = NUM2DBL(advance);
	double spd = NUM2DBL(speed);
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	const float *freqptr = NULL;
	size_t freqptr_step = 1;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqptr_step);

	_Bool constant = !freqptr;
	if (!constant) {
		phi = mb_wrap_phase(phi); // a running phase and position (see mb_phase.h)
	}

	// A constant frequency counts the phase and the position from their
	// grids (see mb_phase.h; the position's in tstate[8..10], after the
	// entries cycle-mode tables use)
	struct mb_grid_phase grid = { NAN, NAN, NAN }, pgrid = { NAN, NAN, NAN };
	if (constant) {
		mb_grid_phase_read(state, &grid);
		mb_grid_phase_start(&grid, phi, freq * adv);

		double sp = freq * spd;
		pgrid.base = pgrid.k = pgrid.inc = NAN;
		if (RARRAY_LEN(tstate) >= 11) {
			VALUE b = rb_ary_entry(tstate, 8), k = rb_ary_entry(tstate, 9), inc = rb_ary_entry(tstate, 10);
			if (RB_FLOAT_TYPE_P(b) && RB_FLOAT_TYPE_P(k) && RB_FLOAT_TYPE_P(inc)) {
				pgrid.base = RFLOAT_VALUE(b);
				pgrid.k = RFLOAT_VALUE(k);
				pgrid.inc = RFLOAT_VALUE(inc);
			}
		}
		if (!(pgrid.inc == sp && pgrid.k >= 0 && pgrid.k < MB_PHASE_GRID && wt_loop_position(&t, pgrid.base + sp * pgrid.k) == pos)) {
			pgrid.base = pos;
			pgrid.k = 0;
			pgrid.inc = sp;
		}
	}
	struct wt_sel sel = { .valid = 0 };
	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = freqptr[i * freqptr_step];

		double inc = freq * adv;
		double sp = freq * spd;

		double p = wt_loop_position(&t, constant ? pgrid.base + pgrid.inc * pgrid.k : pos);

		double re, im;
		wt_reselect(&t, fabs(sp), 0, &sel);
		wt_value_dispatch(&t, p, &sel, mode, &ks, &re, &im);
		wt_store(out, t.cs, i, re, im, g, off);

		if (constant) {
			mb_grid_phase_next(&grid);
			pgrid.k += 1.0;
			if (pgrid.k >= MB_PHASE_GRID) {
				pgrid.base = wt_loop_position(&t, pgrid.base + pgrid.inc * MB_PHASE_GRID);
				pgrid.k = 0;
			}
		} else {
			phi = mb_wrap_phase(phi + inc);
			pos = p + sp;
		}
	}

	double p;
	if (constant) {
		rb_ary_store(state, 0, rb_float_new(mb_grid_phase_now(&grid)));
		mb_grid_phase_write(state, &grid);
		p = wt_loop_position(&t, pgrid.base + pgrid.inc * pgrid.k);
		rb_ary_store(tstate, 8, rb_float_new(pgrid.base));
		rb_ary_store(tstate, 9, rb_float_new(pgrid.k));
		rb_ary_store(tstate, 10, rb_float_new(pgrid.inc));
	} else {
		rb_ary_store(state, 0, rb_float_new(wt_wrap(phi, 1.0)));
		p = wt_loop_position(&t, pos);
	}
	rb_ary_store(tstate, 0, rb_float_new(p));
	if (length > 0) {
		rb_ary_store(tstate, 2, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(frequency);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Hard and soft sync for cycle-mode tables, band-limited like
 * FastSynth.oscillate_sync: a sync pulse v at a sample resets the phase
 * (hard) or reverses its direction (soft) 1 - |v| samples earlier.  The
 * output is the naive synced waveform filtered by the minBLEP's minimum-
 * phase lowpass h, exactly, harmonic by harmonic.
 *
 * A table is a sum of harmonics, so between events each harmonic h is a
 * complex exponential A e^(2 pi i (h u + G s)) (A its complex amplitude, u
 * the warped phase in cycles, G = h g its frequency in cycles per sample,
 * g the fundamental's: the phase velocity times the warp slope).  h
 * applied to it is H(G) times it, so each sample reads the harmonic sums
 * with every harmonic scaled by H(h g) (a phase delay of about 2.8 samples
 * at low frequencies, 3.1 at 0.3 cycles per sample, 3.6 at 0.4) instead of
 * the table's levels.  Switching an exponential on at an event adds the
 * residual E(G, t) e^(2 pi i (h u + G t)) for the next +taps+ samples, and
 * switching one off subtracts it, with E(G, t) = -(integral of h(s)
 * e^(-2 pi i G s) for s > t), so E(G, 0) = -H(G) and E settles exactly on
 * zero: unnormalized residuals, the same as FastSynth's synced sines
 * (BandLimit.sync_sine_table, whose rows store E e^(2 pi i G m1) with m1
 * the delay at low frequencies, so they interpolate well in G).  Every
 * segment then has exactly the area and harmonics of the ideal: no DC
 * drift, at any rate of events (until 2026-10-08 the residuals were
 * normalized by H(G) per harmonic while the reads weren't filtered, which
 * left each switch's transient area behind: a synced one-harmonic table
 * drifted up to 0.21 from the ideal mean in a sweep).
 *
 * Events: sync resets and reversals switch every harmonic from (u0, g0) to
 * (u1, g1); phase warp corners (pwm), crossed at the knee w and the wrap,
 * switch each harmonic from one frequency to the other at the same phase
 * (the warp's slope changes), so warped synced tables are band-limited
 * too (the corners were left naive before, -26 to -44 dB of aliasing).
 *
 * Synced tones read the table's sync levels (Wavetable#kernel_spec with
 * sync: true): every harmonic stays below Wavetable#sync_ceiling, and finely
 * spaced levels crossfade continuously so brightness doesn't step; the
 * levels' weights and frames choose the harmonic amplitudes, read from the
 * spectra (so the interpolation setting doesn't matter when band-limited).
 * Complex tables correct their real and imaginary parts alike (the ring
 * holds taps real corrections, then taps imaginary).
 */

// Rows per cycle per sample of BandLimit.sync_sine_table
// (BandLimit::SYNC_SINE_ROWS_PER_CYCLE; SYNC_SINE_ROWS_PER_CYCLE in
// fast_synth.c).
#define WT_E_ROWS_PER_CYCLE 256

// BandLimit.sync_sine_table: +rows+ rows of +len+ complex values (re, im
// interleaved) for t = 0 to +taps+ samples at +os+ points per sample, and
// the delay m1 its rows are rotated by.
struct wt_etab {
	const double *e;
	size_t rows, len, os, taps;
	double m1;
	double *e0; // the rows at t = 0 (re, im interleaved), for the steady sums
};

// The gain of harmonic +h+ in a level with +harmonics+ harmonics (1, or 0
// above them).
static inline double wt_harmonic_gain(long h, long harmonics)
{
	return h > harmonics ? 0.0 : 1.0;
}

// The harmonics a synced tone plays with the levels and frames of +sel+:
// the highest harmonic, and per harmonic h its complex amplitude (the
// frames' spectra blended by the scan, times the levels' weights) through
// wt_amp.
struct wt_harms {
	long hmax, ha, hb;
	double x;
	_Bool two;
	const double *ca, *cb;
	double fs;
};

static inline void wt_harms_of(const struct wt_table *t, const struct wt_sel *sel, struct wt_harms *hs)
{
	hs->ha = t->harmonics[sel->k];
	hs->hb = sel->two ? t->harmonics[sel->k + 1] : 0;
	hs->hmax = hs->ha > hs->hb ? hs->ha : hs->hb;
	hs->two = sel->two;
	hs->x = sel->two ? sel->x : 0.0;
	hs->ca = t->spectra + sel->fa * t->spec_cols * 2;
	hs->cb = sel->fb < 0 ? NULL : t->spectra + sel->fb * t->spec_cols * 2;
	hs->fs = sel->fs;
}

// Harmonic +h+'s complex amplitude into *ar/*ai; returns 0 if its weight
// is 0 (the amplitude is then left unset).
static inline int wt_amp(const struct wt_harms *hs, long h, double *ar, double *ai)
{
	double wgt = hs->two ?
		(1.0 - hs->x) * wt_harmonic_gain(h, hs->ha) + hs->x * wt_harmonic_gain(h, hs->hb) :
		wt_harmonic_gain(h, hs->ha);
	if (wgt == 0) {
		return 0;
	}

	double cr = hs->ca[2 * h];
	double ci = hs->ca[2 * h + 1];
	if (hs->cb) {
		cr = cr * (1.0 - hs->fs) + hs->cb[2 * h] * hs->fs;
		ci = ci * (1.0 - hs->fs) + hs->cb[2 * h + 1] * hs->fs;
	}
	*ar = cr * wgt;
	*ai = ci * wgt;
	return 1;
}

// The DC value (column 0) of the frames of +hs+ (real and imaginary).
static inline void wt_dc(const struct wt_harms *hs, double *re, double *im)
{
	double cr = hs->ca[0];
	double ci = hs->ca[1];
	if (hs->cb) {
		cr = cr * (1.0 - hs->fs) + hs->cb[0] * hs->fs;
		ci = ci * (1.0 - hs->fs) + hs->cb[1] * hs->fs;
	}
	*re = cr;
	*im = ci;
}

// Adds the residual of one harmonic's exponential, of complex amplitude
// (ar, ai) at phase e^(2 pi i h (u + g (t - m1))) = (zr, zi) and frequency
// +gh+ = h g (below the table's last row), switched on +t+ samples (0 to
// 1) before the ring's current sample (at +pos+), rotating by (sr, si) =
// e^(2 pi i gh) per tap.  The table E e^(2 pi i G m1) is read at t + j for
// taps j, interpolated linearly in frequency and time (as sync_sine_lookup
// in fast_synth.c does; 0 past the table), with the row and the fraction
// between table points found once (index t * os + j * os, fraction t * os - floor(t * os)).
static inline void wt_e_add(double *acc, size_t pos, const struct wt_etab *et, int cs, double t, double gh,
		double ar, double ai, double zr, double zi, double sr, double si)
{
	double are = ar * zr - ai * zi;
	double aim = ar * zi + ai * zr;
	double cr = 1.0, ci = 0.0;
	size_t taps = et->taps, os = et->os;
	size_t lim = taps * os;

	double gr = fabs(gh) * WT_E_ROWS_PER_CYCLE;
	size_t r = (size_t)gr;
	double fg = gr - r;
	double x0 = t * os;
	size_t i0 = (size_t)x0;
	double ft = x0 - i0;
	double sgn = gh < 0 ? -1.0 : 1.0;
	const double *e0 = et->e + r * et->len * 2;
	const double *e1 = e0 + et->len * 2;
	size_t k = pos;

	for (size_t j = 0; j < taps; j++) {
		size_t idx = i0 + j * os;
		if (idx >= lim) {
			break;
		}
		const double *p0 = e0 + idx * 2;
		const double *p1 = e1 + idx * 2;
		double a0 = p0[0] + (p0[2] - p0[0]) * ft;
		double a1 = p0[1] + (p0[3] - p0[1]) * ft;
		double b0 = p1[0] + (p1[2] - p1[0]) * ft;
		double b1 = p1[1] + (p1[3] - p1[1]) * ft;
		double er = a0 + (b0 - a0) * fg;
		double ei = (a1 + (b1 - a1) * fg) * sgn;

		double qr = er * cr - ei * ci;
		double qi = er * ci + ei * cr;
		acc[k] += are * qr - aim * qi;
		if (cs == 2) {
			acc[taps + k] += are * qi + aim * qr;
		}

		double nr = cr * sr - ci * si;
		ci = cr * si + ci * sr;
		cr = nr;

		k++;
		if (k == taps) {
			k = 0;
		}
	}
}

// Adds the residuals of an event +t+ samples before the current sample
// (0 <= t <= 1): every harmonic of +hs+ switches off at warped phase +u0+
// and fundamental frequency +g0+ and on at +u1+ and +g1+ (cycles per
// sample, signed).  Harmonics past the residual table (G above
// BandLimit::SYNC_SINE_MAX, where H is -107 dB) are left out, as in the
// sample values.
static void wt_switch(double *acc, size_t pos, const struct wt_etab *et, int cs, const struct wt_harms *hs, double t,
		double u0, double g0, double u1, double g1)
{
	double gmax = (double)(et->rows - 1) / WT_E_ROWS_PER_CYCLE;
	_Bool same = g0 == g1;

	// Per harmonic h: e^(2 pi i h (u + g (t - m1))) and e^(2 pi i h g), by
	// recurrence from h = 1
	double p0 = WT_TWO_PI * (u0 + g0 * (t - et->m1)), p1 = WT_TWO_PI * (u1 + g1 * (t - et->m1));
	double b0r = cos(p0), b0i = sin(p0), b1r = cos(p1), b1i = sin(p1);
	double d0r = cos(WT_TWO_PI * g0), d0i = sin(WT_TWO_PI * g0);
	double d1r = cos(WT_TWO_PI * g1), d1i = sin(WT_TWO_PI * g1);
	double z0r = 1.0, z0i = 0.0, z1r = 1.0, z1i = 0.0;
	double s0r = 1.0, s0i = 0.0, s1r = 1.0, s1i = 0.0;

	for (long h = 1; h <= hs->hmax; h++) {
		double nr = z0r * b0r - z0i * b0i;
		z0i = z0r * b0i + z0i * b0r;
		z0r = nr;
		nr = z1r * b1r - z1i * b1i;
		z1i = z1r * b1i + z1i * b1r;
		z1r = nr;
		nr = s0r * d0r - s0i * d0i;
		s0i = s0r * d0i + s0i * d0r;
		s0r = nr;
		nr = s1r * d1r - s1i * d1i;
		s1i = s1r * d1i + s1i * d1r;
		s1r = nr;

		double ar, ai;
		if (!wt_amp(hs, h, &ar, &ai)) {
			continue;
		}

		double hf = (double)h;
		if (same) {
			if (fabs(hf * g1) >= gmax) {
				continue;
			}
			// One lookup for both: A (z1 - z0) E(G, t + j) ...
			wt_e_add(acc, pos, et, cs, t, hf * g1, ar, ai, z1r - z0r, z1i - z0i, s1r, s1i);
		} else {
			if (fabs(hf * g1) < gmax) {
				wt_e_add(acc, pos, et, cs, t, hf * g1, ar, ai, z1r, z1i, s1r, s1i);
			}
			if (fabs(hf * g0) < gmax) {
				wt_e_add(acc, pos, et, cs, t, hf * g0, -ar, -ai, z0r, z0i, s0r, s0i);
			}
		}
	}
}

// The warped phase of +p+ for width +w+, and the warp's slope there.
static inline double wt_warp_slope(double p, double w, double *k)
{
	if (w == 0.5) {
		*k = 1.0;
		return p;
	}
	*k = p < w ? 0.5 / w : 0.5 / (1.0 - w);
	return p < w ? p * (0.5 / w) : 0.5 + (p - w) * (0.5 / (1.0 - w));
}

// If moving from phase +p+ by +move+ cycles crosses the warp corner at
// phase +c+ (the knee w or the wrap 0), returns the crossing time as a
// fraction of the move, else -1.  A phase on a corner is on its right side
// (the segment after it going forward), as the warp's slope is chosen
// there: a forward move starting on +c+ doesn't cross it and one ending on
// it does; a backward move starting on +c+ crosses it at once (0) and one
// ending on it doesn't.
static inline double wt_corner_crossing(double p, double move, double c)
{
	double ad = fabs(move);
	if (move == 0 || ad >= 1.0) {
		return -1;
	}

	double dist = move > 0 ? c - p : p - c;
	if (dist < 0) {
		dist += 1.0;
	}

	if (move > 0) {
		return dist > 0 && dist <= ad ? dist / ad : -1;
	}
	return dist < ad ? dist / ad : -1;
}

// Moves phase *p by +vel+ cycles per sample for +dur+ samples, ending
// +end_t+ samples before the current sample; with a warp (+w+ not 0.5) and
// band-limiting, each warp corner crossed switches every harmonic from one
// frequency to the other at the corner's phase (see wt_switch).
static inline void wt_sync_move(const struct wt_etab *et, const struct wt_harms *hs, double *p, double vel, double dur,
		double end_t, double w, _Bool bl, double *acc, size_t pos, int cs)
{
	double move = vel * dur;
	if (bl && w != 0.5 && move != 0) {
		double k1 = 0.5 / w, k2 = 0.5 / (1.0 - w);
		for (int j = 0; j < 2; j++) {
			double c = j == 0 ? w : 0.0;
			double f = wt_corner_crossing(*p, move, c);
			if (f < 0) {
				continue;
			}

			// Slopes on the corner's left and right sides, and its
			// warped phase (0.5 at the knee; the wrap as 0)
			double kl = j == 0 ? k1 : k2;
			double kr = j == 0 ? k2 : k1;
			double u = j == 0 ? 0.5 : 0.0;
			double k0 = move > 0 ? kl : kr;
			double kn = move > 0 ? kr : kl;
			double te = end_t + (1.0 - f) * dur;
			wt_switch(acc, pos, et, cs, hs, te, u, vel * k0, u, vel * kn);
		}
	}

	*p = wt_wrap(*p + move, 1.0);
}

// Independent Clenshaw chains of wt_steady (harmonics h = r + WT_CHAINS k).
#define WT_CHAINS 4

// The harmonic sums at warped phase +u+ for fundamental frequency +g+,
// every harmonic scaled by H(h g) (see the top): the DC plus the sums of
// coef[h] e^(2 pi i h (u - g m1)), with coef[h] = -A_h E(h g, 0)
// e^(2 pi i h g m1) recomputed by wt_steady_coefs when +g+ or the
// selection changes (+coef+ holds 2 * (hmax + WT_CHAINS + 1) doubles; the
// entries past hmax are zeroed for the chains).
static void wt_steady_coefs(const struct wt_etab *et, const struct wt_harms *hs, double g, double *coef)
{
	// E(h g, 0) e^(2 pi i h g m1) as the table reads at t = 0, from
	// the compact copy of the rows' first points (the rows themselves are
	// 32 KB apart)
	double rmax = (double)(et->rows - 1);
	const double *e0 = et->e0;
	for (long h = 1; h <= hs->hmax; h++) {
		double ar, ai;
		double gh = (double)h * g;
		double gr = fabs(gh) * WT_E_ROWS_PER_CYCLE;
		if (gr >= rmax || !wt_amp(hs, h, &ar, &ai)) {
			coef[2 * h] = 0.0;
			coef[2 * h + 1] = 0.0;
			continue;
		}
		size_t r = (size_t)gr;
		double fg = gr - r;
		double er = e0[2 * r] + (e0[2 * r + 2] - e0[2 * r]) * fg;
		double ei = e0[2 * r + 1] + (e0[2 * r + 3] - e0[2 * r + 1]) * fg;
		if (gh < 0) {
			ei = -ei;
		}
		coef[2 * h] = -(ar * er - ai * ei);
		coef[2 * h + 1] = -(ar * ei + ai * er);
	}
	for (long h = hs->hmax + 1; h <= hs->hmax + WT_CHAINS; h++) {
		coef[2 * h] = 0.0;
		coef[2 * h + 1] = 0.0;
	}
}

// Sums coef[h] e^(i h psi) for h = 1 to +hmax+ by Clenshaw's recurrence
// in WT_CHAINS interleaved chains (harmonics r + WT_CHAINS k for r = 1 to
// WT_CHAINS, each a sum over k of a_k e^(i k theta), theta = WT_CHAINS psi:
// b_k = (a_k - b_(k+2)) + 2 cos(theta) b_(k+1), sum a_0 + b_1 e^(i theta) -
// b_2, times e^(i r psi)), so the dependency chains are short and run side
// by side (about 1 ns per harmonic instead of 4 for rotating e^(i h psi)).
static inline void wt_steady(const struct wt_etab *et, const struct wt_harms *hs, const double *coef, double u, double g, int cs,
		double *re, double *im)
{
	double dr, di;
	wt_dc(hs, &dr, &di);

	double psi = WT_TWO_PI * (u - g * et->m1);
	double c1 = cos(psi), s1 = sin(psi);

	// e^(i r psi) for r = 1..4, and e^(i theta)
	double er[WT_CHAINS + 1], ei[WT_CHAINS + 1];
	er[1] = c1;
	ei[1] = s1;
	for (int r = 2; r <= WT_CHAINS; r++) {
		er[r] = er[r - 1] * c1 - ei[r - 1] * s1;
		ei[r] = er[r - 1] * s1 + ei[r - 1] * c1;
	}
	double tc = er[WT_CHAINS], ts = ei[WT_CHAINS];
	double x = 2.0 * tc;

	long kmax = hs->hmax >= 1 ? (hs->hmax - 1) / WT_CHAINS : -1;
	double b1r[WT_CHAINS] = { 0 }, b1i[WT_CHAINS] = { 0 }, b2r[WT_CHAINS] = { 0 }, b2i[WT_CHAINS] = { 0 };
	for (long k = kmax; k >= 1; k--) {
		const double *a = coef + 2 * (1 + WT_CHAINS * k);
		for (int r = 0; r < WT_CHAINS; r++) {
			double nr = (a[2 * r] - b2r[r]) + x * b1r[r];
			double ni = (a[2 * r + 1] - b2i[r]) + x * b1i[r];
			b2r[r] = b1r[r];
			b2i[r] = b1i[r];
			b1r[r] = nr;
			b1i[r] = ni;
		}
	}

	double sr = 0.0, si = 0.0;
	if (kmax >= 0) {
		for (int r = 0; r < WT_CHAINS; r++) {
			// a_0 + b_1 e^(i theta) - b_2, times e^(i (r + 1) psi)
			double qr = coef[2 * (r + 1)] + (b1r[r] * tc - b1i[r] * ts) - b2r[r];
			double qi = coef[2 * (r + 1) + 1] + (b1r[r] * ts + b1i[r] * tc) - b2i[r];
			sr += qr * er[r + 1] - qi * ei[r + 1];
			si += qr * ei[r + 1] + qi * er[r + 1];
		}
	}

	*re = dr + sr;
	*im = cs == 2 ? di + si : 0.0;
}

/*
 * A synced wavetable oscillator (see Wavetable#sync):
 *   sync(buffer, spec, frequency, advance, gain, offset, sync_state, ring,
 *        pulses, soft, width, scan, interpolation, remove_dc, sine_table,
 *        m1, oversample, taps, band_limit, sinc, reset_phase = nil)
 *
 * +sync_state+ is as for FastSynth.oscillate_sync ([phase, last increment,
 * direction, ring position, primed]); +ring+ is a DFloat of +taps+ pending
 * corrections (twice that for complex tables).  +sine_table+ and +m1+ are
 * BandLimit.sync_tables(:sine)'s residual table and delay (see the top);
 * +band_limit+ false reads the table's levels with no filtering or
 * residuals (naive sync).  +spec+ is normally the table's sync spec
 * (Wavetable#kernel_spec with sync: true); band-limiting needs its spectra.
 * +reset_phase+ (cycles, nil for 0) is where hard sync events put the
 * phase (Tone resets of complex shapes played through this kernel).
 */
static VALUE ruby_sync(int argc, VALUE *argv, VALUE self)
{
	if (argc != 20 && argc != 21) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 20..21)", argc);
	}
	double reset_phase = argc > 20 && !NIL_P(argv[20]) ? NUM2DBL(argv[20]) : 0.0;

	VALUE buffer = argv[0], spec = argv[1], frequency = argv[2], sync_state = argv[6], ring = argv[7];
	VALUE pulses = argv[8], width = argv[10], scan = argv[11], sine_v = argv[14], sinc = argv[19];

	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0) {
		rb_raise(rb_eArgError, "FastWavetable.sync needs a cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(argv[12], sinc, &t, &ks);
	int cs = t.cs;

	double adv = NUM2DBL(argv[3]);
	double g = NUM2DBL(argv[4]);
	double off = NUM2DBL(argv[5]);
	_Bool soft = RTEST(argv[9]);
	_Bool warped = !NIL_P(width);
	_Bool dc = RTEST(argv[13]) && warped;
	double m1 = NUM2DBL(argv[15]);
	size_t os = NUM2SIZET(argv[16]);
	size_t taps = NUM2SIZET(argv[17]);
	_Bool bl = RTEST(argv[18]);
	if (bl && t.spectra == NULL) {
		rb_raise(rb_eArgError, "A band-limited synced table needs its spectra (Wavetable#kernel_spec with sync: true)");
	}

	Check_Type(sync_state, T_ARRAY);
	if (RARRAY_LEN(sync_state) != 5) {
		rb_raise(rb_eArgError, "Sync state must have five elements");
	}
	double p = NUM2DBL(rb_ary_entry(sync_state, 0));
	double prev_inc = NUM2DBL(rb_ary_entry(sync_state, 1));
	double dir = NUM2DBL(rb_ary_entry(sync_state, 2));
	size_t pos = NUM2SIZET(rb_ary_entry(sync_state, 3));
	_Bool primed = NUM2INT(rb_ary_entry(sync_state, 4)) != 0;

	if (taps < 1 || taps > WT_MAX_TAPS || os < 1 || CLASS_OF(ring) != numo_cDFloat || RNARRAY_NDIM(ring) != 1 || RNARRAY_SHAPE(ring)[0] != taps * cs || !RTEST(nary_check_contiguous(ring))) {
		rb_raise(rb_eArgError, "Ring must be a contiguous DFloat of taps (complex tables: 2 * taps) elements");
	}
	double *acc = (double *)(nary_get_pointer_for_write(ring) + nary_get_offset(ring));
	pos %= taps;

	size_t table_len = taps * os + 1;
	struct wt_etab et = { 0 };
	if (bl) {
		if (CLASS_OF(sine_v) != numo_cDComplex || RNARRAY_NDIM(sine_v) != 2 || RNARRAY_SHAPE(sine_v)[0] < 2 ||
				RNARRAY_SHAPE(sine_v)[1] != table_len || !RTEST(nary_check_contiguous(sine_v))) {
			rb_raise(rb_eArgError, "The sine residual table must be a contiguous 2D DComplex of [rows (at least 2), taps * oversample + 1]");
		}
		et = (struct wt_etab){
			.e = (const double *)(nary_get_pointer_for_read(sine_v) + nary_get_offset(sine_v)),
			.rows = RNARRAY_SHAPE(sine_v)[0],
			.len = table_len,
			.os = os,
			.taps = taps,
			.m1 = m1,
		};
	}

	_Bool was_inplace;
	wt_ensure_output(&buffer, &t, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	double freq;
	const float *freqptr = NULL;
	size_t freqptr_step = 1;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqptr_step);

	double pulse;
	const float *pulseptr = NULL;
	size_t pulseptr_step = 1;
	mb_read_signal_input(&pulses, length, "Sync", &pulse, &pulseptr, &pulseptr_step);
	if (!pulseptr) {
		pulse = 0;
	}

	double w;
	const float *wptr = NULL;
	size_t wptr_step = 1;
	if (!warped) {
		width = DBL2NUM(0.5);
	}
	mb_read_signal_input(&width, length, "Width", &w, &wptr, &wptr_step);
	w = wt_clamp_width(w);

	double sc;
	const float *scptr = NULL;
	size_t scptr_step = 1;
	mb_read_signal_input(&scan, length, "Scan", &sc, &scptr, &scptr_step);

	struct wt_sel sel = { 0 };
	struct wt_harms hs = { 0 };

	// The steady harmonic coefficients (see wt_steady_coefs), kept while
	// the fundamental's frequency and the selection stay the same (future
	// option: block-interpolate them every 16 samples while gliding)
	double *coef = bl ? ALLOC_N(double, 2 * (t.spec_cols + WT_CHAINS + 1)) : NULL;
	if (bl) {
		et.e0 = ALLOC_N(double, 2 * et.rows);
		for (size_t r = 0; r < et.rows; r++) {
			et.e0[2 * r] = et.e[r * et.len * 2];
			et.e0[2 * r + 1] = et.e[r * et.len * 2 + 1];
		}
	}
	_Bool coef_valid = 0;
	double coef_g = 0;
	struct wt_sel coef_sel = { 0 };

	for (size_t i = 0; i < length; i++) {
		if (freqptr) freq = freqptr[i * freqptr_step];
		if (pulseptr) pulse = pulseptr[i * pulseptr_step];
		if (wptr) w = wt_clamp_width(wptr[i * wptr_step]);
		if (scptr) sc = scptr[i * scptr_step];

		double wf = 1.0;
		if (w != 0.5) {
			double k1 = 0.5 / w;
			double k2 = 0.5 / (1.0 - w);
			wf = k1 > k2 ? k1 : k2;
		}
		double m = fabs(freq * adv) * wf;
		if (bl) {
			wt_reselect(&t, m, sc, &sel);
			wt_harms_of(&t, &sel, &hs);
		}

		// The phase velocity into this sample (for the first sample of an
		// unprimed oscillator, as if it had always run at this frequency)
		double vel = dir * (primed ? prev_inc : freq * adv);

		if (primed) {
			if (pulse != 0) {
				double d = 1.0 - fabs(pulse); // the event is d samples before this sample
				if (d < 0) d = 0;
				if (d > 1) d = 1;

				wt_sync_move(&et, &hs, &p, vel, 1.0 - d, d, w, bl, acc, pos, cs);
				double k0, k1;
				double u0 = wt_warp_slope(p, w, &k0);

				double nvel;
				if (soft) {
					dir = -dir;
					nvel = -vel;
				} else {
					dir = 1.0;
					nvel = prev_inc;
					p = reset_phase;
				}

				if (bl) {
					double u1 = wt_warp_slope(p, w, &k1);
					wt_switch(acc, pos, &et, cs, &hs, d, u0, vel * k0, u1, nvel * k1);
				}
				vel = nvel;

				wt_sync_move(&et, &hs, &p, vel, d, 0, w, bl, acc, pos, cs);
			} else {
				wt_sync_move(&et, &hs, &p, vel, 1.0, 0, w, bl, acc, pos, cs);
			}
		}

		double re, im;
		double k;
		double u = wt_warp_slope(p, w, &k);
		if (bl) {
			double gs = vel * k;
			if (!coef_valid || gs != coef_g || sel.k != coef_sel.k || sel.two != coef_sel.two || sel.x != coef_sel.x ||
					sel.fa != coef_sel.fa || sel.fb != coef_sel.fb || sel.fs != coef_sel.fs) {
				wt_steady_coefs(&et, &hs, gs, coef);
				coef_valid = 1;
				coef_g = gs;
				coef_sel = sel;
			}
			wt_steady(&et, &hs, coef, u, gs, cs, &re, &im);
		} else {
			wt_reselect(&t, m, sc, &sel);
			wt_value_dispatch(&t, u, &sel, mode, &ks, &re, &im);
		}
		re += acc[pos];
		acc[pos] = 0;
		if (cs == 2) {
			im += acc[taps + pos];
			acc[taps + pos] = 0;
		}
		pos = (pos + 1) % taps;

		if (dc) {
			re -= wt_half_mean(&t, sc) * (2.0 * w - 1.0);
		}

		wt_store(out, cs, i, re, im, g, off);

		prev_inc = freq * adv;
		primed = 1;
	}

	if (coef) {
		xfree(coef);
		xfree(et.e0);
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

	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	RB_GC_GUARD(frequency);
	RB_GC_GUARD(pulses);
	RB_GC_GUARD(width);
	RB_GC_GUARD(scan);
	RB_GC_GUARD(ring);
	RB_GC_GUARD(sine_v);
	RB_GC_GUARD(buffer);

	return buffer;
}

// Complex.polar(a, angle) exactly as Ruby computes it for Floats:
// (a, 0.0) for a zero magnitude or angle, (-a, 0.0) at pi, (0.0, a) at pi / 2,
// else a cos and a sin.
static inline void wt_polar(double a, double angle, double *re, double *im)
{
	if (a == 0 || angle == 0) {
		*re = a;
		*im = 0.0;
	} else if (angle == M_PI) {
		*re = -a;
		*im = 0.0;
	} else if (angle == M_PI_2) {
		*re = 0.0;
		*im = a;
	} else {
		*re = a * cos(angle);
		*im = a * sin(angle);
	}
}

/*
 * call-seq: MB::Sound::FastWavetable.harmonic_spectra(out, amplitudes, phases) -> out
 *
 * Fills the zeroed contiguous DComplex +out+ ([rows, harmonics + 1]) with
 * the spectra of sine harmonics: +amplitudes+ and +phases+ (radians, or nil
 * for 0) are Arrays of +rows+ Arrays of Floats (equal lengths per row,
 * checked by the caller), column h is Complex.polar(a, p - pi / 2).  The
 * Ruby mirror is Wavetable::Builder.spectra_from_harmonics_ruby.
 */
static VALUE ruby_harmonic_spectra(VALUE self, VALUE out, VALUE amplitudes, VALUE phases)
{
	Check_Type(amplitudes, T_ARRAY);
	if (!NIL_P(phases)) {
		Check_Type(phases, T_ARRAY);
	}
	long rows = RARRAY_LEN(amplitudes);
	if (CLASS_OF(out) != numo_cDComplex || RNARRAY_NDIM(out) != 2 || !RTEST(nary_check_contiguous(out)) ||
			(long)RNARRAY_SHAPE(out)[0] != rows || (!NIL_P(phases) && RARRAY_LEN(phases) != rows)) {
		rb_raise(rb_eArgError, "Output must be a contiguous DComplex of [rows, harmonics + 1]");
	}
	size_t cols = RNARRAY_SHAPE(out)[1];
	double *o = (double *)(nary_get_pointer_for_write(out) + nary_get_offset(out));

	for (long r = 0; r < rows; r++) {
		VALUE arow = rb_ary_entry(amplitudes, r);
		Check_Type(arow, T_ARRAY);
		VALUE prow = NIL_P(phases) ? Qnil : rb_ary_entry(phases, r);
		if (!NIL_P(prow)) {
			Check_Type(prow, T_ARRAY);
		}
		long n = RARRAY_LEN(arow);
		if ((size_t)n + 1 > cols || (!NIL_P(prow) && RARRAY_LEN(prow) != n)) {
			rb_raise(rb_eArgError, "Row %ld doesn't fit the output", r);
		}

		for (long i = 0; i < n; i++) {
			double a = NUM2DBL(rb_ary_entry(arow, i));
			double p = NIL_P(prow) ? 0.0 : NUM2DBL(rb_ary_entry(prow, i));
			double *c = o + (r * cols + i + 1) * 2;
			wt_polar(a, p - M_PI / 2, c, c + 1);
		}
	}

	RB_GC_GUARD(amplitudes);
	RB_GC_GUARD(phases);
	return out;
}

/*
 * call-seq: MB::Sound::FastWavetable.half_means(out, spectra) -> out
 *
 * Fills the contiguous DFloat +out+ ([rows]) with the half means of the
 * contiguous DComplex +spectra+ ([rows, harmonics + 1]): the sum over odd h
 * of the real part of 2i c_h / (pi h), in harmonic order, with the products
 * as Ruby's Complex arithmetic does them (0 * re is a zero with re's sign).
 * The Ruby mirror is Wavetable::Builder.half_means_ruby.
 */
static VALUE ruby_half_means(VALUE self, VALUE out, VALUE spectra)
{
	if (CLASS_OF(spectra) != numo_cDComplex || RNARRAY_NDIM(spectra) != 2 || !RTEST(nary_check_contiguous(spectra)) ||
			CLASS_OF(out) != numo_cDFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out)) ||
			RNARRAY_SHAPE(out)[0] != RNARRAY_SHAPE(spectra)[0]) {
		rb_raise(rb_eArgError, "Spectra must be a contiguous DComplex [rows, harmonics + 1] and out a DFloat [rows]");
	}
	size_t rows = RNARRAY_SHAPE(spectra)[0], cols = RNARRAY_SHAPE(spectra)[1];
	const double *sp = (const double *)(nary_get_pointer_for_read(spectra) + nary_get_offset(spectra));
	double *o = (double *)(nary_get_pointer_for_write(out) + nary_get_offset(out));

	for (size_t r = 0; r < rows; r++) {
		double sum = 0.0;
		for (size_t h = 1; h < cols; h += 2) {
			double re = sp[(r * cols + h) * 2];
			double im = sp[(r * cols + h) * 2 + 1];
			double z = isnan(re) ? re * 0.0 : copysign(0.0, re);
			sum += (z - 2.0 * im) / (M_PI * (double)h);
		}
		o[r] = sum;
	}

	RB_GC_GUARD(spectra);
	return out;
}

/*
 * The value and slope of a cycle-mode table (Tone#table_shape, for the
 * band-limited steps of phase jumps: key-synced resets):
 *   shape(out, spec, u, m, scan, interpolation, sinc) -> out
 *
 * +out+ is a DFloat of 4 values: [re, im] of the value at +u+ (cycles)
 * moving +m+ cycles per sample at +scan+ (wt_value), then [re, im] of the
 * slope per cycle from the table's harmonics (wt_table_slope).  The Ruby
 * mirror is Wavetable::KernelRuby.value and .spectral_derivs.
 */
static VALUE ruby_shape(VALUE self, VALUE out, VALUE spec, VALUE u_v, VALUE m_v, VALUE scan_v, VALUE interp, VALUE sinc)
{
	struct wt_table t;
	wt_read_table(spec, &t);
	if (t.mode != 0) {
		rb_raise(rb_eArgError, "FastWavetable.shape needs a cycle-mode table");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(interp, sinc, &t, &ks);

	if (CLASS_OF(out) != numo_cDFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out)) || RNARRAY_SIZE(out) < 4) {
		rb_raise(rb_eArgError, "Shape output must be a contiguous DFloat of 4 values");
	}
	if (OBJ_FROZEN(out)) {
		rb_raise(rb_eFrozenError, "Shape output is frozen");
	}
	double *o = (double *)(nary_get_pointer_for_write(out) + nary_get_offset(out));

	double u = NUM2DBL(u_v);
	double m = fabs(NUM2DBL(m_v));
	double sc = NUM2DBL(scan_v);

	double re = 0, im = 0;
	wt_value(&t, u, m, sc, mode, &ks, &re, &im);
	double sre = 0, sim = 0;
	wt_table_slope(&t, u, m, sc, mode, &ks, &sre, &sim);
	o[0] = re;
	o[1] = im;
	o[2] = sre;
	o[3] = sim;

	RB_GC_GUARD(spec);
	RB_GC_GUARD(sinc);
	return out;
}

void Init_fast_wavetable(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_wavetable_module = rb_define_module_under(sound, "FastWavetable");

	rb_define_module_function(fast_wavetable_module, "oscillate", ruby_oscillate, -1);
	rb_define_module_function(fast_wavetable_module, "lookup", ruby_lookup, 9);
	rb_define_module_function(fast_wavetable_module, "play", ruby_play, 11);
	rb_define_module_function(fast_wavetable_module, "sync", ruby_sync, -1);
	rb_define_module_function(fast_wavetable_module, "harmonic_spectra", ruby_harmonic_spectra, 3);
	rb_define_module_function(fast_wavetable_module, "half_means", ruby_half_means, 2);
	rb_define_module_function(fast_wavetable_module, "shape", ruby_shape, 7);
}
