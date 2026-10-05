/*
 * MB::Sound::FastEnvelope: the envelope generator kernel behind
 * MB::Sound::Envelope (lib/mb/sound/envelope.rb), a state machine that
 * plays a list of curved segments.
 *
 * Stages: idle, segment (attack, decay, ..., release), sustain, ended (a
 * one-shot that has finished), choke (a fast linear release to 0), and
 * pending (a one-shot that starts on its next sample).  The segments before
 * +release_node+ lead up to the sustain level (the level of the segment just
 * before it); the segments from +release_node+ on are the release.  ADSR
 * uses three segments (attack to 1, decay to the sustain level, release to
 * 0) with a release node of 2, so later multi-segment envelopes (levels,
 * times, curves, release node) need no kernel changes.
 *
 * Each segment moves from its start level to its target over its length in
 * samples (rounded to whole samples), along a curve given in signed dB, d:
 *   c = d * curve_scale (curve_scale = -ln(10) / 20)
 *   p(x) = (1 - e^(c x)) / (1 - e^c), or x if c = 0, for x in 0..1
 *   level = start + (target - start) * p(x)
 * so d > 0 moves fast first, d < 0 slowly first, and d = 0 is linear.  The
 * segment lands exactly on its target on its last sample.  Per sample, the
 * curve is the one-pole recursion w *= g with level = y0 + scale * (1 - w).
 *
 * When a segment's length, curve, or target changes (graph node
 * parameters), the rest of the segment is re-planned from the last output
 * level, keeping the original curvature for the part of the segment left
 * (the remainder of a curve with curvature c from x0 is a curve with
 * curvature c * (1 - x0)), so the level stays continuous.  Constant
 * parameters are planned once per segment (two exp() calls).
 *
 * The Ruby mirror is MB::Sound::Envelope.process_ruby; specs check that both
 * give exactly the same samples, so keep the operations identical (this
 * extension is built with -ffp-contract=off so clang doesn't fuse them).
 */

#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

// The most segments an envelope may have.
#define ENV_MAX_SEGMENTS 16

// The remaining curvature below which a segment is planned as a line.
#define ENV_LINEAR_LIMIT 1e-9

enum env_stage {
	ENV_IDLE = 0,
	ENV_SEGMENT = 1,
	ENV_SUSTAIN = 2,
	ENV_ENDED = 3,
	ENV_CHOKE = 4,
	ENV_PENDING = 5,
};

// Indices into the state DFloat (MB::Sound::Envelope::STATE_* constants).
enum env_state_index {
	ST_STAGE,
	ST_SEGMENT,
	ST_POSITION,       // samples since the start of the stage
	ST_LEVEL,          // the last output level (before the octave transform)
	ST_PEAK,           // velocity scale of the current note
	ST_GATE,           // whether the gate was high on the last sample
	ST_PLANNED,        // whether the plan below is valid
	ST_PLAN_LENGTH,    // the parameters the plan was made for
	ST_PLAN_CURVE,
	ST_PLAN_TARGET,
	ST_ANCHOR_POSITION,
	ST_ANCHOR_LEVEL,
	ST_SCALE,          // slope (linear) or curve scale
	ST_W,
	ST_G,
	ST_LINEAR,
	ST_TRIGGER,        // whether the trigger was > 0 on the last sample
	ST_NOTE_POSITION,  // samples since the note started (for hold)
	ST_RELEASE_SCALE,  // release time multiplier from lift (1 without)
	ST_SIZE
};

// Indices into the config Array.
enum env_config_index {
	CF_FLAGS,
	CF_RELEASE_NODE,
	CF_VELOCITY_LOW,
	CF_VELOCITY_HIGH,
	CF_VELOCITY_DB,
	CF_CHOKE_SAMPLES,
	CF_CURVE_SCALE,
	CF_SIZE
};

enum env_flags {
	ENV_HAS_GATE = 1,
	ENV_HAS_TRIGGER = 2,
	ENV_ONE_SHOT = 4,
	ENV_LEGATO = 8,
	ENV_OCTAVES = 16,
	ENV_LIFT = 32,
	ENV_ADD = 64,     // retrigger peaks add to the current level (energy sum)
};

// A parameter or input: a constant, or a float or double per sample.
struct env_signal {
	double scalar;
	const float *f;
	const double *d;
};

static inline double env_at(const struct env_signal *s, size_t i)
{
	if (s->f) {
		return s->f[i];
	}
	if (s->d) {
		return s->d[i];
	}
	return s->scalar;
}

// Reads a parameter or input: nil (+nil_value+), a Numeric, or a 1D SFloat
// or DFloat (other NArrays are cast to DFloat) of +length+ values.  NArrays
// that had to be converted are kept alive in +keep+.
static void env_read_signal(VALUE v, size_t length, const char *name, double nil_value, VALUE keep, struct env_signal *s)
{
	s->scalar = nil_value;
	s->f = NULL;
	s->d = NULL;

	if (NIL_P(v)) {
		return;
	}

	if (!rb_obj_is_kind_of(v, cNArray)) {
		s->scalar = NUM2DBL(v);
		return;
	}

	if (RNARRAY_NDIM(v) != 1) {
		rb_raise(rb_eArgError, "%s must be a 1D NArray", name);
	}
	if (RNARRAY_SHAPE(v)[0] != length) {
		rb_raise(rb_eArgError, "%s length %zu does not match the output length %zu", name, (size_t)RNARRAY_SHAPE(v)[0], length);
	}

	if (CLASS_OF(v) != numo_cSFloat && CLASS_OF(v) != numo_cDFloat) {
		v = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, v);
	}
	if (!RTEST(nary_check_contiguous(v))) {
		v = nary_dup(v);
	}
	rb_ary_push(keep, v);

	if (CLASS_OF(v) == numo_cSFloat) {
		s->f = (const float *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	} else {
		s->d = (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	}
}

// A segment length in whole samples: 0 for negative or NaN lengths,
// infinity stays infinite.
static double env_length(double t)
{
	if (!(t > 0)) {
		return 0;
	}
	if (isinf(t)) {
		return t;
	}
	return round(t);
}

// The release time multiplier for release velocity +lift+ (clamped to
// 0..1): 2 ** ((0.5 - lift) * 2), so 0.5 (MIDI 64) is neutral, 0 doubles the
// release time, and 1 halves it.
static double env_lift_scale(double lift)
{
	if (!(lift >= 0)) {
		lift = 0;
	}
	if (lift > 1) {
		lift = 1;
	}

	return pow(2.0, (0.5 - lift) * 2.0);
}

// The peak level for velocity +v+ (clamped to 0..1).
static double env_peak(double v, double low, double high, int db)
{
	if (!(v >= 0)) {
		v = 0;
	}
	if (v > 1) {
		v = 1;
	}

	if (db) {
		return low * pow(high / low, v);
	}

	return low + (high - low) * v;
}

// How far a retrigger with ENV_ADD may rise above its own velocity peak:
// sqrt(2), two equal strikes summed in energy (MB::Sound::Envelope::ADD_LIMIT).
#define ENV_ADD_LIMIT 1.4142135623730951

// The peak of a note that starts at level +y+ with velocity peak +p+ when
// the ENV_ADD flag is set: the energy sum sqrt(y^2 + p^2), at most
// ENV_ADD_LIMIT * p and the loudest velocity's peak (the larger of |low|
// and |high|), but never below the current level.  So a retrigger never
// attacks downward, and a roll of equal strikes levels off at sqrt(2)
// times one strike's peak (+3 dB) from the second strike on.
static double env_add_peak(double y, double p, double low, double high)
{
	double a = fabs(y);
	double sum = sqrt(a * a + p * p);
	double vmax = fabs(low) > fabs(high) ? fabs(low) : fabs(high);
	double cap = p * ENV_ADD_LIMIT;
	if (cap > vmax) {
		cap = vmax;
	}
	if (a > cap) {
		cap = a;
	}
	return sum > cap ? cap : sum;
}

/*
 * Runs the envelope for one buffer:
 *   process(out, state, times, curves, levels, hold, inputs, config)
 * +out+ is a contiguous SFloat written in place (and returned).  +state+ is
 * a contiguous DFloat of ST_SIZE values, updated in place.  +times+ (in
 * samples), +curves+ (in dB), and +levels+ (relative to the peak) are
 * Arrays with one entry per segment, each a Numeric or an NArray of
 * out.length values.  +hold+ is how long notes of envelopes without a gate
 * last before releasing, counted from the note start, in samples (Numeric
 * or NArray).  +inputs+ is [gate, trigger, velocity, choke, lift, octaves],
 * each nil, a Numeric, or an NArray (lift and octaves are used only with
 * the ENV_LIFT and ENV_OCTAVES flags).  +config+ is [flags, release node,
 * velocity low, velocity high, velocity in dB (0 or 1), choke samples,
 * curve scale] (see MB::Sound::Envelope#kernel_config).
 *
 * With the ENV_ADD flag, a note's peak is env_add_peak of the level when
 * it starts and its velocity's peak (Envelope retrigger: :add).
 *
 * Triggers fire on rising edges: a sample > 0 after a sample <= 0
 * (negative values are reserved).  A release starts with its time scaled
 * by env_lift_scale of the lift input on that sample.
 */
static VALUE ruby_process(VALUE self, VALUE out, VALUE state, VALUE times, VALUE curves, VALUE levels, VALUE hold, VALUE inputs, VALUE config)
{
	if (CLASS_OF(out) != numo_cSFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "Output must be a contiguous 1D SFloat");
	}
	if (CLASS_OF(state) != numo_cDFloat || RNARRAY_NDIM(state) != 1 || RNARRAY_SHAPE(state)[0] != ST_SIZE || !RTEST(nary_check_contiguous(state))) {
		rb_raise(rb_eArgError, "State must be a contiguous DFloat of %d values", ST_SIZE);
	}

	Check_Type(times, T_ARRAY);
	Check_Type(curves, T_ARRAY);
	Check_Type(levels, T_ARRAY);
	Check_Type(inputs, T_ARRAY);
	Check_Type(config, T_ARRAY);

	long nseg = RARRAY_LEN(times);
	if (nseg < 2 || nseg > ENV_MAX_SEGMENTS || RARRAY_LEN(curves) != nseg || RARRAY_LEN(levels) != nseg) {
		rb_raise(rb_eArgError, "Times, curves, and levels must have the same number of segments (2 to %d)", ENV_MAX_SEGMENTS);
	}
	if (RARRAY_LEN(inputs) != 6) {
		rb_raise(rb_eArgError, "Inputs must be [gate, trigger, velocity, choke, lift, octaves]");
	}
	if (RARRAY_LEN(config) != CF_SIZE) {
		rb_raise(rb_eArgError, "Config must have %d values", CF_SIZE);
	}

	int flags = NUM2INT(rb_ary_entry(config, CF_FLAGS));
	long release_node = NUM2LONG(rb_ary_entry(config, CF_RELEASE_NODE));
	double velocity_low = NUM2DBL(rb_ary_entry(config, CF_VELOCITY_LOW));
	double velocity_high = NUM2DBL(rb_ary_entry(config, CF_VELOCITY_HIGH));
	int velocity_db = NUM2INT(rb_ary_entry(config, CF_VELOCITY_DB));
	double choke_samples = env_length(NUM2DBL(rb_ary_entry(config, CF_CHOKE_SAMPLES)));
	double curve_scale = NUM2DBL(rb_ary_entry(config, CF_CURVE_SCALE));

	if (release_node < 1 || release_node >= nseg) {
		rb_raise(rb_eArgError, "Release node must be from 1 to %ld", nseg - 1);
	}
	if (velocity_db && !(velocity_low > 0 && velocity_high > 0)) {
		rb_raise(rb_eArgError, "Velocity gains must be positive for dB scaling");
	}

	int has_gate = !!(flags & ENV_HAS_GATE);
	int has_trigger = !!(flags & ENV_HAS_TRIGGER);
	int one_shot = !!(flags & ENV_ONE_SHOT);
	int legato = !!(flags & ENV_LEGATO);
	int use_octaves = !!(flags & ENV_OCTAVES);
	int has_lift = !!(flags & ENV_LIFT);
	int add = !!(flags & ENV_ADD);

	size_t n = RNARRAY_SHAPE(out)[0];
	VALUE keep = rb_ary_new();

	struct env_signal seg_times[ENV_MAX_SEGMENTS], seg_curves[ENV_MAX_SEGMENTS], seg_levels[ENV_MAX_SEGMENTS];
	for (long s = 0; s < nseg; s++) {
		env_read_signal(rb_ary_entry(times, s), n, "Segment time", 0, keep, &seg_times[s]);
		env_read_signal(rb_ary_entry(curves, s), n, "Segment curve", 0, keep, &seg_curves[s]);
		env_read_signal(rb_ary_entry(levels, s), n, "Segment level", 0, keep, &seg_levels[s]);
	}

	struct env_signal hold_sig, gate_sig, trigger_sig, velocity_sig, choke_sig, lift_sig, octaves_sig;
	env_read_signal(hold, n, "Hold", 0, keep, &hold_sig);
	env_read_signal(rb_ary_entry(inputs, 0), n, "Gate", 0, keep, &gate_sig);
	env_read_signal(rb_ary_entry(inputs, 1), n, "Trigger", 0, keep, &trigger_sig);
	env_read_signal(rb_ary_entry(inputs, 2), n, "Velocity", 1, keep, &velocity_sig);
	env_read_signal(rb_ary_entry(inputs, 3), n, "Choke", 0, keep, &choke_sig);
	env_read_signal(rb_ary_entry(inputs, 4), n, "Lift", 0.5, keep, &lift_sig);
	env_read_signal(rb_ary_entry(inputs, 5), n, "Octaves", 0, keep, &octaves_sig);

	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	double *st = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));

	int stage = (int)st[ST_STAGE];
	long seg = (long)st[ST_SEGMENT];
	double e = st[ST_POSITION];
	double y = st[ST_LEVEL];
	double peak = st[ST_PEAK];
	int gate_prev = st[ST_GATE] != 0;
	int planned = st[ST_PLANNED] != 0;
	double plan_length = st[ST_PLAN_LENGTH];
	double plan_curve = st[ST_PLAN_CURVE];
	double plan_target = st[ST_PLAN_TARGET];
	double e0 = st[ST_ANCHOR_POSITION];
	double y0 = st[ST_ANCHOR_LEVEL];
	double scale = st[ST_SCALE];
	double w = st[ST_W];
	double g = st[ST_G];
	int linear = st[ST_LINEAR] != 0;
	int trigger_prev = st[ST_TRIGGER] != 0;
	double note_position = st[ST_NOTE_POSITION];
	double release_scale = st[ST_RELEASE_SCALE];

	if (seg < 0 || seg >= nseg) {
		rb_raise(rb_eArgError, "Segment index %ld out of range in envelope state", seg);
	}

	for (size_t i = 0; i < n; i++) {
		int gate_now = has_gate && env_at(&gate_sig, i) != 0;
		int start = stage == ENV_PENDING;

		if (env_at(&choke_sig, i) != 0 && (stage == ENV_SEGMENT || stage == ENV_SUSTAIN)) {
			stage = ENV_CHOKE;
			e = 0;
			planned = 0;
		}

		if (has_gate) {
			if (gate_now && !gate_prev) {
				start = 1;
			} else if (!gate_now && gate_prev && ((stage == ENV_SEGMENT && seg < release_node) || stage == ENV_SUSTAIN)) {
				stage = ENV_SEGMENT;
				seg = release_node;
				e = 0;
				planned = 0;
				release_scale = has_lift ? env_lift_scale(env_at(&lift_sig, i)) : 1.0;
			}
		}

		int trigger_now = has_trigger && env_at(&trigger_sig, i) > 0;
		if (trigger_now && !trigger_prev && !(legato && gate_prev && gate_now)) {
			start = 1;
		}
		trigger_prev = trigger_now;

		if (start) {
			peak = env_peak(env_at(&velocity_sig, i), velocity_low, velocity_high, velocity_db);
			if (add) {
				peak = env_add_peak(y, peak, velocity_low, velocity_high);
			}
			stage = ENV_SEGMENT;
			seg = 0;
			e = 0;
			planned = 0;
			note_position = 0;
			release_scale = 1.0;
		}

		gate_prev = gate_now;

		for (;;) {
			if (!has_gate && ((stage == ENV_SEGMENT && seg < release_node) || stage == ENV_SUSTAIN) &&
					note_position >= env_length(env_at(&hold_sig, i))) {
				// Notes without a gate release +hold+ samples after they start
				stage = ENV_SEGMENT;
				seg = release_node;
				e = 0;
				planned = 0;
				release_scale = has_lift ? env_lift_scale(env_at(&lift_sig, i)) : 1.0;
				continue;
			}

			if (stage == ENV_SEGMENT || stage == ENV_CHOKE) {
				double length, curve, target;
				if (stage == ENV_CHOKE) {
					length = choke_samples;
					curve = 0;
					target = 0;
				} else {
					double t = env_at(&seg_times[seg], i);
					length = env_length(seg >= release_node ? t * release_scale : t);
					curve = env_at(&seg_curves[seg], i);
					target = env_at(&seg_levels[seg], i) * peak;
				}
				if (!isfinite(curve)) {
					curve = 0;
				}

				if (e >= length) {
					// Land exactly on the target, then start the next stage
					// on this same sample.
					y = target;
					e = 0;
					planned = 0;

					if (stage == ENV_CHOKE || seg == nseg - 1) {
						stage = one_shot ? ENV_ENDED : ENV_IDLE;
					} else if (seg == release_node - 1) {
						stage = ENV_SUSTAIN;
					} else {
						seg++;
					}

					continue;
				}

				if (!planned || length != plan_length || curve != plan_curve || target != plan_target) {
					// (Re-)plan the rest of the segment from the last output.
					planned = 1;
					plan_length = length;
					plan_curve = curve;
					plan_target = target;
					e0 = e > 0 ? e - 1 : 0;
					y0 = y;

					double rem = length - e0;
					if (isinf(length)) {
						linear = 1;
						scale = 0;
					} else {
						double k = curve * curve_scale / length;
						if (fabs(k * rem) < ENV_LINEAR_LIMIT) {
							linear = 1;
							scale = (target - y0) / rem;
						} else {
							linear = 0;
							scale = (target - y0) / (1.0 - exp(k * rem));
							w = 1.0;
							g = exp(k);
						}
					}
				}

				if (linear) {
					y = y0 + scale * (e - e0);
				} else {
					if (e > e0) {
						w *= g;
					}
					y = y0 + scale * (1.0 - w);
				}

				e += 1;
				break;
			}

			if (stage == ENV_SUSTAIN) {
				if (has_gate && !gate_now) {
					// A triggered note reached sustain with the gate low
					stage = ENV_SEGMENT;
					seg = release_node;
					e = 0;
					planned = 0;
					release_scale = has_lift ? env_lift_scale(env_at(&lift_sig, i)) : 1.0;
					continue;
				}

				y = env_at(&seg_levels[release_node - 1], i) * peak;
				e += 1;
				break;
			}

			// Idle or ended
			y = 0;
			break;
		}

		note_position += 1;
		o[i] = use_octaves ? pow(2.0, y * env_at(&octaves_sig, i)) : y;
	}

	st[ST_STAGE] = stage;
	st[ST_SEGMENT] = seg;
	st[ST_POSITION] = e;
	st[ST_LEVEL] = y;
	st[ST_PEAK] = peak;
	st[ST_GATE] = gate_prev;
	st[ST_PLANNED] = planned;
	st[ST_PLAN_LENGTH] = plan_length;
	st[ST_PLAN_CURVE] = plan_curve;
	st[ST_PLAN_TARGET] = plan_target;
	st[ST_ANCHOR_POSITION] = e0;
	st[ST_ANCHOR_LEVEL] = y0;
	st[ST_SCALE] = scale;
	st[ST_W] = w;
	st[ST_G] = g;
	st[ST_LINEAR] = linear;
	st[ST_TRIGGER] = trigger_prev;
	st[ST_NOTE_POSITION] = note_position;
	st[ST_RELEASE_SCALE] = release_scale;

	RB_GC_GUARD(keep);

	return out;
}

void Init_fast_envelope(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_envelope = rb_define_module_under(sound, "FastEnvelope");

	rb_define_const(fast_envelope, "STATE_SIZE", INT2FIX(ST_SIZE));
	rb_define_const(fast_envelope, "MAX_SEGMENTS", INT2FIX(ENV_MAX_SEGMENTS));

	rb_define_module_function(fast_envelope, "process", ruby_process, 8);
}
