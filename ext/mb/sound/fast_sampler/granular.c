/*
 * MB::Sound::FastSampler.grains: the granular kernel (GraphNode::Grains;
 * see design/notes/granular.md).
 *
 * grains(out_l, out_r, specs, slots, state, rng, window, inputs, config)
 *
 * Plays a cloud of grains from one Sample into +out_l+ and +out_r+
 * (contiguous 1D SFloats of the same length, written in place).  +specs+
 * is an Array of one or two sample-mode Wavetable#kernel_spec Arrays (the
 * sample's channels; a mono sample feeds both outputs), read through
 * mb_wavetable.h with each grain's band-limited levels selected by its
 * speed.
 *
 * +slots+ is a contiguous 2D DFloat with a row of GR_COLS values per grain
 * slot (its row count is the most grains sounding at once), +state+ a
 * DFloat of GR_STATE_LENGTH values (onset phase, interval scale, scan
 * playhead), +rng+ a one-value UInt64 splitmix64 state, +window+ a DFloat
 * of GR_WINDOW + 1 window values (read with linear interpolation).
 *
 * +inputs+ is [trigger, density, size, position, spread, pitch,
 * pitch_spread, pan_spread, reverse, freq, scan, jitter], signal inputs
 * (Numeric, nil, or NArray of out_l.length values read as float32); freq
 * nil means no key tracking.  A grain reads them at its onset sample.
 *
 * +config+ is [sample rate, root Hz, pitch choices (Array of semitones),
 * interpolation code, sinc kernel, normalization (0 none, 1 power: 1 /
 * sqrt(overlap), 2 amplitude: 1 / overlap), the window's mean square (power)
 * or mean (amplitude), region start, region stop, reversed, source rate / output rate,
 * tune semitones, level, longest grain (samples)].
 *
 * Every onset draws exactly six random numbers (position, pitch choice,
 * pitch jitter, pan, reverse, next interval), so one parameter's setting
 * doesn't change the others' draws.  Output is the same at any buffer
 * size.  The Ruby mirror (MB::Sound::Granular::KernelRuby.grains) gives
 * exactly the same samples, so keep the operations identical; built with
 * fast_sampler's -ffp-contract=off.
 */

#include <math.h>
#include <stdint.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_wavetable.h"

#include "granular.h"

// Grain slot columns
enum {
	GR_ACTIVE = 0,
	GR_POS,
	GR_STEP,
	GR_AGE,
	GR_LEN,
	GR_WSTEP,
	GR_GL,
	GR_GR,
	GR_COLS
};

// Global state
enum {
	GS_PHASE = 0,
	GS_Q,
	GS_PLAYHEAD,
	GR_STATE_LENGTH
};

#define GR_WINDOW 1024
#define GR_MAX_SLOTS 256
#define GR_MAX_CHOICES 64
#define GR_MIN_Q 1e-3
#define GR_EPS 1e-9
#define GR_SQRT2 1.4142135623730951
#define GR_QUARTER_PI 0.78539816339744831

struct gr_ctx {
	struct wt_table tables[2];
	int nch;
	int mode;
	struct wt_sinc ks;
	double fs, root_hz, mw2, start, stop, rate, tune, level;
	int normalize;
	_Bool reversed;
	long max_len;
	double choices[GR_MAX_CHOICES];
	long nchoices;
};

static double *gr_dfloat(VALUE v, long length, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || (long)RNARRAY_SHAPE(v)[0] != length) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D DFloat of %ld values", name, length);
	}
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

// Like gr_dfloat, for reading (frozen arrays are fine).
static const double *gr_dfloat_read(VALUE v, long length, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || (long)RNARRAY_SHAPE(v)[0] != length) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D DFloat of %ld values", name, length);
	}
	return (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

static float *gr_out(VALUE v, const char *name)
{
	if (CLASS_OF(v) != numo_cSFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D SFloat (written in place)", name);
	}
	return mb_sfloat_ptr(v);
}

// Starts a grain at sample +i+ in a free row of +slots+ (if any), drawing
// six random numbers and setting the next onset interval scale *q.
static void gr_spawn(const struct gr_ctx *c, double *slots, long nslots, struct wt_sel *sels, uint64_t *rng, double *q,
		double playhead, double density, double size, double position, double spread, double pitch, double pitch_spread,
		double pan_spread, double reverse, _Bool has_freq, double freq, double jitter)
{
	double u1 = wt_noise_random(rng);
	double u2 = wt_noise_random(rng);
	double u3 = wt_noise_random(rng);
	double u4 = wt_noise_random(rng);
	double u5 = wt_noise_random(rng);
	double u6 = wt_noise_random(rng);

	double j = jitter;
	if (j < 0) j = 0;
	if (j > 1) j = 1;
	double nq = (1.0 - j) + j * -log(1.0 - u6);
	if (!(nq >= GR_MIN_Q)) nq = GR_MIN_Q;
	*q = nq;

	long slot = -1;
	for (long k = 0; k < nslots; k++) {
		if (slots[k * GR_COLS + GR_ACTIVE] == 0) {
			slot = k;
			break;
		}
	}
	if (slot < 0) {
		return;
	}

	double p = position + playhead;
	if (p < 0 || p > 1) {
		p = wt_wrap(p, 1.0);
	}
	p = p + spread * (2.0 * u1 - 1.0);
	if (p < 0) p = 0;
	if (p > 1) p = 1;

	double semis = pitch + c->tune;
	if (c->nchoices > 0) {
		long ci = (long)floor(u2 * (double)c->nchoices);
		if (ci >= c->nchoices) ci = c->nchoices - 1;
		semis = semis + c->choices[ci];
	}
	semis = semis + pitch_spread * (2.0 * u3 - 1.0);
	double sp = pow(2.0, semis / 12.0) * c->rate;
	if (has_freq && c->root_hz > 0) {
		sp = sp * (freq / c->root_hz);
	}
	if (!(sp > 1e-6) || !isfinite(sp)) {
		return;
	}

	double ls = floor(size * c->fs + 0.5);
	if (!(ls >= 2)) ls = 2;
	if (ls > (double)c->max_len) ls = (double)c->max_len;
	double len = c->stop - c->start;
	double span = (ls - 1.0) * sp;
	if (span > len - 1.0) {
		ls = floor((len - 1.0) / sp) + 1.0;
		span = (ls - 1.0) * sp;
	}
	if (ls < 2) {
		return;
	}

	double center = c->reversed ? c->stop - p * len : c->start + p * len;
	double a = center - span * 0.5;
	double amax = c->stop - 1.0 - span;
	if (a > amax) a = amax;
	if (a < c->start) a = c->start;

	double dir = c->reversed ? -1.0 : 1.0;
	if (u5 < reverse) {
		dir = -dir;
	}

	double pan = pan_spread * (2.0 * u4 - 1.0);
	if (pan < -1) pan = -1;
	if (pan > 1) pan = 1;
	double ang = (pan + 1.0) * GR_QUARTER_PI;
	double gl = cos(ang) * GR_SQRT2;
	double gr = sin(ang) * GR_SQRT2;

	double g = c->level;
	if (c->normalize != 0) {
		double o = density * (ls / c->fs) * c->mw2;
		if (o > 1) {
			g = c->normalize == 2 ? g / o : g / sqrt(o);
		}
	}

	double *s = slots + slot * GR_COLS;
	s[GR_ACTIVE] = 1;
	s[GR_POS] = dir > 0 ? a : a + span;
	s[GR_STEP] = dir * sp;
	s[GR_AGE] = 0;
	s[GR_LEN] = ls;
	s[GR_WSTEP] = (double)GR_WINDOW / ls;
	s[GR_GL] = gl * g;
	s[GR_GR] = gr * g;

	for (int ch = 0; ch < c->nch; ch++) {
		wt_select(&c->tables[ch], sp, 0, &sels[slot * 2 + ch]);
	}
}

static VALUE ruby_grains(VALUE self, VALUE out_l, VALUE out_r, VALUE specs, VALUE slots_v, VALUE state, VALUE rng, VALUE window,
		VALUE inputs, VALUE config)
{
	Check_Type(specs, T_ARRAY);
	Check_Type(inputs, T_ARRAY);
	Check_Type(config, T_ARRAY);
	if (RARRAY_LEN(inputs) != 12) {
		rb_raise(rb_eArgError, "Grain inputs are [trigger, density, size, position, spread, pitch, pitch_spread, pan_spread, reverse, freq, scan, jitter]");
	}
	if (RARRAY_LEN(config) != 14) {
		rb_raise(rb_eArgError, "Grain config has 14 entries (see granular.c)");
	}
	long nspecs = RARRAY_LEN(specs);
	if (nspecs < 1 || nspecs > 2) {
		rb_raise(rb_eArgError, "Grains read one or two tables (channels)");
	}

	struct gr_ctx c;
	memset(&c, 0, sizeof(c));
	c.nch = (int)nspecs;
	for (int ch = 0; ch < c.nch; ch++) {
		wt_read_table(rb_ary_entry(specs, ch), &c.tables[ch]);
		if (c.tables[ch].mode != 1 || c.tables[ch].has_loop || c.tables[ch].cs != 1) {
			rb_raise(rb_eArgError, "Grain tables must be real sample-mode tables without loops");
		}
	}
	c.mode = wt_read_interp(rb_ary_entry(config, 3), rb_ary_entry(config, 4), &c.tables[0], &c.ks);

	c.fs = NUM2DBL(rb_ary_entry(config, 0));
	c.root_hz = NUM2DBL(rb_ary_entry(config, 1));
	VALUE choices = rb_ary_entry(config, 2);
	Check_Type(choices, T_ARRAY);
	c.nchoices = RARRAY_LEN(choices);
	if (c.nchoices > GR_MAX_CHOICES) {
		rb_raise(rb_eArgError, "At most %d pitch choices", GR_MAX_CHOICES);
	}
	for (long k = 0; k < c.nchoices; k++) {
		c.choices[k] = NUM2DBL(rb_ary_entry(choices, k));
	}
	c.normalize = NUM2INT(rb_ary_entry(config, 5));
	if (c.normalize < 0 || c.normalize > 2) {
		rb_raise(rb_eArgError, "Grain normalization is 0, 1, or 2");
	}
	c.mw2 = NUM2DBL(rb_ary_entry(config, 6));
	c.start = NUM2DBL(rb_ary_entry(config, 7));
	c.stop = NUM2DBL(rb_ary_entry(config, 8));
	c.reversed = RTEST(rb_ary_entry(config, 9));
	c.rate = NUM2DBL(rb_ary_entry(config, 10));
	c.tune = NUM2DBL(rb_ary_entry(config, 11));
	c.level = NUM2DBL(rb_ary_entry(config, 12));
	c.max_len = NUM2LONG(rb_ary_entry(config, 13));
	if (!(c.fs > 0) || c.max_len < 2) {
		rb_raise(rb_eArgError, "Grains need a positive sample rate and a longest grain of at least 2 samples");
	}
	if (!(c.start >= 0) || !(c.stop - c.start >= 2) || c.stop > c.tables[0].end) {
		rb_raise(rb_eArgError, "The grains' region must lie inside the sample and hold at least 2 samples");
	}
	for (int ch = 1; ch < c.nch; ch++) {
		if (c.tables[ch].end != c.tables[0].end || c.tables[ch].nlevels != c.tables[0].nlevels) {
			rb_raise(rb_eArgError, "Grain channel tables must have the same shape");
		}
	}

	if (CLASS_OF(slots_v) != numo_cDFloat || RNARRAY_NDIM(slots_v) != 2 || !RTEST(nary_check_contiguous(slots_v)) ||
			RNARRAY_SHAPE(slots_v)[1] != GR_COLS) {
		rb_raise(rb_eArgError, "Grain slots must be a contiguous 2D DFloat with %d columns", GR_COLS);
	}
	long nslots = (long)RNARRAY_SHAPE(slots_v)[0];
	if (nslots < 1 || nslots > GR_MAX_SLOTS) {
		rb_raise(rb_eArgError, "Grains need 1 to %d slots", GR_MAX_SLOTS);
	}
	double *slots = (double *)(nary_get_pointer_for_write(slots_v) + nary_get_offset(slots_v));
	double *st = gr_dfloat(state, GR_STATE_LENGTH, "Grain state");
	const double *win = gr_dfloat_read(window, GR_WINDOW + 1, "Grain window");
	if (CLASS_OF(rng) != numo_cUInt64 || RNARRAY_SIZE(rng) != 1 || !RTEST(nary_check_contiguous(rng))) {
		rb_raise(rb_eArgError, "The grains' random state must be a one-value contiguous UInt64");
	}
	uint64_t *rs = (uint64_t *)(nary_get_pointer_for_write(rng) + nary_get_offset(rng));

	float *ol = gr_out(out_l, "The left output");
	float *orr = gr_out(out_r, "The right output");
	size_t length = RNARRAY_SHAPE(out_l)[0];
	if ((size_t)RNARRAY_SHAPE(out_r)[0] != length) {
		rb_raise(rb_eArgError, "The grain outputs must be the same length");
	}

	VALUE in[12];
	struct mb_signal sig[12];
	static const char *names[12] = {
		"Trigger", "Density", "Size", "Position", "Spread", "Pitch", "Pitch spread", "Pan spread", "Reverse", "Frequency", "Scan", "Jitter"
	};
	for (int k = 0; k < 12; k++) {
		in[k] = rb_ary_entry(inputs, k);
	}
	_Bool has_freq = !NIL_P(in[9]);
	for (int k = 0; k < 12; k++) {
		mb_signal_input(&in[k], length, names[k], &sig[k]);
	}

	// Each slot's level selection per channel (made again here; a grain's
	// speed is fixed, so it stays valid while the grain plays)
	struct wt_sel sels[GR_MAX_SLOTS * 2];
	for (long k = 0; k < nslots; k++) {
		double *s = slots + k * GR_COLS;
		if (s[GR_ACTIVE] != 0) {
			if (!(s[GR_LEN] >= 2) || !(s[GR_AGE] >= 0) || !(s[GR_AGE] < s[GR_LEN])) {
				rb_raise(rb_eArgError, "Grain slot %ld has a bad age or length", k);
			}
			for (int ch = 0; ch < c.nch; ch++) {
				wt_select(&c.tables[ch], fabs(s[GR_STEP]), 0, &sels[k * 2 + ch]);
			}
		}
	}

	double phase = st[GS_PHASE];
	double q = st[GS_Q];
	double playhead = st[GS_PLAYHEAD];
	if (!(q >= GR_MIN_Q)) q = 1.0;
	double region = c.stop - c.start;

	for (size_t i = 0; i < length; i++) {
		if (mb_signal_at(&sig[0], i) > 0) {
			playhead = 0;
			phase = 1;
		}

		double density = mb_signal_at(&sig[1], i);
		// (onsets within GR_EPS of a sample land on it, so 100 grains per
		// second at 48 kHz land every 480 samples despite rounding)
		if (phase >= 1.0 - GR_EPS) {
			phase = phase - 1.0;
			if (phase < 0) phase = 0;
			if (phase >= 1) phase = 0;
			gr_spawn(&c, slots, nslots, sels, rs, &q, playhead, density, mb_signal_at(&sig[2], i), mb_signal_at(&sig[3], i),
					mb_signal_at(&sig[4], i), mb_signal_at(&sig[5], i), mb_signal_at(&sig[6], i), mb_signal_at(&sig[7], i),
					mb_signal_at(&sig[8], i), has_freq, mb_signal_at(&sig[9], i), mb_signal_at(&sig[11], i));
		}
		if (density > 0) {
			phase = phase + density / (c.fs * q);
		}
		double sc = mb_signal_at(&sig[10], i);
		if (sc != 0) {
			playhead = playhead + sc * c.rate / region;
			if (playhead < 0 || playhead >= 1) {
				playhead = wt_wrap(playhead, 1.0);
			}
		}

		double l = 0;
		double r = 0;
		for (long k = 0; k < nslots; k++) {
			double *s = slots + k * GR_COLS;
			if (s[GR_ACTIVE] == 0) {
				continue;
			}
			double x = s[GR_AGE] * s[GR_WSTEP];
			long ix = (long)x;
			if (ix >= GR_WINDOW) ix = GR_WINDOW - 1;
			double f = x - (double)ix;
			double w = win[ix] + (win[ix + 1] - win[ix]) * f;

			double re, im;
			double p = s[GR_POS];
			wt_value_dispatch(&c.tables[0], p, &sels[k * 2], c.mode, &c.ks, &re, &im);
			double vl = re * w;
			double vr = vl;
			if (c.nch > 1) {
				wt_value_dispatch(&c.tables[1], p, &sels[k * 2 + 1], c.mode, &c.ks, &re, &im);
				vr = re * w;
			}
			l = l + vl * s[GR_GL];
			r = r + vr * s[GR_GR];

			s[GR_POS] = p + s[GR_STEP];
			s[GR_AGE] = s[GR_AGE] + 1;
			if (s[GR_AGE] >= s[GR_LEN]) {
				s[GR_ACTIVE] = 0;
			}
		}

		ol[i] = l;
		orr[i] = r;
	}

	st[GS_PHASE] = phase;
	st[GS_Q] = q;
	st[GS_PLAYHEAD] = playhead;

	for (int k = 0; k < 12; k++) {
		RB_GC_GUARD(in[k]);
	}
	RB_GC_GUARD(specs);

	return out_l;
}

void mb_granular_init(VALUE fast_sampler)
{
	rb_define_module_function(fast_sampler, "grains", ruby_grains, 9);
	rb_define_const(fast_sampler, "GRAIN_COLS", INT2FIX(GR_COLS));
	rb_define_const(fast_sampler, "GRAIN_STATE_LENGTH", INT2FIX(GR_STATE_LENGTH));
	rb_define_const(fast_sampler, "GRAIN_WINDOW", INT2FIX(GR_WINDOW));
	rb_define_const(fast_sampler, "GRAIN_MAX_SLOTS", INT2FIX(GR_MAX_SLOTS));
}
