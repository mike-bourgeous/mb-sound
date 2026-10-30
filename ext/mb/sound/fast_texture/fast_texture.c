/*
 * MB::Sound::FastTexture: random texture kernels (GraphNode::Dust and
 * GraphNode::Drift).
 *
 * dust(out, rate, rng, sample_rate, lo, hi, gap, since): sparse random
 * impulses, about +rate+ per second (SuperCollider's Dust/Dust2).  Every
 * sample draws one uniform number u from the splitmix64 state in +rng+ (a
 * one-value Numo::UInt64; the same generator as the noise oscillators), and
 * the sample is an impulse when u < p = rate / sample_rate (clamped to
 * 0..1), with height lo + (hi - lo) * u / p (uniform over lo..hi), else 0.
 * One draw per sample whatever the rate, so the impulses fall on the same
 * samples at any buffer size and the rate may move every sample.
 *
 * +gap+ (a signal input in samples; 0 for none) is the shortest spacing
 * between impulses: an impulse may come only once +since+ (a one-value
 * DFloat: samples since the last impulse, updated in place; infinite at
 * the start) reaches it.  So the rate stays the average, the chance per
 * allowed sample grows to p / (1 - p d) for the d = ceil(gap) - 1 samples
 * each impulse shuts out (1 once p d reaches 1: impulses exactly every
 * ceil(gap) samples), and heights use that chance in place of p.
 *
 * drift(out, rate, state, rng, sample_rate, lo, hi, mode, walk, table,
 * hold_lo, hold_hi, hold_kind, jitter): a slow random line through random
 * points, +rate+ new points per second on average (a phase accumulator; a
 * phase reaching 1 within 1e-9 counts, so rates that divide the sample rate
 * step exactly), interpolated by +mode+: 0 step (the sample-and-hold
 * flavor: each point held for its step), 1 linear, 2 cosine, 3 cubic (a
 * uniform cubic B-spline over four points: smooth in value, slope, and
 * curvature, and never outside lo..hi since each output is a weighted
 * average of points), 4 curve (p1 + (p2 - p1) c(t) for the tweening curve
 * whose value table is +table+, an Array of four DFloats as
 * MB::Sound::Curve#value_table gives; see mb_curve_lookup.h; curves that
 * overshoot leave lo..hi, unclamped).  Points are unit values 0...1 mapped
 * to lo..hi on output.  +walk+ > 0 makes each new point a step of up to
 * +walk+ (a fraction of the range, at most 1) from the last, reflected at
 * the ends (a bounded random walk); 0 draws independent points.
 *
 * Three random streams in +rng+ (a three-value UInt64), so each choice
 * leaves the others' draws alone: [0] the points, [1] holds, [2] spacing.
 * At the first sample of each step (and the very first sample), if
 * +jitter+ is given, the step's length in average steps is drawn as (1 -
 * j) + j E (E exponential with mean 1, from stream 2; j the jitter at that
 * sample, clamped to 0..1; at least 1e-3), so 0 is even spacing, 1
 * Poisson-like spacing, and the mean rate stays +rate+; the phase then
 * advances by the increment over that length (at most 1 per sample).  If a
 * hold range is given, a hold is drawn uniformly from hold_lo..hold_hi at
 * that sample (stream 1): a share of the step (+hold_kind+ 0) or samples
 * (1, divided by the step's length), clamped to 0..1.  The segment's
 * position is 0 until the phase reaches the hold, then (phase - hold) / (1
 * - hold), so the line rests on each point for the hold before moving.
 *
 * +state+ is a DFloat [phase, p0, p1, p2, p3, hold, speed] updated in
 * place: the output moves from p1 to p2 over a step (the B-spline uses p0
 * and p3 as well); hold and speed are NaN until the first sample draws
 * them.
 *
 * noise_skip(phase, noise, frequency, advance, random_advance, count): moves
 * a noise Tone's phase (+phase+, a Ruby Array whose first element is the
 * phase in cycles, Tone::State#phase) and splitmix64 generator state
 * (+noise+, an Array of one Integer, Tone::State#noise) on by +count+
 * samples at the constant +frequency+, as the noise path of
 * FastSound.phasor/oscillate (and the plan executor's naive tones) would
 * render them: each sample draws u and adds frequency * (advance + u *
 * random_advance) to the phase, wrapped to 0...1.  For a sleeping voice's
 * catch-up (Tone#catch_up_noise, NodeTraits' +random+ trait), so a voice
 * that slept draws the noise it would have drawn awake.
 *
 * The Ruby mirrors (GraphNode::Dust.process_ruby, GraphNode::Drift
 * .process_ruby, Tone.noise_skip_ruby) give exactly the same samples (specs
 * check it), so keep the operations identical; built with
 * -ffp-contract=off.
 */

#include <math.h>
#include <stdint.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_curve_lookup.h"

#define DRIFT_STATE_LENGTH 7

// The shortest step drift's spacing jitter allows, in average steps.
#define DRIFT_MIN_LENGTH 1e-3

// Phases this close below a whole cycle count as reaching it (as in
// FastLofi.decimate), so 1 point per second at 48 kHz steps every 48000
// samples exactly despite rounding.
#define DRIFT_EDGE 1e-9

enum drift_mode {
	DRIFT_STEP = 0,
	DRIFT_LINEAR = 1,
	DRIFT_COSINE = 2,
	DRIFT_CUBIC = 3,
	DRIFT_CURVE = 4,
};

// The next uniform random number in 0...1 from the splitmix64 state *s (53
// bits; the same generator as noise_random in mb_osc_shapes.h, mirrored by
// MB::Sound::Tone.noise_random).
static inline double texture_random(uint64_t *s)
{
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	z ^= z >> 31;
	return (double)(z >> 11) * 0x1.0p-53;
}

// The share of a step (rate / sample rate), 0 for zero, negative, or NaN
// rates, at most 1.
static inline double texture_increment(double rate, double fs)
{
	double inc = rate / fs;
	if (!(inc > 0)) {
		return 0;
	}
	return inc > 1.0 ? 1.0 : inc;
}

static void check_output(VALUE out)
{
	if (CLASS_OF(out) != numo_cSFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "The output must be a contiguous 1D SFloat");
	}
	rb_check_frozen(out);
}

static uint64_t *rng_pointer(VALUE rng)
{
	if (CLASS_OF(rng) != numo_cUInt64 || RNARRAY_NDIM(rng) != 1 || RNARRAY_SHAPE(rng)[0] != 1 || !RTEST(nary_check_contiguous(rng))) {
		rb_raise(rb_eArgError, "The random state must be a contiguous one-value UInt64");
	}
	rb_check_frozen(rng);
	return (uint64_t *)(nary_get_pointer_for_write(rng) + nary_get_offset(rng));
}

// A contiguous one-dimensional DFloat of +length+ values (states and
// curve tables), for writing if +write+.
static double *dfloat_values(VALUE v, size_t length, const char *name, _Bool write)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || RNARRAY_SHAPE(v)[0] != length || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "%s must be a contiguous DFloat of %zu values", name, length);
	}
	if (write) {
		rb_check_frozen(v);
		return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
	}
	return (double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

static double positive_rate(VALUE sample_rate)
{
	double fs = NUM2DBL(sample_rate);
	if (!(fs > 0)) {
		rb_raise(rb_eArgError, "The sample rate must be positive");
	}
	return fs;
}

/*
 * call-seq:
 *   MB::Sound::FastTexture.dust(out, rate, rng, sample_rate, lo, hi, gap, since) -> out
 *
 * See the file comment.  +rate+ and +gap+ are signal inputs (a Numeric or
 * an NArray of out.length values, read as float32).
 */
static VALUE ruby_dust(VALUE self, VALUE out, VALUE rate, VALUE rng, VALUE sample_rate, VALUE lo_v, VALUE hi_v, VALUE gap, VALUE since_v)
{
	check_output(out);
	uint64_t *rp = rng_pointer(rng);
	double fs = positive_rate(sample_rate);
	double lo = NUM2DBL(lo_v);
	double span = NUM2DBL(hi_v) - lo;

	size_t length = RNARRAY_SHAPE(out)[0];
	struct mb_signal rs;
	mb_signal_input(&rate, length, "The rate", &rs);
	struct mb_signal gs;
	mb_signal_input(&gap, length, "The gap", &gs);
	double *since = dfloat_values(since_v, 1, "The gap state", 1);
	double s = since[0];

	float *op = mb_sfloat_ptr(out);
	for (size_t i = 0; i < length; i++) {
		double p = texture_increment(mb_signal_at(&rs, i), fs);
		double u = texture_random(rp);
		double g = mb_signal_at(&gs, i);
		if (!(g > 0)) {
			g = 0;
		}
		double dead = g > 1.0 ? ceil(g) - 1.0 : 0.0;
		float y = 0.0f;
		s += 1.0;
		if (s >= g) {
			double q = p;
			if (dead > 0) {
				q = p * dead < 1.0 ? p / (1.0 - p * dead) : 1.0;
			}
			if (u < q) {
				y = (float)(lo + span * (u / q));
				s = 0.0;
			}
		}
		op[i] = y;
	}
	since[0] = s;

	RB_GC_GUARD(rate);
	RB_GC_GUARD(gap);
	RB_GC_GUARD(since_v);
	return out;
}

// The share of the step in which drift moves at the next sample: the
// hold drawn for the step (see the file comment).  +u+ is a uniform draw
// from the hold stream, +lo+ and +hi+ the hold range at this sample, +kind+
// 1 for samples (else shares), +inc+ the step's share of a sample.
static inline double drift_hold(double u, double lo, double hi, int kind, double inc)
{
	double h = lo + (hi - lo) * u;
	if (kind) {
		h *= inc;
	}
	if (!(h > 0)) {
		return 0.0;
	}
	return h > 1.0 ? 1.0 : h;
}

// The speed of the next step (1 / its length in average steps) for
// spacing jitter +j+ (0..1) and a uniform draw +u+ from the spacing stream.
static inline double drift_speed(double u, double j)
{
	if (!(j > 0)) {
		return 1.0;
	}
	if (j > 1.0) {
		j = 1.0;
	}
	double len = (1.0 - j) + j * -log(1.0 - u);
	if (len < DRIFT_MIN_LENGTH) {
		len = DRIFT_MIN_LENGTH;
	}
	return 1.0 / len;
}

/*
 * call-seq:
 *   MB::Sound::FastTexture.drift(out, rate, state, rng, sample_rate, lo, hi, mode, walk, table, hold_lo, hold_hi, hold_kind, jitter) -> out
 *
 * See the file comment.  +rate+, +hold_lo+, +hold_hi+, and +jitter+ are
 * signal inputs (nil holds are no hold; nil jitter is even spacing).
 * +table+ is nil unless +mode+ is 4 (curve).
 */
static VALUE ruby_drift(VALUE self, VALUE out, VALUE rate, VALUE state, VALUE rng, VALUE sample_rate, VALUE lo_v, VALUE hi_v, VALUE mode_v, VALUE walk_v,
		VALUE table_v, VALUE hold_lo_v, VALUE hold_hi_v, VALUE hold_kind_v, VALUE jitter_v)
{
	check_output(out);
	double *st = dfloat_values(state, DRIFT_STATE_LENGTH, "The state", 1);
	if (CLASS_OF(rng) != numo_cUInt64 || RNARRAY_NDIM(rng) != 1 || RNARRAY_SHAPE(rng)[0] != 3 || !RTEST(nary_check_contiguous(rng))) {
		rb_raise(rb_eArgError, "The random state must be a contiguous UInt64 of three values (points, holds, spacing)");
	}
	rb_check_frozen(rng);
	uint64_t *rp = (uint64_t *)(nary_get_pointer_for_write(rng) + nary_get_offset(rng));
	double fs = positive_rate(sample_rate);
	double lo = NUM2DBL(lo_v);
	double span = NUM2DBL(hi_v) - lo;
	int mode = NUM2INT(mode_v);
	if (mode < DRIFT_STEP || mode > DRIFT_CURVE) {
		rb_raise(rb_eArgError, "The mode must be 0 (step), 1 (linear), 2 (cosine), 3 (cubic), or 4 (curve)");
	}
	double walk = NUM2DBL(walk_v);
	if (!(walk >= 0 && walk <= 1)) {
		rb_raise(rb_eArgError, "The walk must be from 0 to 1");
	}
	int hold_kind = NUM2INT(hold_kind_v);
	_Bool holds = !NIL_P(hold_lo_v) || !NIL_P(hold_hi_v);
	_Bool jitters = !NIL_P(jitter_v);

	struct mb_curve_table curve = { NULL, NULL, NULL, NULL, 0 };
	if (mode == DRIFT_CURVE) {
		if (!RB_TYPE_P(table_v, T_ARRAY) || RARRAY_LEN(table_v) != 4) {
			rb_raise(rb_eArgError, "A curve drift needs a curve table: an Array of four DFloats (Curve#value_table)");
		}
		VALUE first = rb_ary_entry(table_v, 0);
		if (CLASS_OF(first) != numo_cDFloat || RNARRAY_NDIM(first) != 1 || RNARRAY_SHAPE(first)[0] < 2) {
			rb_raise(rb_eArgError, "Curve tables must be DFloats of at least two values");
		}
		size_t nodes = RNARRAY_SHAPE(first)[0];
		curve.fl = dfloat_values(first, nodes, "The curve's left values", 0);
		curve.fr = dfloat_values(rb_ary_entry(table_v, 1), nodes, "The curve's right values", 0);
		curve.dl = dfloat_values(rb_ary_entry(table_v, 2), nodes, "The curve's left slopes", 0);
		curve.dr = dfloat_values(rb_ary_entry(table_v, 3), nodes, "The curve's right slopes", 0);
		curve.cells = nodes - 1;
	}

	size_t length = RNARRAY_SHAPE(out)[0];
	struct mb_signal rs, hls, hhs, js;
	mb_signal_input(&rate, length, "The rate", &rs);
	mb_signal_input(&hold_lo_v, length, "The shortest hold", &hls);
	mb_signal_input(&hold_hi_v, length, "The longest hold", &hhs);
	mb_signal_input(&jitter_v, length, "The jitter", &js);

	float *op = mb_sfloat_ptr(out);
	double phase = st[0];
	double p0 = st[1], p1 = st[2], p2 = st[3], p3 = st[4];
	double hold = st[5], speed = st[6];

	for (size_t i = 0; i < length; i++) {
		double inc = texture_increment(mb_signal_at(&rs, i), fs);

		// The first step's spacing and hold, read at its first sample
		if (isnan(speed)) {
			speed = jitters ? drift_speed(texture_random(rp + 2), mb_signal_at(&js, i)) : 1.0;
		}
		if (isnan(hold)) {
			hold = holds ? drift_hold(texture_random(rp + 1), mb_signal_at(&hls, i), mb_signal_at(&hhs, i), hold_kind, inc * speed) : 0.0;
		}

		double t = phase;
		if (hold > 0) {
			t = t < hold ? 0.0 : (t - hold) / (1.0 - hold);
		}
		double y;
		switch (mode) {
			case DRIFT_STEP:
				y = p1;
				break;

			case DRIFT_LINEAR:
				y = p1 + (p2 - p1) * t;
				break;

			case DRIFT_COSINE:
				y = p1 + (p2 - p1) * ((1.0 - cos(M_PI * t)) * 0.5);
				break;

			case DRIFT_CURVE:
				y = p1 + (p2 - p1) * mb_curve_lookup(&curve, t);
				break;

			default: {
				double t2 = t * t;
				double t3 = t2 * t;
				double s = 1.0 - t;
				y = (s * s * s * p0 + (3.0 * t3 - 6.0 * t2 + 4.0) * p1 + (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) * p2 + t3 * p3) / 6.0;
				break;
			}
		}
		op[i] = (float)(lo + span * y);

		double d = inc * speed;
		phase += d > 1.0 ? 1.0 : d;
		if (phase >= 1.0 - DRIFT_EDGE) {
			phase -= mb_floor(phase + DRIFT_EDGE);
			if (phase < 0) {
				phase = 0;
			}

			double u = texture_random(rp);
			double v;
			if (walk > 0) {
				v = p3 + walk * (2.0 * u - 1.0);
				if (v < 0) {
					v = -v;
				} else if (v > 1.0) {
					v = 2.0 - v;
				}
			} else {
				v = u;
			}
			p0 = p1;
			p1 = p2;
			p2 = p3;
			p3 = v;

			if (jitters) {
				speed = drift_speed(texture_random(rp + 2), mb_signal_at(&js, i));
			}
			if (holds) {
				hold = drift_hold(texture_random(rp + 1), mb_signal_at(&hls, i), mb_signal_at(&hhs, i), hold_kind, inc * speed);
			}
		}
	}

	st[0] = phase;
	st[1] = p0;
	st[2] = p1;
	st[3] = p2;
	st[4] = p3;
	st[5] = hold;
	st[6] = speed;

	RB_GC_GUARD(rate);
	RB_GC_GUARD(table_v);
	RB_GC_GUARD(hold_lo_v);
	RB_GC_GUARD(hold_hi_v);
	RB_GC_GUARD(jitter_v);
	return out;
}

/*
 * See noise_skip at the top of the file.  Returns nil.
 */
static VALUE ruby_noise_skip(VALUE self, VALUE phase, VALUE noise, VALUE frequency, VALUE advance, VALUE random_advance, VALUE count)
{
	Check_Type(phase, T_ARRAY);
	Check_Type(noise, T_ARRAY);
	if (RARRAY_LEN(phase) < 1 || RARRAY_LEN(noise) != 1) {
		rb_raise(rb_eArgError, "noise_skip needs a phase state Array and a one-Integer noise state Array");
	}
	long n = NUM2LONG(count);
	if (n < 0) {
		rb_raise(rb_eArgError, "noise_skip count must not be negative (got %ld)", n);
	}

	double phi = NUM2DBL(rb_ary_entry(phase, 0));
	uint64_t rng = NUM2ULL(rb_ary_entry(noise, 0));
	double freq = NUM2DBL(frequency);
	double adv = NUM2DBL(advance);
	double rndadv = NUM2DBL(random_advance);

	for (long i = 0; i < n; i++) {
		// (phasor_increment in mb_osc_shapes.h, in separate statements)
		double r = texture_random(&rng) * rndadv;
		double a = adv + r;
		double inc = freq * a;
		phi = mb_wrap(phi + inc, 1.0);
	}

	rb_ary_store(phase, 0, rb_float_new(mb_wrap(phi, 1.0)));
	rb_ary_store(noise, 0, ULL2NUM(rng));
	return Qnil;
}

void Init_fast_texture(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_texture = rb_define_module_under(sound, "FastTexture");

	rb_define_module_function(fast_texture, "dust", ruby_dust, 8);
	rb_define_module_function(fast_texture, "drift", ruby_drift, 14);
	rb_define_module_function(fast_texture, "noise_skip", ruby_noise_skip, 6);
}
