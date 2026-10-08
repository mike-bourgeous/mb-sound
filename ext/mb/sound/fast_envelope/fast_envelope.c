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
 * S segments (shape ENV_SHAPE_S) follow a smoothstep of the same dB-warped
 * curve of a phase u that runs from 0 to 1 over the segment:
 *   S(u) = s(p(u)), s(x) = x^2 (3 - 2x)
 *   level = y_a + (target - y_a) * (S(u) - S(u_a)) / (1 - S(u_a))
 * so every S segment starts and ends with zero slope (0 dB is plain
 * smoothstep, negative dB swells, positive dB moves fast first).  y_a and
 * u_a are the level and phase where the plan was made (0 at the segment
 * start).  When the length changes, u keeps its value and its rate becomes
 * (1 - u) / (samples left), so the segment still lands on its sample; a
 * target or curve change re-anchors y_a and u_a at the current level and
 * phase.  The warp p runs on the recursion w = e^(c u), w *= e^(c rate).
 *
 * After a re-plan, a release, or a note start (not a normal landing), an S
 * segment carries the old slope for a moment and fades it out with a
 * Hermite term m_c * tau * h(t / tau), h(x) = x (1 - x)^2, where m_c is the
 * last output slope minus the new path's slope and t counts samples from
 * the last output.  tau is at most CF_SLOPE_SAMPLES (2 ms), the samples
 * left, and 27 eps |step| / (4 |m_c|), so the bump stays within eps
 * (CF_OVERSHOOT, 1%) of the segment's step; the level stays continuous and
 * the slope too, at that time scale.
 *
 * The Ruby mirror is MB::Sound::Envelope.process_ruby; specs check that both
 * give exactly the same samples, so keep the operations identical (this
 * extension is built with -ffp-contract=off so clang doesn't fuse them).
 */

#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_envelope.h"

// Reads a parameter or input: nil (+nil_value+), a Numeric, or a 1D SFloat
// or DFloat (other NArrays are cast to DFloat) of +length+ values.  NArrays
// that had to be converted are kept alive in +keep+.
static void env_read_signal(VALUE v, size_t length, const char *name, double nil_value, VALUE *keep, struct env_signal *s)
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

	VALUE orig = v;
	if (CLASS_OF(v) != numo_cSFloat && CLASS_OF(v) != numo_cDFloat) {
		v = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, v);
	}
	if (!RTEST(nary_check_contiguous(v))) {
		v = nary_dup(v);
	}
	if (v != orig) {
		// Only converted copies need keeping alive (the caller's Arrays
		// hold the originals); the Array is made on first use, so the usual
		// call allocates nothing
		if (NIL_P(*keep)) {
			*keep = rb_ary_new();
		}
		rb_ary_push(*keep, v);
	}

	if (CLASS_OF(v) == numo_cSFloat) {
		s->f = (const float *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	} else {
		s->d = (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	}
}

/*
 * Runs the envelope for one buffer:
 *   process(out, state, times, curves, levels, hold, inputs, config, shapes)
 * +out+ is a contiguous SFloat written in place (and returned).  +state+ is
 * a contiguous DFloat of ST_SIZE values, updated in place.  +times+ (in
 * samples), +curves+ (in dB), and +levels+ (relative to the peak) are
 * Arrays with one entry per segment, each a Numeric or an NArray of
 * out.length values.  +shapes+ is an Array of one Integer per segment
 * (enum env_shape).  +hold+ is how long notes of envelopes without a gate
 * last before releasing, counted from the note start, in samples (Numeric
 * or NArray).  +inputs+ is [gate, trigger, velocity, choke, lift, octaves],
 * each nil, a Numeric, or an NArray (lift and octaves are used only with
 * the ENV_LIFT and ENV_OCTAVES flags).  +config+ is [flags, release node,
 * velocity low, velocity high, velocity in dB (0 or 1), choke samples,
 * curve scale, slope correction samples, overshoot], optionally followed
 * by a loop node (see MB::Sound::Envelope#kernel_config).
 *
 * Loops: with a loop node L >= 0 (at most the release node), the segment
 * before the release node jumps to segment L when it lands instead of
 * entering the sustain stage, so segments L to release node - 1 repeat
 * until the release (gate off, hold, or choke).  L equal to the release
 * node runs straight into the release (the SQ-80's CYC mode with a
 * trigger and no gate).  Without a loop node (or -1) nothing changes.
 *
 * With the ENV_ZERO flag, every note start drops the level to 0 first
 * (and the slope the S segments carry), so the attack starts from zero
 * like the SQ-80's ENV restart mode (it clicks if the level wasn't 0).
 *
 * With the ENV_ADD flag, a note's peak is env_add_peak of the level when
 * it starts and its velocity's peak (Envelope retrigger: :add).
 *
 * Triggers fire on rising edges: a sample > 0 after a sample <= 0
 * (negative values are reserved).  A release starts with its time scaled
 * by env_lift_scale of the lift input on that sample.
 */
static VALUE ruby_process(VALUE self, VALUE out, VALUE state, VALUE times, VALUE curves, VALUE levels, VALUE hold, VALUE inputs, VALUE config, VALUE shapes)
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
	Check_Type(shapes, T_ARRAY);

	long nseg = RARRAY_LEN(times);
	if (nseg < 2 || nseg > ENV_MAX_SEGMENTS || RARRAY_LEN(curves) != nseg || RARRAY_LEN(levels) != nseg || RARRAY_LEN(shapes) != nseg) {
		rb_raise(rb_eArgError, "Times, curves, levels, and shapes must have the same number of segments (2 to %d)", ENV_MAX_SEGMENTS);
	}
	if (RARRAY_LEN(inputs) != 6) {
		rb_raise(rb_eArgError, "Inputs must be [gate, trigger, velocity, choke, lift, octaves]");
	}
	if (RARRAY_LEN(config) != CF_SIZE && RARRAY_LEN(config) != CF_SIZE + 1) {
		rb_raise(rb_eArgError, "Config must have %d or %d values", CF_SIZE, CF_SIZE + 1);
	}

	int flags = NUM2INT(rb_ary_entry(config, CF_FLAGS));
	long release_node = NUM2LONG(rb_ary_entry(config, CF_RELEASE_NODE));
	double velocity_low = NUM2DBL(rb_ary_entry(config, CF_VELOCITY_LOW));
	double velocity_high = NUM2DBL(rb_ary_entry(config, CF_VELOCITY_HIGH));
	int velocity_db = NUM2INT(rb_ary_entry(config, CF_VELOCITY_DB));
	double choke_samples = env_length(NUM2DBL(rb_ary_entry(config, CF_CHOKE_SAMPLES)));
	double curve_scale = NUM2DBL(rb_ary_entry(config, CF_CURVE_SCALE));
	double slope_samples = NUM2DBL(rb_ary_entry(config, CF_SLOPE_SAMPLES));
	double overshoot = NUM2DBL(rb_ary_entry(config, CF_OVERSHOOT));

	if (release_node < 1 || release_node >= nseg) {
		rb_raise(rb_eArgError, "Release node must be from 1 to %ld", nseg - 1);
	}
	long loop_node = RARRAY_LEN(config) > CF_LOOP_NODE ? NUM2LONG(rb_ary_entry(config, CF_LOOP_NODE)) : -1;
	if (loop_node < -1 || loop_node > release_node) {
		rb_raise(rb_eArgError, "Loop node must be -1 (none) or from 0 to the release node %ld", release_node);
	}
	if (velocity_db && !(velocity_low > 0 && velocity_high > 0)) {
		rb_raise(rb_eArgError, "Velocity gains must be positive for dB scaling");
	}


	size_t n = RNARRAY_SHAPE(out)[0];
	VALUE keep = Qnil;

	struct env_signal seg_times[ENV_MAX_SEGMENTS], seg_curves[ENV_MAX_SEGMENTS], seg_levels[ENV_MAX_SEGMENTS];
	for (long s = 0; s < nseg; s++) {
		env_read_signal(rb_ary_entry(times, s), n, "Segment time", 0, &keep, &seg_times[s]);
		env_read_signal(rb_ary_entry(curves, s), n, "Segment curve", 0, &keep, &seg_curves[s]);
		env_read_signal(rb_ary_entry(levels, s), n, "Segment level", 0, &keep, &seg_levels[s]);
	}

	int seg_shapes[ENV_MAX_SEGMENTS];
	for (long s = 0; s < nseg; s++) {
		seg_shapes[s] = NUM2INT(rb_ary_entry(shapes, s));
		if (seg_shapes[s] != ENV_SHAPE_EXP && seg_shapes[s] != ENV_SHAPE_S) {
			rb_raise(rb_eArgError, "Unknown segment shape %d", seg_shapes[s]);
		}
	}

	struct env_signal hold_sig, gate_sig, trigger_sig, velocity_sig, choke_sig, lift_sig, octaves_sig;
	env_read_signal(hold, n, "Hold", 0, &keep, &hold_sig);
	env_read_signal(rb_ary_entry(inputs, 0), n, "Gate", 0, &keep, &gate_sig);
	env_read_signal(rb_ary_entry(inputs, 1), n, "Trigger", 0, &keep, &trigger_sig);
	env_read_signal(rb_ary_entry(inputs, 2), n, "Velocity", 1, &keep, &velocity_sig);
	env_read_signal(rb_ary_entry(inputs, 3), n, "Choke", 0, &keep, &choke_sig);
	env_read_signal(rb_ary_entry(inputs, 4), n, "Lift", 0.5, &keep, &lift_sig);
	env_read_signal(rb_ary_entry(inputs, 5), n, "Octaves", 0, &keep, &octaves_sig);

	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	double *st = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));


	struct mb_env_args a;
	a.nseg = nseg;
	for (long s = 0; s < nseg; s++) {
		a.times[s] = seg_times[s];
		a.curves[s] = seg_curves[s];
		a.levels[s] = seg_levels[s];
		a.shapes[s] = seg_shapes[s];
	}
	a.hold = hold_sig;
	a.gate = gate_sig;
	a.trigger = trigger_sig;
	a.velocity = velocity_sig;
	a.choke = choke_sig;
	a.lift = lift_sig;
	a.octaves = octaves_sig;
	a.flags = flags;
	a.release_node = release_node;
	a.loop_node = loop_node;
	a.velocity_low = velocity_low;
	a.velocity_high = velocity_high;
	a.velocity_db = velocity_db;
	a.choke_samples = choke_samples;
	a.curve_scale = curve_scale;
	a.slope_samples = slope_samples;
	a.overshoot = overshoot;

	if (mb_env_process(&a, o, n, st) != 0) {
		rb_raise(rb_eArgError, "Segment index %ld out of range in envelope state", (long)st[ST_SEGMENT]);
	}

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

	rb_define_module_function(fast_envelope, "process", ruby_process, 9);
}
