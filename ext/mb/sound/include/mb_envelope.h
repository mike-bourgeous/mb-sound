/*
 * The envelope generator kernel of MB::Sound::FastEnvelope (see
 * fast_envelope.c for the algorithm, arguments, and state), shared with
 * the plan layer executor (fast_plan) so a planned envelope runs exactly
 * the same arithmetic.  The Ruby mirror is MB::Sound::Envelope.process_ruby.
 *
 * fast_envelope is built with -ffp-contract=off and fast_plan isn't, so
 * every function here starts with MB_ENV_NO_CONTRACT, which turns
 * contraction off for clang; GCC with -std=c99 (both extensions) doesn't
 * contract (ISO C modes default to -ffp-contract=off).
 */
#ifndef MB_ENVELOPE_H
#define MB_ENVELOPE_H

#include <math.h>
#include <stddef.h>

#if defined(__clang__)
#define MB_ENV_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define MB_ENV_NO_CONTRACT
#endif

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
	ST_PREV_LEVEL,     // the output level before ST_LEVEL (for the slope)
	ST_PLAN_SHAPE,     // the segment shape the plan was made for
	ST_PHASE,          // S segments: phase u (0..1) of the last output
	ST_RATE,           //   phase increment per sample
	ST_S_ANCHOR,       //   S(u) at the anchor
	ST_WARP_INV,       //   1 / (1 - e^c) for the dB warp of the phase
	ST_WARP_LINEAR,    //   whether the warp is the identity (c = 0)
	ST_CORR_SLOPE,     //   slope carried by the correction (per sample)
	ST_CORR_TIME,      //   correction length tau (samples)
	ST_CORR_POSITION,  //   samples since the correction's anchor
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
	CF_SLOPE_SAMPLES,  // longest slope correction of S segments (samples)
	CF_OVERSHOOT,      // largest correction bump, relative to the step
	CF_SIZE,
	CF_LOOP_NODE = CF_SIZE, // optional: segment to loop back to, or -1
};

// The most loop jumps on one sample (a loop of zero-length segments stops
// looping and sustains instead of spinning forever).
#define ENV_MAX_LOOP_JUMPS ENV_MAX_SEGMENTS

// Segment shapes (MB::Sound::Envelope::SHAPES).
enum env_shape {
	ENV_SHAPE_EXP = 0,
	ENV_SHAPE_S = 1,
};

// The smallest segment step the S correction's overshoot bound uses.
#define ENV_MIN_STEP 1e-3

enum env_flags {
	ENV_HAS_GATE = 1,
	ENV_HAS_TRIGGER = 2,
	ENV_ONE_SHOT = 4,
	ENV_LEGATO = 8,
	ENV_OCTAVES = 16,
	ENV_LIFT = 32,
	ENV_ADD = 64,     // retrigger peaks add to the current level (energy sum)
	ENV_ZERO = 128,   // notes start from 0, not the current level (SQ-80 ENV restart)
};

// A parameter or input: a constant, or a float or double per sample.
struct env_signal {
	double scalar;
	const float *f;
	const double *d;
};

static inline double env_at(const struct env_signal *s, size_t i)
{
	MB_ENV_NO_CONTRACT
	if (s->f) {
		return s->f[i];
	}
	if (s->d) {
		return s->d[i];
	}
	return s->scalar;
}

// A segment length in whole samples: 0 for negative or NaN lengths,
// infinity stays infinite.
static inline double env_length(double t)
{
	MB_ENV_NO_CONTRACT
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
static inline double env_lift_scale(double lift)
{
	MB_ENV_NO_CONTRACT
	if (!(lift >= 0)) {
		lift = 0;
	}
	if (lift > 1) {
		lift = 1;
	}

	return pow(2.0, (0.5 - lift) * 2.0);
}

// The peak level for velocity +v+ (clamped to 0..1).
static inline double env_peak(double v, double low, double high, int db)
{
	MB_ENV_NO_CONTRACT
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
static inline double env_add_peak(double y, double p, double low, double high)
{
	MB_ENV_NO_CONTRACT
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

// The plan of an S segment (see the top of the file).  Kept apart from the
// exp planner's locals, with planning and sampling out of line, so the loop
// of exp envelopes stays as tight as before the S shape existed.
struct env_s_plan {
	double e0;             // anchor position (the last output's)
	double y0;             // anchor level
	double scale;          // (target - y0) / (1 - S(u_a))
	double w, g;           // warp recursion: w = e^(c u), w *= g each sample
	double u, rate;        // phase of the last output, and its increment
	double s_anchor;       // S(u_a)
	double warp_inv;       // 1 / (1 - e^c)
	int warp_linear;       // c = 0: the warp is the identity
	double corr_slope;     // slope correction (see the top of the file)
	double corr_time;
	double corr_position;
};

// (Re-)plans the rest of an S segment at position +e+ from the last output
// +y+ (whose slope was +slope+), for +length+ samples, curvature +c+, and
// +target+.  +full+ recomputes the warp (new segment, new curve, or
// another shape until now), +timing+ the phase rate; +landed+ skips the
// slope correction (a normal landing on the previous segment's target).
static __attribute__((noinline, unused)) void env_plan_s(
		struct env_s_plan *sp, int full, int timing, int other_shape, int landed,
		double e, double y, double slope, double length, double c, double target,
		double slope_samples, double overshoot)
{
	MB_ENV_NO_CONTRACT
	sp->e0 = e > 0 ? e - 1 : 0;
	sp->y0 = y;
	if (e == 0) {
		sp->u = 0;
	} else if (other_shape) {
		// Another shape until now: the phase from the time
		sp->u = sp->e0 / length;
	}

	if (full) {
		sp->warp_linear = fabs(c) < ENV_LINEAR_LIMIT;
		if (!sp->warp_linear) {
			sp->warp_inv = 1.0 / (1.0 - exp(c));
			sp->w = exp(c * sp->u);
		}
	}
	if (timing) {
		sp->rate = (1.0 - sp->u) / (length - sp->e0);
		if (!sp->warp_linear) {
			sp->g = exp(c * sp->rate);
		}
	}

	double p = sp->warp_linear ? sp->u : (1.0 - sp->w) * sp->warp_inv;
	sp->s_anchor = p * p * (3.0 - 2.0 * p);
	double span = 1.0 - sp->s_anchor;
	sp->scale = span > 0 ? (target - sp->y0) / span : 0.0;

	// Slope correction (not after a normal landing)
	sp->corr_position = 0;
	sp->corr_time = 0;
	sp->corr_slope = 0;
	if (!landed) {
		double dp = sp->warp_linear ? 1.0 : -c * sp->w * sp->warp_inv;
		sp->corr_slope = slope - sp->scale * (6.0 * p * (1.0 - p)) * dp * sp->rate;
		if (sp->corr_slope != 0) {
			double step = fabs(target - sp->y0);
			if (step < ENV_MIN_STEP) {
				step = ENV_MIN_STEP;
			}
			double limit = 27.0 * overshoot * step / (4.0 * fabs(sp->corr_slope));
			sp->corr_time = length - sp->e0;
			if (slope_samples < sp->corr_time) {
				sp->corr_time = slope_samples;
			}
			if (limit < sp->corr_time) {
				sp->corr_time = limit;
			}
			if (sp->corr_time < 1) {
				sp->corr_time = 1;
			}
		}
	}
}

// The level of an S segment at position +e+ (advancing its phase).
static __attribute__((noinline, unused)) double env_sample_s(struct env_s_plan *sp, double e)
{
	MB_ENV_NO_CONTRACT
	if (e > sp->e0) {
		sp->u += sp->rate;
		if (!sp->warp_linear) {
			sp->w *= sp->g;
		}
	}
	sp->corr_position += 1;

	double p = sp->warp_linear ? sp->u : (1.0 - sp->w) * sp->warp_inv;
	double y = sp->y0 + sp->scale * (p * p * (3.0 - 2.0 * p) - sp->s_anchor);
	if (sp->corr_position < sp->corr_time) {
		double x = sp->corr_position / sp->corr_time;
		double h = 1.0 - x;
		y += sp->corr_slope * sp->corr_time * (x * h * h);
	}

	return y;
}


// The parameters and inputs of one envelope (see fast_envelope.c's
// ruby_process).
struct mb_env_args {
	long nseg;
	struct env_signal times[ENV_MAX_SEGMENTS], curves[ENV_MAX_SEGMENTS], levels[ENV_MAX_SEGMENTS];
	int shapes[ENV_MAX_SEGMENTS];
	struct env_signal hold, gate, trigger, velocity, choke, lift, octaves;
	int flags;
	long release_node;
	long loop_node;     // -1 for none
	double velocity_low, velocity_high;
	int velocity_db;
	double choke_samples; // env_length of the choke time
	double curve_scale, slope_samples, overshoot;
};

// Runs the envelope for +n+ samples into +o+ with the state +st+ (ST_SIZE
// doubles, read and written).  Returns 0, or -1 (nothing written) if the
// state's segment index is out of range.
static inline int mb_env_process(const struct mb_env_args *a, float *o, size_t n, double *st)
{
	MB_ENV_NO_CONTRACT
	long nseg = a->nseg;
	int flags = a->flags;
	long release_node = a->release_node;
	long loop_node = a->loop_node;
	double velocity_low = a->velocity_low;
	double velocity_high = a->velocity_high;
	int velocity_db = a->velocity_db;
	double choke_samples = a->choke_samples;
	double curve_scale = a->curve_scale;
	double slope_samples = a->slope_samples;
	double overshoot = a->overshoot;
	const struct env_signal *seg_times = a->times;
	const struct env_signal *seg_curves = a->curves;
	const struct env_signal *seg_levels = a->levels;
	const int *seg_shapes = a->shapes;
	struct env_signal hold_sig = a->hold, gate_sig = a->gate, trigger_sig = a->trigger, velocity_sig = a->velocity;
	struct env_signal choke_sig = a->choke, lift_sig = a->lift, octaves_sig = a->octaves;

	int has_gate = !!(flags & ENV_HAS_GATE);
	int has_trigger = !!(flags & ENV_HAS_TRIGGER);
	int one_shot = !!(flags & ENV_ONE_SHOT);
	int legato = !!(flags & ENV_LEGATO);
	int use_octaves = !!(flags & ENV_OCTAVES);
	int has_lift = !!(flags & ENV_LIFT);
	int add = !!(flags & ENV_ADD);
	int zero = !!(flags & ENV_ZERO);

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
	double y_prev = st[ST_PREV_LEVEL];
	int plan_shape = (int)st[ST_PLAN_SHAPE];
	struct env_s_plan sp = {
		.e0 = e0, .y0 = y0, .scale = scale, .w = w, .g = g,
		.u = st[ST_PHASE],
		.rate = st[ST_RATE],
		.s_anchor = st[ST_S_ANCHOR],
		.warp_inv = st[ST_WARP_INV],
		.warp_linear = st[ST_WARP_LINEAR] != 0,
		.corr_slope = st[ST_CORR_SLOPE],
		.corr_time = st[ST_CORR_TIME],
		.corr_position = st[ST_CORR_POSITION],
	};

	if (seg < 0 || seg >= nseg) {
		return -1;
	}

	for (size_t i = 0; i < n; i++) {
		int gate_now = has_gate && env_at(&gate_sig, i) != 0;
		int start = stage == ENV_PENDING;
		int landed = 0;
		int loop_jumps = 0;
		double y_last = y;

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
			if (zero) {
				y = 0;
				y_prev = 0;
				y_last = 0;
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
					landed = 1;

					if (stage == ENV_CHOKE || seg == nseg - 1) {
						stage = one_shot ? ENV_ENDED : ENV_IDLE;
					} else if (seg == release_node - 1) {
						if (loop_node >= 0 && loop_jumps < ENV_MAX_LOOP_JUMPS) {
							seg = loop_node;
							loop_jumps++;
						} else {
							stage = ENV_SUSTAIN;
						}
					} else {
						seg++;
					}

					continue;
				}

				int shape = stage == ENV_CHOKE ? ENV_SHAPE_EXP : seg_shapes[seg];

				if (shape == ENV_SHAPE_S) {
					if (!planned || length != plan_length || curve != plan_curve || target != plan_target || plan_shape != ENV_SHAPE_S) {
						// (Re-)plan the rest of the segment from the last
						// output, keeping its phase (see the top of the file).
						int other_shape = plan_shape != ENV_SHAPE_S;
						int full = !planned || e == 0 || other_shape || curve != plan_curve;
						int timing = full || length != plan_length;
						env_plan_s(&sp, full, timing, other_shape, landed, e, y, y - y_prev, length, curve * curve_scale, target, slope_samples, overshoot);

						planned = 1;
						plan_length = length;
						plan_curve = curve;
						plan_target = target;
						plan_shape = ENV_SHAPE_S;
					}

					y = env_sample_s(&sp, e);
					e += 1;
					break;
				}

				if (!planned || length != plan_length || curve != plan_curve || target != plan_target || plan_shape != ENV_SHAPE_EXP) {
					// (Re-)plan the rest of the segment from the last output.
					planned = 1;
					plan_length = length;
					plan_curve = curve;
					plan_target = target;
					plan_shape = ENV_SHAPE_EXP;
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

		y_prev = y_last;
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
	if (plan_shape == ENV_SHAPE_S) {
		e0 = sp.e0;
		y0 = sp.y0;
		scale = sp.scale;
		w = sp.w;
		g = sp.g;
	}
	st[ST_ANCHOR_POSITION] = e0;
	st[ST_ANCHOR_LEVEL] = y0;
	st[ST_SCALE] = scale;
	st[ST_W] = w;
	st[ST_G] = g;
	st[ST_LINEAR] = linear;
	st[ST_TRIGGER] = trigger_prev;
	st[ST_NOTE_POSITION] = note_position;
	st[ST_RELEASE_SCALE] = release_scale;
	st[ST_PREV_LEVEL] = y_prev;
	st[ST_PLAN_SHAPE] = plan_shape;
	st[ST_PHASE] = sp.u;
	st[ST_RATE] = sp.rate;
	st[ST_S_ANCHOR] = sp.s_anchor;
	st[ST_WARP_INV] = sp.warp_inv;
	st[ST_WARP_LINEAR] = sp.warp_linear;
	st[ST_CORR_SLOPE] = sp.corr_slope;
	st[ST_CORR_TIME] = sp.corr_time;
	st[ST_CORR_POSITION] = sp.corr_position;


	return 0;
}

#endif
