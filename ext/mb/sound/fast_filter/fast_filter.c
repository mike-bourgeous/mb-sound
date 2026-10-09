/*
 * MB::Sound::FastFilter: analog-style filter kernels (the four-pole, the
 * diode ladder (ruby_diode_ladder below), and the state-variable filter,
 * ruby_svf below).
 *
 * four_pole: a 4-pole resonant lowpass in the style of the CEM3379 (and
 * CEM3320): four one-pole OTA-C stages in a cascade with resonance feedback
 * from the last stage to the input, simulated with the topology-preserving
 * transform (trapezoidal integrators) and the feedback loop solved in closed
 * form (zero-delay feedback), after Zavalishin, "The Art of VA Filter
 * Design".
 *
 * Passband compensation: part of the input is added to the resonance path,
 * u = x (1 + c k) - k y4 = x - k (y4 - c x), so the DC gain is
 * (1 + c k) / (1 + k); c = 0.375 loses 6 dB of bass at k = 4 instead of
 * 12 dB (the CEM3379 datasheet's "constant amplitude" behavior).
 *
 * Resonance curve: the resonance r (0..1) gives the loop gain k = f(r) ×
 * k_max, with f(r) = r (linear) or the dB curve (fp_resonance_curve), which
 * makes the gain at the cutoff frequency (relative to DC) rise linearly in
 * dB from -12 dB at r = 0 to +33.8 dB at r = 1 (k = 3.9).
 *
 * Self-oscillation curves (curve 2: linear below the onset, 3: dB below the
 * onset; fp_self_osc_gain): the bottom FP_SELF_OSC_ONSET (0.9) of the knob
 * is the linear or dB curve, compressed and reaching the oscillation edge
 * k = 4 at the onset, and above it k rises as 4 + (k_max - 4) x^2 (x = 0..1
 * over the rest of the knob), so the oscillation's amplitude (about
 * proportional to sqrt(k - 4) near the edge) grows roughly linearly with
 * the knob instead of jumping in.
 *
 * Drive modes (all off with drive 0; tanh_d(z) = tanh(d z) / d):
 * - input: tanh_d on the solved input u of the cascade (one step after the
 *   linear loop solution).
 * - stages: every OTA stage saturates its drive current, dy/dt = wc
 *   tanh_d(x - y).  Zavalishin's "cheap" one-step method: the linear loop
 *   solution predicts each stage's input difference e, the stage's gain g
 *   becomes g tanh_d(e) / e (the secant), and the loop is solved again in
 *   closed form with those per-stage gains.
 * - feedback: a clipper (soft tanh_d, or hard: a clamp with a short
 *   quadratic knee) on the resonance feedback signal y4 - c x only (the
 *   Korg MS-20's diode clipper idea), with the same secant step: the loop
 *   gain becomes k clip_d(r) / r at the linear prediction r.
 *
 * tan, tanh, and 2^x are approximations using only +, -, *, /, floor, and
 * ldexp, so that every platform (glibc, macOS libm) and the Ruby mirror,
 * MB::Sound::Filter::FourPole.process_ruby, give identical samples; the
 * extension is built with -ffp-contract=off so no multiply-adds are fused.
 * Keep the operations here and in the mirror identical.
 */

#include <stdlib.h>
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_svf.h"
#include "mb_four_pole.h"

/*
 * Filters +buffer+ (SFloat, modified in place if marked inplace):
 *   four_pole(buffer, cutoff, resonance, state, sample_rate, k_max,
 *             compensation, drive, mix, curve = 0, drive_mode = 0, clip = 0)
 *
 * +cutoff+ (Hz) and +resonance+ (0..1, through the curve and times +k_max+
 * for the loop gain k) are Numerics or NArrays of the buffer's length (read
 * as float32).  +state+ is a 4-element Array of the integrator states,
 * updated.  +drive+ 0 is linear.  +mix+ is 5 output gains for the cascade
 * input and the four stage outputs (lowpass 4: [0, 0, 0, 0, 1]).  +curve+ is
 * 0 (linear), 1 (dB), 2 (self-oscillation over linear), or 3
 * (self-oscillation over dB; +k_max+ is then the loop gain at r = 1);
 * +drive_mode+ 0 (input), 1 (stages), or 2
 * (feedback); +clip+ 0 (soft) or 1 (hard), for the feedback mode.
 */
static VALUE ruby_four_pole(int argc, VALUE *argv, VALUE self)
{
	if (argc < 9 || argc > 12) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 9..12)", argc);
	}
	VALUE buffer = argv[0], cutoff = argv[1], resonance = argv[2], state = argv[3];
	double rate = NUM2DBL(argv[4]);
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}
	double k_max = NUM2DBL(argv[5]);
	double comp = NUM2DBL(argv[6]);
	double drive = NUM2DBL(argv[7]);
	VALUE mix_v = argv[8];
	if (!isfinite(k_max) || !isfinite(comp) || !(drive >= 0) || !isfinite(drive)) {
		rb_raise(rb_eArgError, "Filter parameters must be finite (and drive not negative)");
	}
	int curve = argc > 9 ? NUM2INT(argv[9]) : 0;
	int drive_mode = argc > 10 ? NUM2INT(argv[10]) : FP_DRIVE_INPUT;
	int clip = argc > 11 ? NUM2INT(argv[11]) : FP_CLIP_SOFT;
	if (curve < FP_CURVE_LINEAR || curve > FP_CURVE_SELF_OSC_DB) {
		rb_raise(rb_eArgError, "Resonance curve must be 0 (linear), 1 (dB), 2 (self-oscillating linear), or 3 (self-oscillating dB)");
	}
	if (drive_mode < FP_DRIVE_INPUT || drive_mode > FP_DRIVE_FEEDBACK) {
		rb_raise(rb_eArgError, "Drive mode must be 0 (input), 1 (stages), or 2 (feedback)");
	}
	if (clip < FP_CLIP_SOFT || clip > FP_CLIP_HARD) {
		rb_raise(rb_eArgError, "Clip must be 0 (soft) or 1 (hard)");
	}

	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) {
		rb_raise(rb_eArgError, "Four-pole state must have four elements");
	}
	Check_Type(mix_v, T_ARRAY);
	if (RARRAY_LEN(mix_v) != 5) {
		rb_raise(rb_eArgError, "Four-pole mix must have five elements");
	}
	double m0 = NUM2DBL(rb_ary_entry(mix_v, 0));
	double m1 = NUM2DBL(rb_ary_entry(mix_v, 1));
	double m2 = NUM2DBL(rb_ary_entry(mix_v, 2));
	double m3 = NUM2DBL(rb_ary_entry(mix_v, 3));
	double m4 = NUM2DBL(rb_ary_entry(mix_v, 4));

	double s0 = mb_finite_entry(state, 0);
	double s1 = mb_finite_entry(state, 1);
	double s2 = mb_finite_entry(state, 2);
	double s3 = mb_finite_entry(state, 3);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	struct mb_signal fc_in, res_in;
	mb_signal_input(&cutoff, length, "Cutoff", &fc_in);
	mb_signal_input(&resonance, length, "Resonance", &res_in);

	struct mb_fp_args args = {
		.rate = rate, .k_max = k_max, .comp = comp, .drive = drive,
		.mix = { m0, m1, m2, m3, m4 },
		.curve = curve, .drive_mode = drive_mode, .clip = clip, .normalize = 0,
	};
	double st[4] = { s0, s1, s2, s3 };
	mb_four_pole_run(&args, data, data, length, &fc_in, &res_in, st);
	mb_fp_flush(st);
	for (int j = 0; j < 4; j++) {
		rb_ary_store(state, j, rb_float_new(st[j]));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);
	RB_GC_GUARD(cutoff);
	RB_GC_GUARD(resonance);

	return buffer;
}

/*
 * svf: a linear trapezoidal state-variable filter (Andrew Simper's
 * "Cytomic" SVF, "Linear Trap Optimised 2"), with output mixes for the
 * RBJ cookbook responses (the same bilinear transform with the cutoff
 * prewarped, so static responses match MB::Sound::Filter::Cookbook).
 *
 * Its two states are integrator (capacitor) states rather than past
 * samples, so changing the cutoff, Q, or gain on any sample keeps the
 * output continuous: no thumps when a cutoff dives quickly to low values
 * (the direct form biquad's past outputs don't match new coefficients).
 *
 * Per change of cutoff fc, quality Q, or linear gain G:
 *   g = tan(pi fc / rate) (mb_tan_pade), k = 1 / Q
 *   a1 = 1 / (1 + g (g + k)), a2 = g a1, a3 = g a2
 * and per sample (ic1, ic2 the states):
 *   v3 = x - ic2
 *   v1 = a1 ic1 + a2 v3          (band)
 *   v2 = ic2 + a2 ic1 + a3 v3    (low)
 *   ic1 = 2 v1 - ic1, ic2 = 2 v2 - ic2
 *   y = m0 x + m1 v1 + m2 v2
 *
 * Output mixes (m0, m1, m2), with A = sqrt(G) (the cookbook's
 * 10^(dB / 40)):
 *   lowpass (0, 0, 1); highpass (1, -k, -1); bandpass, 0 dB peak (0, k G, 0);
 *   bandpass_skirt, peak Q (0, G, 0); notch (1, -k, 0); allpass (1, -2k, 0);
 *   peak: k = 1 / (Q A), (1, k (G - 1), 0);
 *   lowshelf: g / sqrt(A), (1, k (A - 1), G - 1);
 *   highshelf: g sqrt(A), (G, k (1 - A) A, 1 - G).
 *
 * Exact Ruby mirror: MB::Sound::Filter::SVF.process_ruby (same operations;
 * the extension is built with -ffp-contract=off).
 */

/*
 *   svf(buffer, cutoff, quality, gain, type, state, sample_rate)
 *
 * Filters +buffer+ (SFloat; modified in place if marked inplace).
 * +cutoff+ (Hz), +quality+, and +gain+ (linear; used by bandpass, peak,
 * and shelves) are Numerics or NArrays of the buffer's length (read as
 * float32).  +state+ is [ic1, ic2], updated.
 */
static VALUE ruby_svf(VALUE self, VALUE buffer, VALUE cutoff, VALUE quality, VALUE gain, VALUE type_v, VALUE state, VALUE rate_v)
{
	int type = NUM2INT(type_v);
	if (type < SVF_LOWPASS || type > SVF_BANDPASS_SKIRT) {
		rb_raise(rb_eArgError, "SVF filter type must be 0..8");
	}
	double rate = NUM2DBL(rate_v);
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}
	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 2) {
		rb_raise(rb_eArgError, "SVF state must have two elements");
	}
	double ic1 = mb_finite_entry(state, 0);
	double ic2 = mb_finite_entry(state, 1);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	struct mb_signal fc_in, q_in, g_in;
	mb_signal_input(&cutoff, length, "Cutoff", &fc_in);
	mb_signal_input(&quality, length, "Quality", &q_in);
	if (NIL_P(gain)) {
		gain = DBL2NUM(1.0);
	}
	mb_signal_input(&gain, length, "Gain", &g_in);

	double pi_over_rate = M_PI / rate;
	double fc_max = rate * FP_MAX_CUTOFF_RATIO;

	// Coefficients, recomputed only when an input changes
	struct mb_svf svf;
	mb_svf_init(&svf);

	for (size_t i = 0; i < length; i++) {
		mb_svf_coefficients(&svf, type, mb_signal_at(&fc_in, i), mb_signal_at(&q_in, i), mb_signal_at(&g_in, i), pi_over_rate, fc_max);
		data[i] = mb_svf_step(&svf, data[i], &ic1, &ic2);
	}

	if (!isfinite(ic1) || fabs(ic1) < FP_FLUSH) {
		ic1 = 0.0;
	}
	if (!isfinite(ic2) || fabs(ic2) < FP_FLUSH) {
		ic2 = 0.0;
	}
	rb_ary_store(state, 0, rb_float_new(ic1));
	rb_ary_store(state, 1, rb_float_new(ic2));

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);
	RB_GC_GUARD(cutoff);
	RB_GC_GUARD(quality);
	RB_GC_GUARD(gain);

	return buffer;
}

/*
 * diode_ladder: a TB-303-style 4-pole diode ladder lowpass (a behavioral
 * model, not a circuit simulation), with lp4's resonance scale, curves,
 * compensation, and drive.
 *
 * Four one-pole stages that load their neighbors (the diode ladder's
 * coupling), in units of the angular frequency wc:
 *   y1' = wc ((u - y1) + (y2 - y1))
 *   y2' = wc ((y1 - y2) + (y3 - y2))
 *   y3' = wc ((y2 - y3) + (y4 - y3))
 *   y4' = wc (y3 - y4)
 * i.e. y' = wc (A y + e1 u) with A tridiagonal (diagonal -2, -2, -2, -1,
 * off-diagonals 1), and resonance feedback u = x (1 + c k) - k y4 (lp4's
 * passband compensation c).  The open loop from u to y4 is 1 / D(s) with
 * D(s) = s^4 + 7 s^3 + 15 s^2 + 10 s + 1 (s in units of wc), so its phase
 * reaches -180 degrees at s = j sqrt(10/7) (DL_W180), where |1 / D| =
 * 49 / 901: the loop oscillates at k = 901 / 49 = 18.39 (DL_EDGE_K;
 * folklore says 17-18 for diode ladders, against 4 for a transistor
 * ladder).  The cutoff is normalized so that frequency is the cutoff, as
 * lp4's resonant peak is at its cutoff: the poles spread, so without
 * resonance the response is already -25.3 dB there (dark; it wants
 * resonance, like a 303), with slopes of about 14, 18, and 22 dB per
 * octave over the first three octaves above.
 *
 * Resonance: lp4's curves scaled from lp4's oscillation edge (k = 4) to
 * this one's (DL_SCALE = DL_EDGE_K / 4): the same knob positions sit the
 * same distance from oscillation, with the same top (0.975 of the edge by
 * default) and self-oscillation onset (0.9) and rise.  The dB curve
 * (dl_resonance_curve) is defined like lp4's: the gain at the cutoff
 * (relative to DC), (1 + k) / (K - k) for edge K, rises linearly in dB
 * from 1 / K (-25.3 dB) at r = 0 to +32.3 dB at r = 1 (k = 0.975 K).
 *
 * Normalization (normalize = 1, the default; user decision 2026-10-09: easy
 * switching between lp4 and the diode at the same settings, not hardware
 * fidelity): the stages' frequency is raised by dl_cutoff_scale(k) (2.86
 * without resonance, where the response falls 12 dB below DC at the cutoff
 * like lp4's, to 1 at the oscillation edge; the resonant peak is at lp4's
 * frequency from resonance 0.3 up), the compensation is replaced by
 * dl_compensation (the DC gain is lp4's at the same knob position), and the
 * input drive's saturator gets dl_headroom(k) (up to DL_SCALE), so ringing
 * and self-oscillation reach lp4's levels.  All three change only with the
 * resonance; normalize = 0 is the round-1 ladder described above.
 *
 * Simulation: trapezoidal integrators (TPT) with every stage and the loop
 * solved implicitly each sample (zero-delay feedback): with g = tan(pi fc
 * / rate) m / W180 (m the normalization, 1 without) and integrator states
 * s, the stage outputs solve (I - g A) y = s + g e1 u, a tridiagonal system
 * (Thomas algorithm, coefficients recomputed when the cutoff or resonance
 * changes, so both may move every sample), linear in u: y = p + q u, where p comes from the states
 * and q from the coefficients.  The loop is then solved in closed form,
 * u = (x (1 + c k) - k p4) / (1 + k q4), the drive applied like lp4's
 * (:input: tanh on u; :feedback: the secant step on the feedback y4 - c
 * x), y = p + q u back-substituted, and the states updated s = 2 y - s.
 *
 * Exact Ruby mirror: MB::Sound::Filter::FourPole.diode_process_ruby.
 */

/*
 * Filters +buffer+ (SFloat, modified in place if marked inplace):
 *   diode_ladder(buffer, cutoff, resonance, state, sample_rate, k_max,
 *                compensation, drive, curve = 0, drive_mode = 0, clip = 0)
 *
 * The arguments are four_pole's without the output mix (the output is the
 * fourth stage); +k_max+ is lp4's (3.9, or 5 with self-oscillation), scaled
 * by DL_SCALE here.  +drive_mode+ 0 (input) or 2 (feedback).
 */
static VALUE ruby_diode_ladder(int argc, VALUE *argv, VALUE self)
{
	if (argc < 8 || argc > 12) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 8..12)", argc);
	}
	VALUE buffer = argv[0], cutoff = argv[1], resonance = argv[2], state = argv[3];
	double rate = NUM2DBL(argv[4]);
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}
	double k_max = NUM2DBL(argv[5]);
	double comp = NUM2DBL(argv[6]);
	double drive = NUM2DBL(argv[7]);
	if (!isfinite(k_max) || !isfinite(comp) || !(drive >= 0) || !isfinite(drive)) {
		rb_raise(rb_eArgError, "Filter parameters must be finite (and drive not negative)");
	}
	int curve = argc > 8 ? NUM2INT(argv[8]) : 0;
	int drive_mode = argc > 9 ? NUM2INT(argv[9]) : FP_DRIVE_INPUT;
	int clip = argc > 10 ? NUM2INT(argv[10]) : FP_CLIP_SOFT;
	int normalize = argc > 11 ? NUM2INT(argv[11]) : 1;
	if (curve < FP_CURVE_LINEAR || curve > FP_CURVE_SELF_OSC_DB) {
		rb_raise(rb_eArgError, "Resonance curve must be 0 (linear), 1 (dB), 2 (self-oscillating linear), or 3 (self-oscillating dB)");
	}
	if (drive_mode != FP_DRIVE_INPUT && drive_mode != FP_DRIVE_FEEDBACK) {
		rb_raise(rb_eArgError, "Diode ladder drive mode must be 0 (input) or 2 (feedback)");
	}
	if (clip < FP_CLIP_SOFT || clip > FP_CLIP_HARD) {
		rb_raise(rb_eArgError, "Clip must be 0 (soft) or 1 (hard)");
	}
	if (normalize != 0 && normalize != 1) {
		rb_raise(rb_eArgError, "Normalize must be 0 (off) or 1 (on)");
	}

	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) {
		rb_raise(rb_eArgError, "Diode ladder state must have four elements");
	}

	double s0 = mb_finite_entry(state, 0);
	double s1 = mb_finite_entry(state, 1);
	double s2 = mb_finite_entry(state, 2);
	double s3 = mb_finite_entry(state, 3);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	struct mb_signal fc_in, res_in;
	mb_signal_input(&cutoff, length, "Cutoff", &fc_in);
	mb_signal_input(&resonance, length, "Resonance", &res_in);

	struct mb_fp_args args = {
		.rate = rate, .k_max = k_max, .comp = comp, .drive = drive,
		.mix = { 0, 0, 0, 0, 1 },
		.curve = curve, .drive_mode = drive_mode, .clip = clip, .normalize = normalize,
	};
	double st[4] = { s0, s1, s2, s3 };
	mb_diode_ladder_run(&args, data, data, length, &fc_in, &res_in, st);
	mb_fp_flush(st);
	for (int j = 0; j < 4; j++) {
		rb_ary_store(state, j, rb_float_new(st[j]));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);
	RB_GC_GUARD(cutoff);
	RB_GC_GUARD(resonance);

	return buffer;
}

// Exposes the diode ladder's dB resonance curve (k / DL_CURVE_K) for specs.
static VALUE ruby_diode_resonance_curve(VALUE self, VALUE r)
{
	return rb_float_new(dl_resonance_curve(NUM2DBL(r)));
}

// Exposes the diode ladder's loop gain for specs.
static VALUE ruby_diode_loop_gain(VALUE self, VALUE r, VALUE curve, VALUE k_max)
{
	return rb_float_new(dl_loop_gain(NUM2DBL(r), NUM2INT(curve), NUM2DBL(k_max)));
}

// Exposes the diode ladder's cutoff normalization factor for specs.
static VALUE ruby_diode_cutoff_scale(VALUE self, VALUE k)
{
	return rb_float_new(dl_cutoff_scale(NUM2DBL(k)));
}

// Exposes the normalized diode ladder's passband compensation for specs.
static VALUE ruby_diode_compensation(VALUE self, VALUE k, VALUE k4, VALUE comp)
{
	return rb_float_new(dl_compensation(NUM2DBL(k), NUM2DBL(k4), NUM2DBL(comp)));
}

// Exposes the diode ladder's input saturation headroom for specs.
static VALUE ruby_diode_headroom(VALUE self, VALUE k)
{
	return rb_float_new(dl_headroom(NUM2DBL(k)));
}

// Exposes the tan approximation for specs and the Ruby mirror's checks.
static VALUE ruby_tan(VALUE self, VALUE w)
{
	return rb_float_new(mb_tan_pade(NUM2DBL(w)));
}

// Exposes the tanh approximation for specs.
static VALUE ruby_tanh(VALUE self, VALUE x)
{
	return rb_float_new(fp_tanh(NUM2DBL(x)));
}

// Exposes the saturators' secant gains for specs: clip 0 soft, 1 hard.
static VALUE ruby_secant(VALUE self, VALUE x, VALUE clip)
{
	double v = NUM2DBL(x);
	return rb_float_new(NUM2INT(clip) == FP_CLIP_HARD ? fp_hard_secant(v) : fp_tanh_secant(v));
}

// Exposes the dB resonance curve (k / k_max for resonance r) for specs.
static VALUE ruby_resonance_curve(VALUE self, VALUE r)
{
	return rb_float_new(fp_resonance_curve(NUM2DBL(r)));
}

// Exposes the self-oscillation curves' loop gain for specs.
static VALUE ruby_self_osc_gain(VALUE self, VALUE r, VALUE db, VALUE k_max)
{
	return rb_float_new(fp_self_osc_gain(NUM2DBL(r), RTEST(db), NUM2DBL(k_max)));
}

void Init_fast_filter(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_filter = rb_define_module_under(sound, "FastFilter");

	rb_define_module_function(fast_filter, "four_pole", ruby_four_pole, -1);
	rb_define_module_function(fast_filter, "svf", ruby_svf, 7);
	rb_define_module_function(fast_filter, "tan", ruby_tan, 1);
	rb_define_module_function(fast_filter, "tanh", ruby_tanh, 1);
	rb_define_module_function(fast_filter, "secant", ruby_secant, 2);
	rb_define_module_function(fast_filter, "resonance_curve", ruby_resonance_curve, 1);
	rb_define_module_function(fast_filter, "self_osc_gain", ruby_self_osc_gain, 3);
	rb_define_module_function(fast_filter, "diode_ladder", ruby_diode_ladder, -1);
	rb_define_module_function(fast_filter, "diode_resonance_curve", ruby_diode_resonance_curve, 1);
	rb_define_module_function(fast_filter, "diode_loop_gain", ruby_diode_loop_gain, 3);
	rb_define_module_function(fast_filter, "diode_cutoff_scale", ruby_diode_cutoff_scale, 1);
	rb_define_module_function(fast_filter, "diode_headroom", ruby_diode_headroom, 1);
	rb_define_module_function(fast_filter, "diode_compensation", ruby_diode_compensation, 3);
}
