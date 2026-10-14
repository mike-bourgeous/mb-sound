/*
 * MB::Sound::FastTexture: random texture kernels (GraphNode::Dust and
 * GraphNode::Drift).
 *
 * dust(out, rate, rng, sample_rate, lo, hi): sparse random impulses, about
 * +rate+ per second (SuperCollider's Dust/Dust2).  Every sample draws one
 * uniform number u from the splitmix64 state in +rng+ (a one-value
 * Numo::UInt64; the same generator as the noise oscillators), and the
 * sample is an impulse when u < p = rate / sample_rate (clamped to 0..1),
 * with height lo + (hi - lo) * u / p (uniform over lo..hi), else 0.  One
 * draw per sample whatever the rate, so the impulses fall on the same
 * samples at any buffer size and the rate may move every sample.
 *
 * drift(out, rate, state, rng, sample_rate, lo, hi, mode, walk): a slow
 * random line through random points, +rate+ new points per second (a
 * phase accumulator; a phase reaching 1 within 1e-9 counts, so rates that
 * divide the sample rate step exactly), interpolated by +mode+: 0 step (the
 * sample-and-hold flavor: each point held for its step), 1 linear, 2
 * cosine, 3 cubic (a uniform cubic B-spline over four points: smooth in
 * value, slope, and curvature, and never outside lo..hi since each output
 * is a weighted average of points).  Points are unit values 0...1 mapped to
 * lo..hi on output.  +walk+ > 0 makes each new point a step of up to +walk+
 * (a fraction of the range, at most 1) from the last, reflected at the
 * ends (a bounded random walk); 0 draws independent points.  +state+ is a
 * DFloat [phase, p0, p1, p2, p3] updated in place: the output moves from p1
 * to p2 over a step (the B-spline uses p0 and p3 as well).
 *
 * The Ruby mirrors (GraphNode::Dust.process_ruby, GraphNode::Drift
 * .process_ruby) give exactly the same samples (specs check it), so keep the
 * operations identical; built with -ffp-contract=off.
 */

#include <math.h>
#include <stdint.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

#define DRIFT_STATE_LENGTH 5

// Phases this close below a whole cycle count as reaching it (as in
// FastLofi.decimate), so 1 point per second at 48 kHz steps every 48000
// samples exactly despite rounding.
#define DRIFT_EDGE 1e-9

enum drift_mode {
	DRIFT_STEP = 0,
	DRIFT_LINEAR = 1,
	DRIFT_COSINE = 2,
	DRIFT_CUBIC = 3,
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
 *   MB::Sound::FastTexture.dust(out, rate, rng, sample_rate, lo, hi) -> out
 *
 * See the file comment.  +rate+ is a signal input (a Numeric or an NArray of
 * out.length values, read as float32).
 */
static VALUE ruby_dust(VALUE self, VALUE out, VALUE rate, VALUE rng, VALUE sample_rate, VALUE lo_v, VALUE hi_v)
{
	check_output(out);
	uint64_t *rp = rng_pointer(rng);
	double fs = positive_rate(sample_rate);
	double lo = NUM2DBL(lo_v);
	double span = NUM2DBL(hi_v) - lo;

	size_t length = RNARRAY_SHAPE(out)[0];
	struct mb_signal rs;
	mb_signal_input(&rate, length, "The rate", &rs);

	float *op = mb_sfloat_ptr(out);
	for (size_t i = 0; i < length; i++) {
		double p = texture_increment(mb_signal_at(&rs, i), fs);
		double u = texture_random(rp);
		op[i] = u < p ? (float)(lo + span * (u / p)) : 0.0f;
	}

	RB_GC_GUARD(rate);
	return out;
}

/*
 * call-seq:
 *   MB::Sound::FastTexture.drift(out, rate, state, rng, sample_rate, lo, hi, mode, walk) -> out
 *
 * See the file comment.  +rate+ is a signal input (points per second).
 */
static VALUE ruby_drift(VALUE self, VALUE out, VALUE rate, VALUE state, VALUE rng, VALUE sample_rate, VALUE lo_v, VALUE hi_v, VALUE mode_v, VALUE walk_v)
{
	check_output(out);
	if (CLASS_OF(state) != numo_cDFloat || RNARRAY_NDIM(state) != 1 || RNARRAY_SHAPE(state)[0] != DRIFT_STATE_LENGTH ||
			!RTEST(nary_check_contiguous(state))) {
		rb_raise(rb_eArgError, "The state must be a contiguous DFloat of %d values", DRIFT_STATE_LENGTH);
	}
	rb_check_frozen(state);
	uint64_t *rp = rng_pointer(rng);
	double fs = positive_rate(sample_rate);
	double lo = NUM2DBL(lo_v);
	double span = NUM2DBL(hi_v) - lo;
	int mode = NUM2INT(mode_v);
	if (mode < DRIFT_STEP || mode > DRIFT_CUBIC) {
		rb_raise(rb_eArgError, "The mode must be 0 (step), 1 (linear), 2 (cosine), or 3 (cubic)");
	}
	double walk = NUM2DBL(walk_v);
	if (!(walk >= 0 && walk <= 1)) {
		rb_raise(rb_eArgError, "The walk must be from 0 to 1");
	}

	size_t length = RNARRAY_SHAPE(out)[0];
	struct mb_signal rs;
	mb_signal_input(&rate, length, "The rate", &rs);

	float *op = mb_sfloat_ptr(out);
	double *st = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));
	double phase = st[0];
	double p0 = st[1], p1 = st[2], p2 = st[3], p3 = st[4];

	for (size_t i = 0; i < length; i++) {
		double t = phase;
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

			default: {
				double t2 = t * t;
				double t3 = t2 * t;
				double s = 1.0 - t;
				y = (s * s * s * p0 + (3.0 * t3 - 6.0 * t2 + 4.0) * p1 + (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) * p2 + t3 * p3) / 6.0;
				break;
			}
		}
		op[i] = (float)(lo + span * y);

		phase += texture_increment(mb_signal_at(&rs, i), fs);
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
		}
	}

	st[0] = phase;
	st[1] = p0;
	st[2] = p1;
	st[3] = p2;
	st[4] = p3;

	RB_GC_GUARD(rate);
	return out;
}

void Init_fast_texture(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_texture = rb_define_module_under(sound, "FastTexture");

	rb_define_module_function(fast_texture, "dust", ruby_dust, 6);
	rb_define_module_function(fast_texture, "drift", ruby_drift, 9);
}
