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

#endif
