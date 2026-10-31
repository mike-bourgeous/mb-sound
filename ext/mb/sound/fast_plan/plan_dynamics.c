/*
 * Dynamics nodes as plan ops (fast_plan.c's OP_DYNAMICS; see
 * Plan::Op::Dynamics): FastDynamics.compand's kernel through
 * mb_dynamics.h, so a planned compressor, expander, gate, duck, or
 * compander runs the same operations as its node, on the node's own state
 * and lookahead delay.  fast_dynamics is built with -ffp-contract=off; the
 * header turns clang's contraction off by pragma (GCC's -std=c99 doesn't
 * contract).
 */
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_dynamics.h"

#include "plan_filters.h"

_Static_assert(MB_PLAN_DYN_SIGNALS == DT_COUNT, "plan_filters.h's MB_PLAN_DYN_SIGNALS must be mb_dynamics.h's DT_COUNT");

static ID id_params, id_plan_curve, id_state, id_delay;

// A contiguous 1D DFloat ivar +id+ of +obj+ with at least +min+ elements.
static double *dyn_ivar(VALUE obj, ID id, long min, const char *what, _Bool write)
{
	VALUE v = rb_ivar_get(obj, id);
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || (long)RNARRAY_SIZE(v) < min) {
		rb_raise(rb_eArgError, "A planned dynamics node's %s must be a contiguous DFloat of at least %ld values", what, min);
	}
	if (!write) return (double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	if (OBJ_FROZEN(v)) rb_raise(rb_eFrozenError, "A planned dynamics node's %s is frozen", what);
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

void mb_plan_dynamics(float *const *out, long nch, const struct mb_signal *in, const struct mb_signal *side, long nside, const struct mb_signal *tim, VALUE obj, size_t n)
{
	if (!id_params) {
		id_params = rb_intern("@params");
		id_plan_curve = rb_intern("@plan_curve");
		id_state = rb_intern("@state");
		id_delay = rb_intern("@delay");
	}

	const double *par = dyn_ivar(obj, id_params, DP_COUNT, "params", 0);
	VALUE curve = rb_ivar_get(obj, id_plan_curve);
	const double *seg = dyn_ivar(obj, id_plan_curve, 5, "curve", 0);
	long nseg = (long)RNARRAY_SIZE(curve) / 5;
	long la = (long)par[DP_LOOKAHEAD];
	if (la < 0) rb_raise(rb_eArgError, "Lookahead must not be negative");
	long ndet = par[DP_LINK] != 0 ? 1 : nch;
	if (par[DP_LINK] == 0 && nside != nch) rb_raise(rb_eArgError, "An unlinked planned dynamics node needs one detector signal per channel");
	if (nside < 1) rb_raise(rb_eArgError, "A planned dynamics node needs a detector signal");

	double *st = dyn_ivar(obj, id_state, ndet * DYN_DET_STATE + 1, "state", 1);
	double *dl = la > 0 ? dyn_ivar(obj, id_delay, nch * la, "delay", 1) : NULL;

	mb_dyn_compand(out, nch, in, side, nside, tim, par, seg, nseg, st, dl, (long)n);
	RB_GC_GUARD(curve);
}
