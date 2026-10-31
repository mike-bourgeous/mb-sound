/*
 * Filters as plan ops (fast_plan.c's OP_SVF, ...): the kernels live in
 * plan_filters.c, sharing the filters' own code through the include/
 * headers (mb_svf.h, ...), so a planned filter runs the same operations as
 * its node.
 */
#ifndef MB_PLAN_FILTERS_H
#define MB_PLAN_FILTERS_H

#include <stddef.h>
#include <ruby.h>

// A filter parameter: a float register (p non-NULL) or a number.
struct mb_plan_param {
	const float *p;
	double scalar;
};

static inline double mb_plan_param_at(const struct mb_plan_param *s, size_t i)
{
	return s->p ? (double)s->p[i] : s->scalar;
}

// OP_SVF: Filter::SVF#dynamic_process (FastFilter.svf) on +a+ into +d+;
// +obj+ is the Filter::SVF (its @state, @type_id, and @sample_rate are
// read each block); +remember_gain+ as SVF#remember with a gain input.  Raises on bad objects.
void mb_plan_svf(float *d, const float *a, const struct mb_plan_param *fc, const struct mb_plan_param *q,
		const struct mb_plan_param *g, _Bool remember_gain, VALUE obj, size_t n);

// OP_SVF for several lanes at once (FastPlan.run_lanes): +lanes+ filters,
// each with its output d[l], input a[l], parameters prm[3 * l ...], gain
// flag, and Filter::SVF objs[l], giving each exactly what mb_plan_svf gives
// it, with the lanes' recursions interleaved sample by sample.
void mb_plan_svf_lanes(int lanes, float *const *d, const float *const *a, const struct mb_plan_param *prm,
		const _Bool *remember_gain, const VALUE *objs, size_t n);

// OP_FOUR_POLE: GraphNode::FourPole (Filter::FourPole#dynamic_process:
// FastFilter.four_pole or .diode_ladder through mb_four_pole.h) on +a+ into
// +d+; +cfg+ is [k_max, compensation, drive, mix (5), curve, drive mode,
// clip, normalize, diode, tuning]; +obj+ the Filter::FourPole (its @state and
// @sample_rate read each block, @cutoff and @resonance set to the last
// values as #remember does).
void mb_plan_four_pole(float *d, const float *a, const struct mb_plan_param *fc, const struct mb_plan_param *res,
		const double *cfg, VALUE obj, size_t n);

// OP_FOUR_POLE for several lanes at once (see mb_plan_svf_lanes): prm
// holds each lane's cutoff and resonance (2 per lane), cfg[l] each lane's
// settings.
void mb_plan_four_pole_lanes(int lanes, float *const *d, const float *const *a, const struct mb_plan_param *prm,
		const double *const *cfg, const VALUE *objs, size_t n);

// OP_BIQUAD (plan_biquad.c): Filter::Cookbook#dynamic_process
// (FastSound.dynamic_biquad through mb_biquad.h) on +a+ into +d+ with the
// cutoff and quality registers +cut+ and +q+; +type+ the cookbook filter
// type id; +obj+ the Filter::Cookbook (its sample rate, dB gain, f0 limit,
// and x/y state read each block, its coefficients, state, quality, and
// cutoff set afterwards as #dynamic_process_c does).
void mb_plan_biquad(float *d, const float *a, const float *cut, const float *q, int type, VALUE obj, size_t n);

// OP_BIQUAD for several lanes at once (see mb_plan_svf_lanes; the filter
// type is the op's, the same for every lane).
void mb_plan_biquad_lanes(int lanes, float *const *d, const float *const *a, const float *const *cut, const float *const *q,
		int type, const VALUE *objs, size_t n);

// The wavetable kernel of OP_TONE (plan_wavetable.c): one segment of a
// planned wavetable tone (FastWavetable.oscillate's loop through
// mb_wavetable.h) into +out+; +tinfo+ is Tone#plan_wavetable's [kernel
// spec, interpolation code, sinc kernel]; +phase_state+, +tstate+, and
// +noise+ the Tone::State's phase, table, and noise Arrays, updated.
struct mb_signal;
void mb_plan_wavetable_segment(VALUE tinfo, float *out, size_t length, const struct mb_signal *f, const struct mb_signal *p,
		const struct mb_signal *w, _Bool warped, const struct mb_signal *scan, double adv, double rndadv, double g, double off,
		_Bool remove_dc, VALUE phase_state, VALUE tstate, VALUE noise);

// OP_DYNAMICS: FastDynamics.compand (plan_dynamics.c, through
// mb_dynamics.h) on the +nch+ inputs +in+ into +out+, with +nside+ detector
// signals +side+ and MB_PLAN_DYN_SIGNALS signals +tim+ (DT_COUNT: the
// times in samples, then the live threshold shift, ratio scale, and mix);
// +obj+ is the GraphNode::Dynamics (its @params, @plan_curve, @state, and
// @delay are read each block).  Raises on bad objects.
#define MB_PLAN_DYN_SIGNALS 8
struct mb_signal;
void mb_plan_dynamics(float *const *out, long nch, const struct mb_signal *in, const struct mb_signal *side, long nside, const struct mb_signal *tim, VALUE obj, size_t n);

// OP_DECIMATE: FastLofi.decimate (plan_lofi.c, through mb_decimate.h) on
// the real input +in+ into +d+ at the hold rate +rate+ (Hz), then, unless
// +mix+ is NULL, GraphNode::Decimator.mix's float steps with +mix+ (a
// register, or its scalar when it has no pointer); +obj+ is the
// GraphNode::Decimator (its @state, @rng, @sample_rate, @jitter, and @mode
// are read each block).  Raises on bad objects.
void mb_plan_decimate(float *d, const struct mb_signal *in, const struct mb_signal *rate, const struct mb_signal *mix, VALUE obj, size_t n);

// OP_RESONATOR: FastResonator.ping (or .modes if +modal+; plan_resonator.c,
// through mb_resonator.h) on the real input +in+ into +d+ at frequency
// +freq+ (Hz) with decay +decay+ (samples to -60 dB); +obj+ is the
// GraphNode::Resonator (its @state, @sample_rate, @cos_phase, @sin_phase,
// and a ModalResonator's @table are read each block).  Raises on bad
// objects.
void mb_plan_resonator(float *d, const struct mb_signal *in, const struct mb_signal *freq, const struct mb_signal *decay, int modal, VALUE obj, size_t n);

#endif
