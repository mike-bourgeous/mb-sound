/*
 * Reverb network kernel for MB::Sound::GraphNode::Reverb: diffusion stages
 * and a feedback delay network (FDN), run one sample at a time so the
 * feedback loops are exactly the line delays at every buffer size, with
 * modulated delay reads and processing inside the feedback loop.
 *
 * Per sample (pos counts samples since the start of the stream):
 *
 *   1. Every LFO_STEP samples of the stream, the LFOs compute their value
 *      LFO_STEP samples ahead; in between the value ramps linearly (one add
 *      per LFO per sample), so the modulation doesn't depend on the buffer
 *      size.
 *   2. x[j] = input[j] * in_gain[j] * (1 - freeze)
 *   3. Each diffusion stage s: x[j] is written to line (s, j), read back
 *      delay[s][j] + depth * (1 + lfo) samples later (cubic interpolation
 *      when fractional), multiplied by its polarity, mixed by a normalized
 *      Hadamard matrix (fast Walsh-Hadamard transform times +diff_scale+),
 *      and shuffled: x[k] = mixed[order[s][k]].
 *   4. Without feedback the outputs are x.  With it, each FDN line j is
 *      read at its loop delay loop[j] * size + depth * lfo (the line's
 *      input that many samples ago), shimmer-pitch-shifted, filtered
 *      (damping lowpass, highpass), saturated, bit-crushed, and scaled by
 *      its gain (raised toward 1 by +freeze+): r[j].  u = x + r is mixed by
 *      a Householder reflection (u - 2 n (n . u)), shuffled into the lines'
 *      inputs (w[i] = h[order[i]]), and written.  The outputs are the lines
 *      read at their output taps tap[i] * size + depth * lfo (after the
 *      write, so a tap may be 0 samples; taps equal to the loops read the
 *      same samples as the loops).
 *
 * MB::Sound::FastReverb::Network.new(config) builds the state (see
 * Reverb::Network for the config Hash); #process(inputs, outputs, params)
 * runs a block.  The exact Ruby mirror is Reverb::Network::RubyKernel,
 * which does the same double operations in the same order and rounds to
 * float32 where this stores floats (ring buffers and outputs); built with
 * -ffp-contract=off so specs can compare them for exact equality.
 */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

// LFOs compute a new target every this many samples of the stream.
#define LFO_STEP 16

// Parameter signals passed to #process, in order.
enum rev_param {
	P_DIFF_DEPTH = 0, // diffusion modulation depth (samples)
	P_DIFF_RATE, // diffusion modulation rate (Hz)
	P_FDN_DEPTH, // feedback modulation depth (samples)
	P_FDN_RATE, // feedback modulation rate (Hz)
	P_DAMPING, // damping lowpass cutoff (Hz; <= 0 off; ignored with per-line damping)
	P_HIGHPASS, // highpass cutoff (Hz; <= 0 off)
	P_DRIVE, // saturation drive (<= 0 off)
	P_SHIMMER, // shimmer amount (0..1)
	P_SHIMMER_RATIO, // shimmer pitch ratio (2 = an octave up)
	P_FREEZE, // freeze (0..1)
	P_SIZE, // delay scale for the FDN lines (1 = as built)
	P_CRUSH, // bit depth in the loop (<= 0 off)
	P_COUNT
};

// LFO shapes.
enum rev_shape {
	SHAPE_SINE = 0,
	SHAPE_TRIANGLE = 1,
	SHAPE_RANDOM = 2, // random targets, linear in between
	SHAPE_SMOOTH = 3, // random targets, smoothstep in between
};

// Saturation shapes.
enum rev_drive {
	DRIVE_SOFT = 0, // rational tanh approximation
	DRIVE_HARD = 1, // clip at +/-1
	DRIVE_FOLD = 2, // triangle wavefolder
};

struct rev_line {
	float *buf;
	uint64_t mask;
};

struct rev_lfo {
	double phase;
	double value;
	double slope;
	double prev;
	double next;
	double scale; // rate multiplier
};

struct rev_net {
	long n;
	long stages;
	int feedback;
	double sample_rate;
	uint64_t pos;
	uint64_t rng;

	struct rev_line *diff; // stages * n
	double *diff_delay; // stages * n (samples)
	double *diff_pol; // stages * n
	long *diff_order; // stages * n
	double diff_scale;

	struct rev_line *fdn; // n
	double *tap; // n (samples)
	double *loop; // n (samples)
	double *gain; // n
	double *normal; // n
	long *order; // n
	double *in_gain; // n
	double *damp_a; // n (per-line one-pole coefficients) or NULL

	int diff_mod;
	int fdn_mod;
	int diff_shape;
	int fdn_shape;
	struct rev_lfo *dlfo; // stages * n
	struct rev_lfo *flfo; // n

	int drive_mode;
	double shimmer_window; // samples
	double *shim_phase; // n

	double *lp; // n damping states
	double *hp; // n highpass states

	// Coefficient caches (NAN never equals, so the first sample computes them)
	double damp_hz;
	double damp_c;
	double hp_hz;
	double hp_c;
	double crush_bits;
	double crush_q;

	double *x; // n scratch
	double *u; // n scratch
};

static void rev_free(void *p)
{
	struct rev_net *r = p;
	if (r == NULL) {
		return;
	}
	if (r->diff) {
		for (long i = 0; i < r->stages * r->n; i++) {
			free(r->diff[i].buf);
		}
	}
	if (r->fdn) {
		for (long i = 0; i < r->n; i++) {
			free(r->fdn[i].buf);
		}
	}
	free(r->diff);
	free(r->diff_delay);
	free(r->diff_pol);
	free(r->diff_order);
	free(r->fdn);
	free(r->tap);
	free(r->loop);
	free(r->gain);
	free(r->normal);
	free(r->order);
	free(r->in_gain);
	free(r->damp_a);
	free(r->dlfo);
	free(r->flfo);
	free(r->shim_phase);
	free(r->lp);
	free(r->hp);
	free(r->x);
	free(r->u);
	free(r);
}

static size_t rev_memsize(const void *p)
{
	const struct rev_net *r = p;
	size_t total = sizeof(*r);
	if (r == NULL) {
		return 0;
	}
	if (r->diff) {
		for (long i = 0; i < r->stages * r->n; i++) {
			total += (r->diff[i].mask + 1) * sizeof(float);
		}
	}
	if (r->fdn) {
		for (long i = 0; i < r->n; i++) {
			total += (r->fdn[i].mask + 1) * sizeof(float);
		}
	}
	return total;
}

static const rb_data_type_t rev_type = {
	.wrap_struct_name = "MB::Sound::FastReverb::Network",
	.function = {
		.dmark = NULL,
		.dfree = rev_free,
		.dsize = rev_memsize,
	},
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE rev_alloc(VALUE klass)
{
	struct rev_net *r = calloc(1, sizeof(struct rev_net));
	if (r == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate a reverb network");
	}
	return TypedData_Wrap_Struct(klass, &rev_type, r);
}

static struct rev_net *rev_get(VALUE self)
{
	struct rev_net *r;
	TypedData_Get_Struct(self, struct rev_net, &rev_type, r);
	if (r->n == 0) {
		rb_raise(rb_eRuntimeError, "Reverb network not initialized");
	}
	return r;
}

static void *rev_calloc(size_t count, size_t size)
{
	void *p = calloc(count ? count : 1, size);
	if (p == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate reverb state");
	}
	return p;
}

// Config value +key+ (a Symbol name) from +config+, raising if missing.
static VALUE cfg(VALUE config, const char *key)
{
	VALUE v = rb_hash_aref(config, ID2SYM(rb_intern(key)));
	if (NIL_P(v)) {
		rb_raise(rb_eArgError, "Missing reverb config :%s", key);
	}
	return v;
}

// Copies config Array +key+ of +len+ numbers into a new double array.
static double *cfg_doubles(VALUE config, const char *key, long len)
{
	VALUE ary = cfg(config, key);
	Check_Type(ary, T_ARRAY);
	if (RARRAY_LEN(ary) != len) {
		rb_raise(rb_eArgError, "Reverb config :%s needs %ld values, got %ld", key, len, RARRAY_LEN(ary));
	}
	double *out = rev_calloc(len, sizeof(double));
	for (long i = 0; i < len; i++) {
		out[i] = NUM2DBL(rb_ary_entry(ary, i));
	}
	return out;
}

// Copies config Array +key+ of +len+ indices below +limit+ into a new array.
static long *cfg_indices(VALUE config, const char *key, long len, long limit)
{
	VALUE ary = cfg(config, key);
	Check_Type(ary, T_ARRAY);
	if (RARRAY_LEN(ary) != len) {
		rb_raise(rb_eArgError, "Reverb config :%s needs %ld values, got %ld", key, len, RARRAY_LEN(ary));
	}
	long *out = rev_calloc(len, sizeof(long));
	for (long i = 0; i < len; i++) {
		out[i] = NUM2LONG(rb_ary_entry(ary, i));
		if (out[i] < 0 || out[i] >= limit) {
			rb_raise(rb_eArgError, "Reverb config :%s index %ld out of range", key, out[i]);
		}
	}
	return out;
}

// Allocates a zeroed ring of at least +need+ samples (a power of two).
static void line_init(struct rev_line *l, double need)
{
	if (!(need >= 0) || need > (double)(1L << 28)) {
		rb_raise(rb_eArgError, "Invalid reverb line length %f", need);
	}
	uint64_t cap = 16;
	while ((double)cap < need + 4) {
		cap <<= 1;
	}
	l->buf = rev_calloc(cap, sizeof(float));
	l->mask = cap - 1;
}

// splitmix64 (as Tone.noise_random).
static inline uint64_t rev_rand64(uint64_t *state)
{
	uint64_t z = (*state += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

// A random value in -1...1.
static inline double rev_rand(uint64_t *state)
{
	return (double)(rev_rand64(state) >> 11) * (1.0 / 9007199254740992.0) * 2.0 - 1.0;
}

// The LFO shape at +phase+ (0...1): sine (a 7th-order polynomial of the
// folded triangle, within 2e-4), triangle, or between random targets.
static inline double lfo_shape(int shape, const struct rev_lfo *l)
{
	double p = l->phase;
	switch (shape) {
		case SHAPE_SINE:
		case SHAPE_TRIANGLE: {
			double t;
			if (p < 0.25) {
				t = 4.0 * p;
			} else if (p < 0.75) {
				t = 2.0 - 4.0 * p;
			} else {
				t = 4.0 * p - 4.0;
			}
			if (shape == SHAPE_TRIANGLE) {
				return t;
			}
			double t2 = t * t;
			return t * (1.5707963267948966 - t2 * (0.6459640975062462 - t2 * (0.07969262624616703 - t2 * 0.004681754135318687)));
		}

		case SHAPE_RANDOM:
			return l->prev + (l->next - l->prev) * p;

		default: {
			double s = p * p * (3.0 - 2.0 * p);
			return l->prev + (l->next - l->prev) * s;
		}
	}
}

// Moves +l+ LFO_STEP samples ahead at +inc+ cycles per sample and sets its
// slope toward the new value (drawing random targets at each wrap).
static inline void lfo_step(struct rev_lfo *l, int shape, double inc, uint64_t *rng)
{
	double target;
	l->phase += inc * l->scale * LFO_STEP;
	if (!(l->phase < 1.0) || l->phase < 0) {
		if (shape >= SHAPE_RANDOM) {
			while (l->phase >= 1.0) {
				l->phase -= 1.0;
				l->prev = l->next;
				l->next = rev_rand(rng);
			}
			if (l->phase < 0) {
				l->phase = 0;
			}
		} else {
			l->phase = mb_wrap(l->phase, 1.0);
		}
	}
	target = lfo_shape(shape, l);
	l->slope = (target - l->value) * (1.0 / LFO_STEP);
}

// Reads +l+ at +d+ samples before +pos+ (whole samples directly, else a
// 4-point Catmull-Rom spline reading one sample newer than floor(d)).
static inline double line_read(const struct rev_line *l, uint64_t pos, double d)
{
	double fl = mb_floor(d);
	uint64_t di = (uint64_t)fl;
	double t = d - fl;
	const float *b = l->buf;
	uint64_t m = l->mask;
	if (t == 0) {
		return b[(pos - di) & m];
	}
	double ym1 = b[(pos - di + 1) & m];
	double y0 = b[(pos - di) & m];
	double y1 = b[(pos - di - 1) & m];
	double y2 = b[(pos - di - 2) & m];
	double c1 = 0.5 * (y1 - ym1);
	double c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2;
	double c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1);
	return ((c3 * t + c2) * t + c1) * t + y0;
}

// Clamps a read delay to [+lo+ (1 more if fractional), capacity - 4].
static inline double clamp_delay(double d, double lo, const struct rev_line *l)
{
	double hi = (double)l->mask - 3.0;
	if (!(d >= lo)) {
		d = lo;
	}
	if (d > hi) {
		d = hi;
	}
	if (d < lo + 1.0 && d != mb_floor(d)) {
		d = lo + 1.0;
	}
	return d;
}

// The saturation shape for one sample at unit small-signal gain.
static inline double drive_shape(int mode, double u)
{
	switch (mode) {
		case DRIVE_HARD:
			return u > 1.0 ? 1.0 : (u < -1.0 ? -1.0 : u);

		case DRIVE_FOLD: {
			double t = (u + 1.0) * 0.25;
			t -= mb_floor(t);
			double y = 1.0 - 4.0 * fabs(t - 0.5);
			return y;
		}

		default:
			if (u >= 3.0) {
				return 1.0;
			}
			if (u <= -3.0) {
				return -1.0;
			}
			return u * (27.0 + u * u) / (27.0 + 9.0 * u * u);
	}
}

/*
 * call-seq:
 *   MB::Sound::FastReverb::Network.new(config) -> network
 *
 * See MB::Sound::GraphNode::Reverb::Network#kernel_config for the keys.
 */
static VALUE rev_initialize(VALUE self, VALUE config)
{
	struct rev_net *r;
	TypedData_Get_Struct(self, struct rev_net, &rev_type, r);
	if (r->n != 0) {
		rb_raise(rb_eRuntimeError, "Reverb network already initialized");
	}
	Check_Type(config, T_HASH);

	long n = NUM2LONG(cfg(config, "lines"));
	long stages = NUM2LONG(cfg(config, "stages"));
	if (n < 1 || n > 1024 || (n & (n - 1)) != 0) {
		rb_raise(rb_eArgError, "Reverb lines must be a power of two from 1 to 1024");
	}
	if (stages < 0 || stages > 64) {
		rb_raise(rb_eArgError, "Reverb stages must be 0 to 64");
	}

	r->sample_rate = NUM2DBL(cfg(config, "sample_rate"));
	if (!(r->sample_rate > 0)) {
		rb_raise(rb_eArgError, "Sample rate must be positive");
	}
	r->feedback = RTEST(cfg(config, "feedback"));
	r->rng = NUM2ULL(cfg(config, "seed"));
	r->diff_scale = NUM2DBL(cfg(config, "diff_scale"));
	r->diff_mod = RTEST(cfg(config, "diff_mod"));
	r->fdn_mod = RTEST(cfg(config, "fdn_mod"));
	r->diff_shape = NUM2INT(cfg(config, "diff_shape"));
	r->fdn_shape = NUM2INT(cfg(config, "fdn_shape"));
	r->drive_mode = NUM2INT(cfg(config, "drive_mode"));
	r->shimmer_window = NUM2DBL(cfg(config, "shimmer_window"));
	if (r->diff_shape < 0 || r->diff_shape > 3 || r->fdn_shape < 0 || r->fdn_shape > 3) {
		rb_raise(rb_eArgError, "Invalid LFO shape");
	}
	if (r->drive_mode < 0 || r->drive_mode > 2) {
		rb_raise(rb_eArgError, "Invalid drive mode");
	}
	if (!(r->shimmer_window >= 4)) {
		rb_raise(rb_eArgError, "Shimmer window must be at least 4 samples");
	}

	// n and stages are set last-ish so a raise above leaves an
	// uninitialized (n == 0) network that rev_get refuses; arrays below
	// are freed by rev_free whatever happens.
	long sn = stages * n;
	r->stages = stages;
	r->n = n;

	r->in_gain = cfg_doubles(config, "in_gain", n);
	r->diff_delay = cfg_doubles(config, "diff_delay", sn);
	r->diff_pol = cfg_doubles(config, "diff_polarity", sn);
	r->diff_order = cfg_indices(config, "diff_order", sn, n);
	double *diff_cap = cfg_doubles(config, "diff_capacity", sn);
	r->diff = rev_calloc(sn, sizeof(struct rev_line));
	for (long i = 0; i < sn; i++) {
		line_init(&r->diff[i], diff_cap[i]);
	}
	free(diff_cap);

	r->tap = cfg_doubles(config, "tap", n);
	r->loop = cfg_doubles(config, "loop", n);
	r->gain = cfg_doubles(config, "gain", n);
	r->normal = cfg_doubles(config, "normal", n);
	r->order = cfg_indices(config, "order", n, n);
	double *fdn_cap = cfg_doubles(config, "fdn_capacity", n);
	r->fdn = rev_calloc(n, sizeof(struct rev_line));
	for (long i = 0; i < n; i++) {
		line_init(&r->fdn[i], r->feedback ? fdn_cap[i] : 0);
	}
	free(fdn_cap);

	VALUE damp = rb_hash_aref(config, ID2SYM(rb_intern("damp_coeffs")));
	if (!NIL_P(damp)) {
		r->damp_a = cfg_doubles(config, "damp_coeffs", n);
	}

	double *diff_scales = cfg_doubles(config, "diff_rate_scale", sn);
	double *diff_phases = cfg_doubles(config, "diff_phase", sn);
	double *fdn_scales = cfg_doubles(config, "fdn_rate_scale", n);
	double *fdn_phases = cfg_doubles(config, "fdn_phase", n);
	double *shim = cfg_doubles(config, "shimmer_phase", n);
	r->dlfo = rev_calloc(sn, sizeof(struct rev_lfo));
	r->flfo = rev_calloc(n, sizeof(struct rev_lfo));
	for (long i = 0; i < sn; i++) {
		r->dlfo[i].scale = diff_scales[i];
		r->dlfo[i].phase = diff_phases[i];
	}
	for (long i = 0; i < n; i++) {
		r->flfo[i].scale = fdn_scales[i];
		r->flfo[i].phase = fdn_phases[i];
	}
	r->shim_phase = shim;
	free(diff_scales);
	free(diff_phases);
	free(fdn_scales);
	free(fdn_phases);

	// Random targets for every LFO (diffusion first, then feedback), and
	// each LFO's value at sample 0
	for (long i = 0; i < sn; i++) {
		r->dlfo[i].prev = rev_rand(&r->rng);
		r->dlfo[i].next = rev_rand(&r->rng);
		r->dlfo[i].value = lfo_shape(r->diff_shape, &r->dlfo[i]);
	}
	for (long i = 0; i < n; i++) {
		r->flfo[i].prev = rev_rand(&r->rng);
		r->flfo[i].next = rev_rand(&r->rng);
		r->flfo[i].value = lfo_shape(r->fdn_shape, &r->flfo[i]);
	}

	r->lp = rev_calloc(n, sizeof(double));
	r->hp = rev_calloc(n, sizeof(double));
	r->x = rev_calloc(n, sizeof(double));
	r->u = rev_calloc(n, sizeof(double));

	r->damp_hz = NAN;
	r->hp_hz = NAN;
	r->crush_bits = NAN;

	return self;
}

// Returns the float data of output +idx+ of +outputs+ (checked).
static float *out_ptr(VALUE outputs, long idx, size_t count)
{
	VALUE o = rb_ary_entry(outputs, idx);
	if (CLASS_OF(o) != numo_cSFloat || RNARRAY_NDIM(o) != 1 || !RTEST(nary_check_contiguous(o)) ||
			(size_t)RNARRAY_SHAPE(o)[0] < count) {
		rb_raise(rb_eArgError, "Output %ld must be a contiguous 1D Numo::SFloat of at least %zu samples", idx, count);
	}
	if (OBJ_FROZEN(o)) {
		rb_raise(rb_eFrozenError, "Output %ld is frozen", idx);
	}
	return (float *)(nary_get_pointer_for_write(o) + nary_get_offset(o));
}

/*
 * call-seq:
 *   network.process(inputs, outputs, params, count) -> outputs
 *
 * +inputs+ is an Array of one signal per line (a Numeric, nil, or an NArray
 * of at least +count+ samples, read as float32), +outputs+ an Array of one
 * contiguous Numo::SFloat per line (written), +params+ an Array of
 * P_COUNT signals (see enum rev_param).
 */
static VALUE rev_process(VALUE self, VALUE inputs, VALUE outputs, VALUE params, VALUE vcount)
{
	struct rev_net *r = rev_get(self);
	long n = r->n;
	long count = NUM2LONG(vcount);
	if (count < 0) {
		rb_raise(rb_eArgError, "Count must be non-negative");
	}
	Check_Type(inputs, T_ARRAY);
	Check_Type(outputs, T_ARRAY);
	Check_Type(params, T_ARRAY);
	if (RARRAY_LEN(inputs) != n || RARRAY_LEN(outputs) != n) {
		rb_raise(rb_eArgError, "Need %ld inputs and outputs", n);
	}
	if (RARRAY_LEN(params) != P_COUNT) {
		rb_raise(rb_eArgError, "Need %d parameters", P_COUNT);
	}

	// Signals (cast copies, if any, are kept alive in these Arrays)
	VALUE in_vals = rb_ary_dup(inputs);
	VALUE par_vals = rb_ary_dup(params);
	struct mb_signal *in = ALLOCA_N(struct mb_signal, n);
	struct mb_signal par[P_COUNT];
	float **out = ALLOCA_N(float *, n);
	for (long j = 0; j < n; j++) {
		VALUE v = rb_ary_entry(in_vals, j);
		mb_signal_input(&v, count, "Input", &in[j]);
		rb_ary_store(in_vals, j, v);
		out[j] = out_ptr(outputs, j, count);
	}
	for (long k = 0; k < P_COUNT; k++) {
		VALUE v = rb_ary_entry(par_vals, k);
		mb_signal_input(&v, count, "Parameter", &par[k]);
		rb_ary_store(par_vals, k, v);
	}

	double fs = r->sample_rate;
	double *x = r->x;
	double *u = r->u;
	long stages = r->stages;

	for (long i = 0; i < count; i++) {
		uint64_t pos = r->pos;

		double diff_depth = mb_signal_at(&par[P_DIFF_DEPTH], i);
		double fdn_depth = mb_signal_at(&par[P_FDN_DEPTH], i);
		double freeze = mb_signal_at(&par[P_FREEZE], i);
		if (!(freeze > 0)) {
			freeze = 0;
		} else if (freeze > 1) {
			freeze = 1;
		}

		// LFOs: a new target every LFO_STEP samples of the stream
		if ((pos % LFO_STEP) == 0) {
			if (r->diff_mod) {
				double inc = mb_signal_at(&par[P_DIFF_RATE], i) / fs;
				for (long k = 0; k < stages * n; k++) {
					lfo_step(&r->dlfo[k], r->diff_shape, inc, &r->rng);
				}
			}
			if (r->fdn_mod && r->feedback) {
				double inc = mb_signal_at(&par[P_FDN_RATE], i) / fs;
				for (long k = 0; k < n; k++) {
					lfo_step(&r->flfo[k], r->fdn_shape, inc, &r->rng);
				}
			}
		}

		double in_scale = 1.0 - freeze;
		for (long j = 0; j < n; j++) {
			x[j] = mb_signal_at(&in[j], i) * r->in_gain[j] * in_scale;
		}

		// Diffusion stages
		for (long s = 0; s < stages; s++) {
			struct rev_line *lines = r->diff + s * n;
			const double *delay = r->diff_delay + s * n;
			const double *pol = r->diff_pol + s * n;
			const long *order = r->diff_order + s * n;
			struct rev_lfo *lfo = r->dlfo + s * n;

			for (long j = 0; j < n; j++) {
				lines[j].buf[pos & lines[j].mask] = (float)x[j];
				double d = delay[j];
				if (r->diff_mod) {
					d += diff_depth * (1.0 + lfo[j].value);
				}
				d = clamp_delay(d, 0, &lines[j]);
				u[j] = line_read(&lines[j], pos, d) * pol[j];
			}

			for (long h = 1; h < n; h <<= 1) {
				for (long a = 0; a < n; a += h << 1) {
					for (long b = a; b < a + h; b++) {
						double p = u[b];
						double q = u[b + h];
						u[b] = p + q;
						u[b + h] = p - q;
					}
				}
			}

			for (long k = 0; k < n; k++) {
				x[k] = u[order[k]] * r->diff_scale;
			}
		}

		if (!r->feedback) {
			for (long j = 0; j < n; j++) {
				out[j][i] = (float)x[j];
			}
		} else {
			double size = mb_signal_at(&par[P_SIZE], i);
			double damp_hz = mb_signal_at(&par[P_DAMPING], i);
			double hp_hz = mb_signal_at(&par[P_HIGHPASS], i);
			double drive = mb_signal_at(&par[P_DRIVE], i);
			double shimmer = mb_signal_at(&par[P_SHIMMER], i);
			double bits = mb_signal_at(&par[P_CRUSH], i);

			if (!(size > 0)) {
				size = 0;
			}
			if (damp_hz != r->damp_hz) {
				r->damp_hz = damp_hz;
				r->damp_c = damp_hz > 0 ? 1.0 - exp(-2.0 * M_PI * damp_hz / fs) : 1.0;
			}
			if (hp_hz != r->hp_hz) {
				r->hp_hz = hp_hz;
				r->hp_c = hp_hz > 0 ? 1.0 - exp(-2.0 * M_PI * hp_hz / fs) : 0.0;
			}
			if (bits != r->crush_bits) {
				r->crush_bits = bits;
				r->crush_q = bits > 0 ? pow(2.0, bits) : 0.0;
			}
			double shim_inc = 0;
			if (shimmer > 0) {
				if (shimmer > 1) {
					shimmer = 1;
				}
				shim_inc = (mb_signal_at(&par[P_SHIMMER_RATIO], i) - 1.0) / r->shimmer_window;
			} else {
				shimmer = 0;
			}

			// Loop reads and in-loop processing
			for (long j = 0; j < n; j++) {
				struct rev_line *l = &r->fdn[j];
				double mod = r->fdn_mod ? fdn_depth * r->flfo[j].value : 0.0;
				double d = clamp_delay(r->loop[j] * size + mod, 1, l);
				double v = line_read(l, pos, d);

				if (shimmer > 0) {
					double ph = r->shim_phase[j] - shim_inc;
					ph -= mb_floor(ph);
					r->shim_phase[j] = ph;
					double ph2 = ph + 0.5;
					if (ph2 >= 1.0) {
						ph2 -= 1.0;
					}
					double w = r->shimmer_window;
					double s1 = line_read(l, pos, clamp_delay(d + w * ph, 1, l));
					double s2 = line_read(l, pos, clamp_delay(d + w * ph2, 1, l));
					double shifted = s1 * (1.0 - fabs(2.0 * ph - 1.0)) + s2 * (1.0 - fabs(2.0 * ph2 - 1.0));
					v = v + (shifted - v) * shimmer;
				}

				double c = r->damp_a ? r->damp_a[j] : r->damp_c;
				if (c < 1.0) {
					r->lp[j] += c * (v - r->lp[j]);
					v = r->lp[j] + (v - r->lp[j]) * freeze;
				}

				if (r->hp_c > 0) {
					r->hp[j] += r->hp_c * (v - r->hp[j]);
					v = v - r->hp[j] * (1.0 - freeze);
				}

				if (drive > 0) {
					v = drive_shape(r->drive_mode, v * drive) / drive;
				}

				// Quantized toward zero, so a decaying loop can't get stuck
				// on a level (rounding to nearest could hold x when
				// x * gain rounds back to x: a limit cycle)
				if (r->crush_q > 0) {
					double t = v * r->crush_q;
					t = t < 0 ? -mb_floor(-t) : mb_floor(t);
					v = t / r->crush_q;
				}

				double g = r->gain[j];
				g += (1.0 - g) * freeze;
				u[j] = x[j] + v * g;
			}

			// Householder reflection, shuffle, write
			double dot = 0;
			for (long j = 0; j < n; j++) {
				dot += r->normal[j] * u[j];
			}
			double twice = 2.0 * dot;
			for (long j = 0; j < n; j++) {
				x[j] = u[j] - r->normal[j] * twice;
			}
			for (long j = 0; j < n; j++) {
				struct rev_line *l = &r->fdn[j];
				l->buf[pos & l->mask] = (float)x[r->order[j]];
			}

			// Output taps
			for (long j = 0; j < n; j++) {
				struct rev_line *l = &r->fdn[j];
				double mod = r->fdn_mod ? fdn_depth * r->flfo[j].value : 0.0;
				double d = clamp_delay(r->tap[j] * size + mod, 0, l);
				out[j][i] = (float)line_read(l, pos, d);
			}
		}

		// LFO ramps
		if (r->diff_mod) {
			for (long k = 0; k < stages * n; k++) {
				r->dlfo[k].value += r->dlfo[k].slope;
			}
		}
		if (r->fdn_mod && r->feedback) {
			for (long k = 0; k < n; k++) {
				r->flfo[k].value += r->flfo[k].slope;
			}
		}

		r->pos = pos + 1;
	}

	RB_GC_GUARD(in_vals);
	RB_GC_GUARD(par_vals);
	return outputs;
}

/*
 * call-seq:
 *   network.position -> Integer
 *
 * Samples processed since the network was created.
 */
static VALUE rev_position(VALUE self)
{
	return ULL2NUM(rev_get(self)->pos);
}

/*
 * call-seq:
 *   network.lfo_values -> [diffusion values, feedback values]
 *
 * The LFOs' current values (for specs and plots).
 */
static VALUE rev_lfo_values(VALUE self)
{
	struct rev_net *r = rev_get(self);
	VALUE d = rb_ary_new_capa(r->stages * r->n);
	VALUE f = rb_ary_new_capa(r->n);
	for (long i = 0; i < r->stages * r->n; i++) {
		rb_ary_push(d, DBL2NUM(r->dlfo[i].value));
	}
	for (long i = 0; i < r->n; i++) {
		rb_ary_push(f, DBL2NUM(r->flfo[i].value));
	}
	return rb_ary_new_from_args(2, d, f);
}

void Init_fast_reverb(void)
{
	VALUE mMB = rb_define_module("MB");
	VALUE mSound = rb_define_module_under(mMB, "Sound");
	VALUE mFastReverb = rb_define_module_under(mSound, "FastReverb");
	VALUE cNetwork = rb_define_class_under(mFastReverb, "Network", rb_cObject);

	rb_define_alloc_func(cNetwork, rev_alloc);
	rb_define_method(cNetwork, "initialize", rev_initialize, 1);
	rb_define_method(cNetwork, "process", rev_process, 4);
	rb_define_method(cNetwork, "position", rev_position, 0);
	rb_define_method(cNetwork, "lfo_values", rev_lfo_values, 0);

	rb_define_const(mFastReverb, "LFO_STEP", INT2NUM(LFO_STEP));
	rb_define_const(mFastReverb, "PARAM_COUNT", INT2NUM(P_COUNT));
}
