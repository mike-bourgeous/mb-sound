/*
 * Resonator nodes as plan ops (fast_plan.c's OP_RESONATOR; see
 * Plan::Op::Resonator): FastResonator.ping's and .modes' kernels through
 * mb_resonator.h, so a planned GraphNode::Resonator or ModalResonator runs
 * the same operations as its node, on the node's own state.
 */
#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_resonator.h"

#include "plan_filters.h"

static ID id_state, id_sample_rate, id_cos_phase, id_sin_phase, id_table;

// A contiguous 1D DFloat ivar +id+ of +obj+ with exactly +len+ elements (any
// length > 0 if +len+ is 0).
static double *res_ivar(VALUE obj, ID id, long len, const char *what, _Bool write, long *got)
{
	VALUE v = rb_ivar_get(obj, id);
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) ||
			(len ? (long)RNARRAY_SIZE(v) != len : RNARRAY_SIZE(v) == 0)) {
		rb_raise(rb_eArgError, "A planned resonator's %s must be a contiguous DFloat of the right length", what);
	}
	if (got) *got = (long)RNARRAY_SIZE(v);
	if (!write) return (double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	if (OBJ_FROZEN(v)) rb_raise(rb_eFrozenError, "A planned resonator's %s is frozen", what);
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

void mb_plan_resonator(float *d, const struct mb_signal *in, const struct mb_signal *freq, const struct mb_signal *decay, int modal, VALUE obj, size_t n)
{
	if (!id_state) {
		id_state = rb_intern("@state");
		id_sample_rate = rb_intern("@sample_rate");
		id_cos_phase = rb_intern("@cos_phase");
		id_sin_phase = rb_intern("@sin_phase");
		id_table = rb_intern("@table");
	}

	double fs = NUM2DBL(rb_ivar_get(obj, id_sample_rate));
	if (!(fs > 0)) rb_raise(rb_eArgError, "Sample rate must be positive");

	if (modal) {
		long tlen;
		const double *table = res_ivar(obj, id_table, 0, "mode table", 0, &tlen);
		if (tlen % MB_RES_MODE_FIELDS != 0 || tlen / MB_RES_MODE_FIELDS > MB_RES_MODES_MAX) {
			rb_raise(rb_eArgError, "A planned modal resonator needs %d values per mode, at most %d modes", MB_RES_MODE_FIELDS, MB_RES_MODES_MAX);
		}
		size_t m = (size_t)tlen / MB_RES_MODE_FIELDS;
		double *z = res_ivar(obj, id_state, (long)(2 * m), "state", 1, NULL);
		mb_res_modes(d, in, freq, decay, table, m, z, fs, n);
	} else {
		double *z = res_ivar(obj, id_state, 2, "state", 1, NULL);
		double cp = NUM2DBL(rb_ivar_get(obj, id_cos_phase));
		double sp = NUM2DBL(rb_ivar_get(obj, id_sin_phase));
		mb_res_ping(d, in, freq, decay, z, fs, cp, sp, n);
	}
}
