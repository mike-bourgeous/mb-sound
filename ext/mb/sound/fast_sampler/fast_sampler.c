/*
 * MB::Sound::FastSampler: the sampler voice kernel (GraphNode::Sampler; see
 * design/notes/sampler.md).
 *
 * play(out, specs, regions, state, counters, rng, inputs, config)
 *
 * Plays one channel of one voice into +out+ (a contiguous 1D SFloat,
 * written in place and returned).  +specs+ is an
 * Array of sample-mode Wavetable#kernel_spec Arrays (without loops: the
 * sampler loops by itself), read through mb_wavetable.h, so playback uses
 * the band-limited levels (mipmaps) and interpolators of sample-mode
 * wavetables.  +regions+ is a contiguous 2D DFloat with a row of
 * SMP_REGION_COLS values per region (see the REGION_* indices), picked by
 * note number and velocity (the first that matches).
 *
 * +inputs+ is [trigger, number, freq, gate, start, shift, choke], signal inputs (a
 * Numeric, nil, or an NArray of out.length values read as float32):
 * - trigger: a note-on at every sample above 0, its value the velocity
 *   (0..1; Notes#trigger), so starts are sample-exact.
 * - number: the note number (Notes#number, a Float).
 * - freq: nil, or the voice's frequency in Hz (Notes#freq: pitch bend,
 *   glides), relative to the note's own frequency config[0] * 2^((n - 69) /
 *   12), multiplying the speed every sample.
 * - gate: nil (held) or the note's gate; a release loop stops looping on
 *   the first sample at or below 0.
 * - start: the play start as a fraction of the region (read at note-on).
 * - shift: the note's pitch mark in semitones (Notes#pitch_mark: chop
 *   hits' per-note pitch), read at note-on.
 * - choke: nil, or the voice's chokes (Notes#choke: choke groups, SF2
 *   exclusive classes): at a nonzero sample without a note-on, the voice
 *   stops config[6] samples later (fading out linearly over them when
 *   config[7] is 1, like Drums::ChokeGate; 0 when an envelope fades it);
 *   a note-on cancels the choke, and a choke while choking changes nothing.
 *
 * +config+ is [a4 Hz, declick samples, split key, interpolation code, sinc
 * kernel, transpose semitones, choke samples, choke fade (0 or 1)].  Each region's REGION_INTERP column is its
 * own interpolation code (a lofi Sample's drop-sample read), or -1 for
 * config's; the sinc kernel must be given if any region reads with sinc.  With a split key (-1 for none), notes from
 * it up play the region the voice last played below it, chromatically
 * from the split key (a sampler's split keyboard: slices below, the last
 * slice pitched above).

 * Each note-on moves a sounding note to the tail, which keeps playing at its
 * last speed while fading out linearly over the declick length, so
 * re-struck voices don't click; so at most two notes sound in a voice, and
 * every sample reads at most two positions (two levels each).
 *
 * +state+ is a DFloat of SMP_STATE_LENGTH values (the current note, the
 * tail, the tail's samples left, the region last played below the split,
 * and the choke's samples left), +counters+ a DFloat of 128 note-on
 * counts per key (sequential round robins), +rng+ a one-value UInt64
 * splitmix64 state (one random draw per note-on, for random round robins).
 * All are updated in place.
 *
 * The Ruby mirror (MB::Sound::Sampler::KernelRuby.play) gives exactly the
 * same samples (specs check it), so keep the operations identical; built
 * with -ffp-contract=off.
 */

#include <math.h>
#include <stdint.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_wavetable.h"

#include "granular.h"

enum {
	REGION_TABLE = 0,
	REGION_LOKEY,
	REGION_HIKEY,
	REGION_LOVEL,
	REGION_HIVEL,
	REGION_SEQ_LENGTH,
	REGION_SEQ_POSITION,
	REGION_LORAND,
	REGION_HIRAND,
	REGION_ROOT,
	REGION_KEYTRACK,
	REGION_TUNE,
	REGION_GAIN,
	REGION_START,
	REGION_END,
	REGION_LOOP_START,
	REGION_LOOP_END,
	REGION_LOOP_MODE,
	REGION_REVERSE,
	REGION_FADE_IN,
	REGION_FADE_OUT,
	REGION_VELTRACK,
	REGION_RATE,
	REGION_OFFSET,
	REGION_INTERP, // the region's interpolation code, or -1 for config's
	SMP_REGION_COLS
};

// Loop modes (Sampler::LOOP_MODES)
enum {
	LOOP_NONE = 0,
	LOOP_ONE_SHOT = 1,
	LOOP_FORWARD = 2,
	LOOP_PING_PONG = 3,
	LOOP_RELEASE = 4,
};

// One note's state: SMP_VOICE values in the state array
enum {
	V_ACTIVE = 0,
	V_REGION,
	V_POS,
	V_DIR,
	V_BASE,
	V_GAIN,
	V_NHZ,
	V_INLOOP,
	V_RELEASED,
	V_SPEED,
	SMP_VOICE
};

#define SMP_TAIL_LEFT (2 * SMP_VOICE)
#define SMP_LAST_REGION (2 * SMP_VOICE + 1)
#define SMP_CHOKE_LEFT (2 * SMP_VOICE + 2)
#define SMP_STATE_LENGTH (2 * SMP_VOICE + 3)

struct smp_voice {
	_Bool active;
	long region;
	double pos, dir, base, gain, nhz;
	_Bool inloop, released;
	double speed;
	int slot; // which table slot holds its table
};

struct smp_ctx {
	VALUE specs;
	const double *regions;
	long nregions;
	long split;
	long last_region;
	struct wt_table tables[2];
	struct wt_sel sels[2];
	long loaded[2]; // table index in each slot (-1 none)
	int mode;
	struct wt_sinc ks;
};

static void smp_load(struct smp_ctx *c, int slot, long table)
{
	if (c->loaded[slot] == table) {
		return;
	}
	if (table < 0 || table >= RARRAY_LEN(c->specs)) {
		rb_raise(rb_eArgError, "Sampler region table %ld is out of range", table);
	}
	wt_read_table(rb_ary_entry(c->specs, table), &c->tables[slot]);
	if (c->tables[slot].mode != 1 || c->tables[slot].has_loop || c->tables[slot].cs != 1) {
		rb_raise(rb_eArgError, "Sampler tables must be real sample-mode tables without loops");
	}
	c->loaded[slot] = table;
	c->sels[slot].valid = 0;
}

static void smp_get(const double *s, struct smp_voice *v)
{
	v->active = s[V_ACTIVE] != 0;
	v->region = (long)s[V_REGION];
	v->pos = s[V_POS];
	v->dir = s[V_DIR];
	v->base = s[V_BASE];
	v->gain = s[V_GAIN];
	v->nhz = s[V_NHZ];
	v->inloop = s[V_INLOOP] != 0;
	v->released = s[V_RELEASED] != 0;
	v->speed = s[V_SPEED];
}

static void smp_put(double *s, const struct smp_voice *v)
{
	s[V_ACTIVE] = v->active ? 1 : 0;
	s[V_REGION] = (double)v->region;
	s[V_POS] = v->pos;
	s[V_DIR] = v->dir;
	s[V_BASE] = v->base;
	s[V_GAIN] = v->gain;
	s[V_NHZ] = v->nhz;
	s[V_INLOOP] = v->inloop ? 1 : 0;
	s[V_RELEASED] = v->released ? 1 : 0;
	s[V_SPEED] = v->speed;
}

// True if region +r+ loops right now (looping modes, a release loop until
// released).
static inline _Bool smp_loops(const double *r, const struct smp_voice *v)
{
	double mode = r[REGION_LOOP_MODE];
	if (!(r[REGION_LOOP_END] > r[REGION_LOOP_START])) {
		return 0;
	}
	return mode == LOOP_FORWARD || mode == LOOP_PING_PONG || (mode == LOOP_RELEASE && !v->released);
}

// One sample of voice +v+ at speed +sp+ (source samples per output sample),
// advancing it.
static inline double smp_step(struct smp_ctx *c, struct smp_voice *v, double sp)
{
	const double *r = c->regions + v->region * SMP_REGION_COLS;
	double start = r[REGION_START];
	double end = r[REGION_END];
	double p = v->pos;

	double m = fabs(sp);
	wt_reselect(&c->tables[v->slot], m, 0, &c->sels[v->slot]);
	double re, im;
	int mode = (int)r[REGION_INTERP];
	if (mode < 0) {
		mode = c->mode;
	}
	wt_value_dispatch(&c->tables[v->slot], p, &c->sels[v->slot], mode, &c->ks, &re, &im);

	double g = v->gain;
	double fi = r[REGION_FADE_IN];
	if (fi > 0) {
		double trav = v->dir > 0 ? p - start : (end - 1) - p;
		if (trav < fi) {
			g = g * (trav / fi);
		}
	}

	_Bool loops = smp_loops(r, v);
	double fo = r[REGION_FADE_OUT];
	if (fo > 0 && !loops) {
		double rem = v->dir > 0 ? end - p : (p + 1) - start;
		if (rem < fo) {
			g = g * (rem / fo);
		}
	}

	double val = re * g;

	double np = p + v->dir * sp;
	if (loops) {
		double ls = r[REGION_LOOP_START];
		double le = r[REGION_LOOP_END];
		double len = le - ls;
		if (!v->inloop && np >= ls && np < le) {
			v->inloop = 1;
		}
		if (v->inloop) {
			if (r[REGION_LOOP_MODE] == LOOP_PING_PONG) {
				if (np >= le) {
					np = le - (np - le);
					v->dir = -v->dir;
					if (np < ls) np = ls;
				} else if (np < ls) {
					np = ls + (ls - np);
					v->dir = -v->dir;
					if (np >= le) np = ls;
				}
			} else if (np >= le || np < ls) {
				np = ls + wt_wrap(np - ls, len);
			}
		}
	}

	if (np >= end || np < start) {
		v->active = 0;
	}
	v->pos = np;

	return val;
}

// Starts a note at number +n+ with velocity +vel+ (0..1), start fraction
// +frac+, and pitch mark +shift+ (semitones) into *v (which must be
// inactive), using table slot +slot+.
static void smp_note_on(struct smp_ctx *c, struct smp_voice *v, int slot, double n, double vel, double frac, double shift,
		double *counters, uint64_t *rng, double a4, double transpose)
{
	double rnd = wt_noise_random(rng);
	double v127 = floor(vel * 127.0 + 0.5);
	if (v127 > 127) v127 = 127;
	if (v127 < 0) v127 = 0;

	long j = -1;
	double expo = 0;
	long key = (long)floor(n + 0.5);
	double count = 0;
	if (key >= 0 && key < 128) {
		counters[key] = counters[key] + 1;
		count = counters[key];
	}

	if (c->split >= 0 && key >= c->split) {
		// The split keyboard's upper zone: the last region played below it,
		// chromatically from the split key
		j = c->last_region;
		if (j >= 0) {
			const double *r = c->regions + j * SMP_REGION_COLS;
			expo = ((n - (double)c->split) + r[REGION_TUNE] + transpose + shift) / 12.0;
		}
	} else {
		for (long k = 0; k < c->nregions; k++) {
			const double *r = c->regions + k * SMP_REGION_COLS;
			if (key < r[REGION_LOKEY] || key > r[REGION_HIKEY]) continue;
			if (v127 < r[REGION_LOVEL] || v127 > r[REGION_HIVEL]) continue;
			if (rnd < r[REGION_LORAND] || rnd >= r[REGION_HIRAND]) continue;
			long sl = (long)r[REGION_SEQ_LENGTH];
			if (sl > 1) {
				long pos = ((long)count - 1) % sl + 1;
				if (pos != (long)r[REGION_SEQ_POSITION]) continue;
			}
			j = k;
			break;
		}
		if (j >= 0) {
			const double *r = c->regions + j * SMP_REGION_COLS;
			expo = ((n - r[REGION_ROOT]) * r[REGION_KEYTRACK] + r[REGION_TUNE] + transpose + shift) / 12.0;
			c->last_region = j;
		}
	}

	v->active = 0;
	if (j < 0) {
		return;
	}

	const double *r = c->regions + j * SMP_REGION_COLS;
	double start = r[REGION_START];
	double end = r[REGION_END];
	double off = r[REGION_OFFSET] + frac * (end - start);
	_Bool reverse = r[REGION_REVERSE] != 0;

	v->region = j;
	v->dir = reverse ? -1.0 : 1.0;
	v->pos = reverse ? (end - 1) - off : start + off;
	v->base = pow(2.0, expo) * r[REGION_RATE];
	double vt = r[REGION_VELTRACK];
	double vv = v127 / 127.0;
	v->gain = r[REGION_GAIN] * ((1.0 - vt) + vt * (vv * vv));
	v->nhz = a4 * pow(2.0, (n - 69.0) / 12.0);
	v->released = 0;
	v->speed = v->base;
	v->inloop = r[REGION_LOOP_END] > r[REGION_LOOP_START] && v->pos >= r[REGION_LOOP_START] && v->pos < r[REGION_LOOP_END];
	v->slot = slot;
	v->active = v->pos >= start && v->pos < end;
	if (v->active) {
		smp_load(c, slot, (long)r[REGION_TABLE]);
	}
}

static double *smp_dfloat(VALUE v, long length, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || (long)RNARRAY_SHAPE(v)[0] != length) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D DFloat of %ld values", name, length);
	}
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

static VALUE ruby_play(VALUE self, VALUE buffer, VALUE specs, VALUE regions, VALUE state, VALUE counters, VALUE rng,
		VALUE inputs, VALUE config)
{
	Check_Type(specs, T_ARRAY);
	Check_Type(inputs, T_ARRAY);
	Check_Type(config, T_ARRAY);
	if (RARRAY_LEN(inputs) != 7) {
		rb_raise(rb_eArgError, "Sampler inputs are [trigger, number, freq, gate, start, shift, choke]");
	}
	if (RARRAY_LEN(config) != 8) {
		rb_raise(rb_eArgError, "Sampler config is [a4, declick, split, interpolation, sinc, transpose, choke samples, choke fade]");
	}
	if (RARRAY_LEN(specs) < 1) {
		rb_raise(rb_eArgError, "A sampler needs at least one table");
	}

	if (CLASS_OF(regions) != numo_cDFloat || RNARRAY_NDIM(regions) != 2 || !RTEST(nary_check_contiguous(regions)) ||
			RNARRAY_SHAPE(regions)[1] != SMP_REGION_COLS) {
		rb_raise(rb_eArgError, "Sampler regions must be a contiguous 2D DFloat with %d columns", SMP_REGION_COLS);
	}
	if (CLASS_OF(rng) != numo_cUInt64 || RNARRAY_SIZE(rng) != 1 || !RTEST(nary_check_contiguous(rng))) {
		rb_raise(rb_eArgError, "The sampler's random state must be a one-value contiguous UInt64");
	}

	struct smp_ctx c;
	c.specs = specs;
	c.regions = (const double *)(nary_get_pointer_for_read(regions) + nary_get_offset(regions));
	c.nregions = RNARRAY_SHAPE(regions)[0];
	c.split = NUM2LONG(rb_ary_entry(config, 2));
	if (c.split < -1 || c.split > 127) {
		rb_raise(rb_eArgError, "The split key must be -1 (none) or 0 to 127");
	}
	for (long k = 0; k < c.nregions; k++) {
		const double *r = c.regions + k * SMP_REGION_COLS;
		long t = (long)r[REGION_TABLE];
		if (t < 0 || t >= RARRAY_LEN(specs) || !(r[REGION_END] > r[REGION_START]) || r[REGION_START] < 0) {
			rb_raise(rb_eArgError, "Sampler region %ld has a bad table or range", k);
		}
	}
	c.loaded[0] = c.loaded[1] = -1;
	c.sels[0].valid = c.sels[1].valid = 0;

	// The interpolation mode, checked against the first table's guard
	struct wt_table probe;
	wt_read_table(rb_ary_entry(specs, 0), &probe);
	memset(&c.ks, 0, sizeof(c.ks));
	c.mode = wt_read_interp(rb_ary_entry(config, 3), rb_ary_entry(config, 4), &probe, &c.ks);

	// Regions' own interpolation codes (Sample#read_as); a sinc region needs
	// config's sinc kernel even when config's own mode isn't sinc
	_Bool need_sinc = 0;
	for (long k = 0; k < c.nregions; k++) {
		double m = c.regions[k * SMP_REGION_COLS + REGION_INTERP];
		if (!(m >= -1 && m <= WT_SINC) || m != floor(m)) {
			rb_raise(rb_eArgError, "Sampler region %ld has a bad interpolation code", k);
		}
		if (m == WT_SINC) {
			need_sinc = 1;
		}
	}
	if (need_sinc && c.mode != WT_SINC) {
		VALUE sinc = rb_ary_entry(config, 4);
		if (NIL_P(sinc)) {
			rb_raise(rb_eArgError, "A sampler region reads with sinc interpolation, so config needs the sinc kernel");
		}
		wt_read_sinc(sinc, &c.ks);
		if (c.ks.half + 4 > probe.guard) {
			rb_raise(rb_eArgError, "The sinc kernel is too long for the guard samples");
		}
	}

	double a4 = NUM2DBL(rb_ary_entry(config, 0));
	long declick = NUM2LONG(rb_ary_entry(config, 1));
	double transpose = NUM2DBL(rb_ary_entry(config, 5));
	long choke_len = NUM2LONG(rb_ary_entry(config, 6));
	_Bool choke_fade = NUM2LONG(rb_ary_entry(config, 7)) != 0;
	if (choke_len < 1) {
		rb_raise(rb_eArgError, "The sampler's choke length must be at least one sample");
	}

	double *st = smp_dfloat(state, SMP_STATE_LENGTH, "Sampler state");
	double *cnt = smp_dfloat(counters, 128, "Sampler counters");
	uint64_t *rs = (uint64_t *)(nary_get_pointer_for_write(rng) + nary_get_offset(rng));

	if (CLASS_OF(buffer) != numo_cSFloat || RNARRAY_NDIM(buffer) != 1 || !RTEST(nary_check_contiguous(buffer))) {
		rb_raise(rb_eArgError, "The sampler's output must be a contiguous 1D SFloat (written in place)");
	}
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = mb_sfloat_ptr(buffer);

	VALUE trig_v = rb_ary_entry(inputs, 0);
	VALUE num_v = rb_ary_entry(inputs, 1);
	VALUE freq_v = rb_ary_entry(inputs, 2);
	VALUE gate_v = rb_ary_entry(inputs, 3);
	VALUE start_v = rb_ary_entry(inputs, 4);
	VALUE shift_v = rb_ary_entry(inputs, 5);
	VALUE choke_v = rb_ary_entry(inputs, 6);
	_Bool has_freq = !NIL_P(freq_v);
	_Bool has_gate = !NIL_P(gate_v);
	_Bool has_choke = !NIL_P(choke_v);
	struct mb_signal trig, num, freq, gate, startf, shift, choke;
	mb_signal_input(&trig_v, length, "Trigger", &trig);
	mb_signal_input(&num_v, length, "Number", &num);
	mb_signal_input(&freq_v, length, "Frequency", &freq);
	mb_signal_input(&gate_v, length, "Gate", &gate);
	mb_signal_input(&start_v, length, "Start", &startf);
	mb_signal_input(&shift_v, length, "Shift", &shift);
	mb_signal_input(&choke_v, length, "Choke", &choke);

	struct smp_voice cur, tail;
	smp_get(st, &cur);
	smp_get(st + SMP_VOICE, &tail);
	double left = st[SMP_TAIL_LEFT];
	double choke_left = st[SMP_CHOKE_LEFT];
	c.last_region = (long)st[SMP_LAST_REGION];
	if (c.last_region < -1 || c.last_region >= c.nregions) {
		rb_raise(rb_eArgError, "The sampler state's last region is out of range");
	}
	cur.slot = 0;
	tail.slot = 1;
	if (cur.active) smp_load(&c, 0, (long)c.regions[cur.region * SMP_REGION_COLS + REGION_TABLE]);
	if (tail.active) smp_load(&c, 1, (long)c.regions[tail.region * SMP_REGION_COLS + REGION_TABLE]);

	for (size_t i = 0; i < length; i++) {
		double t = mb_signal_at(&trig, i);
		double n = mb_signal_at(&num, i);

		if (t > 0) {
			int slot = cur.slot;
			if (cur.active && declick > 0) {
				tail = cur;
				left = (double)declick;
				slot = 1 - cur.slot;
			} else if (tail.active) {
				slot = 1 - tail.slot;
			}
			double vel = t > 1 ? 1.0 : t;
			smp_note_on(&c, &cur, slot, n, vel, mb_signal_at(&startf, i), mb_signal_at(&shift, i), cnt, rs, a4, transpose);
			choke_left = 0;
		} else if (has_choke && choke_left <= 0 && mb_signal_at(&choke, i) != 0 && (cur.active || tail.active)) {
			choke_left = (double)choke_len;
		}

		if (has_gate && mb_signal_at(&gate, i) <= 0) {
			cur.released = 1;
		}

		double v = 0;
		if (cur.active) {
			double sp = cur.base;
			if (has_freq && cur.nhz > 0) {
				sp = cur.base * (mb_signal_at(&freq, i) / cur.nhz);
			}
			cur.speed = sp;
			v = smp_step(&c, &cur, sp);
		}
		if (tail.active) {
			double g = left / (double)declick;
			double tv = smp_step(&c, &tail, tail.speed);
			v = v + tv * g;
			left = left - 1;
			if (left <= 0) {
				tail.active = 0;
			}
		}
		if (choke_left > 0) {
			if (choke_fade) {
				v = v * (choke_left / (double)choke_len);
			}
			choke_left = choke_left - 1;
			if (choke_left <= 0) {
				cur.active = 0;
				tail.active = 0;
			}
		}

		out[i] = v;
	}

	smp_put(st, &cur);
	smp_put(st + SMP_VOICE, &tail);
	st[SMP_TAIL_LEFT] = left;
	st[SMP_CHOKE_LEFT] = choke_left;
	st[SMP_LAST_REGION] = (double)c.last_region;

	RB_GC_GUARD(trig_v);
	RB_GC_GUARD(num_v);
	RB_GC_GUARD(freq_v);
	RB_GC_GUARD(gate_v);
	RB_GC_GUARD(start_v);
	RB_GC_GUARD(shift_v);
	RB_GC_GUARD(choke_v);

	return buffer;
}

void Init_fast_sampler(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_sampler = rb_define_module_under(sound, "FastSampler");

	rb_define_module_function(fast_sampler, "play", ruby_play, 8);
	rb_define_const(fast_sampler, "REGION_COLS", INT2FIX(SMP_REGION_COLS));
	rb_define_const(fast_sampler, "STATE_LENGTH", INT2FIX(SMP_STATE_LENGTH));
	rb_define_const(fast_sampler, "CHOKE_LEFT", INT2FIX(SMP_CHOKE_LEFT));

	mb_granular_init(fast_sampler);
}
