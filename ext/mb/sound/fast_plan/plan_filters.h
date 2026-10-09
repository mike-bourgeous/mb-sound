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

// OP_FOUR_POLE: GraphNode::FourPole (Filter::FourPole#dynamic_process:
// FastFilter.four_pole or .diode_ladder through mb_four_pole.h) on +a+ into
// +d+; +cfg+ is [k_max, compensation, drive, mix (5), curve, drive mode,
// clip, normalize, diode]; +obj+ the Filter::FourPole (its @state and
// @sample_rate read each block, @cutoff and @resonance set to the last
// values as #remember does).
void mb_plan_four_pole(float *d, const float *a, const struct mb_plan_param *fc, const struct mb_plan_param *res,
		const double *cfg, VALUE obj, size_t n);

// OP_BIQUAD (plan_biquad.c): Filter::Cookbook#dynamic_process
// (FastSound.dynamic_biquad through mb_biquad.h) on +a+ into +d+ with the
// cutoff and quality registers +cut+ and +q+; +type+ the cookbook filter
// type id; +obj+ the Filter::Cookbook (its sample rate, dB gain, f0 limit,
// and x/y state read each block, its coefficients, state, quality, and
// cutoff set afterwards as #dynamic_process_c does).
void mb_plan_biquad(float *d, const float *a, const float *cut, const float *q, int type, VALUE obj, size_t n);

#endif
