/*
 * GraphNode::FilterBank as a plan op (fast_plan.c's OP_FILTER_BANK; see
 * Plan::Op::FilterBank): FastFilter.filter_bank's kernel through
 * mb_filter_bank.h, on the node's own config and state, so a planned bank
 * runs the same operations as its node.
 */
#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_filter_bank.h"

#include "plan_filters.h"

static ID id_config, id_state, id_sample_rate;

// A contiguous 1D DFloat ivar +id+ of +obj+ (writable if +write+).
static double *fbank_ivar(VALUE obj, ID id, const char *what, _Bool write, size_t *len)
{
	VALUE v = rb_ivar_get(obj, id);
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "A planned filter bank's %s must be a contiguous 1D DFloat", what);
	}
	*len = RNARRAY_SIZE(v);
	if (!write) return (double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	if (OBJ_FROZEN(v)) rb_raise(rb_eFrozenError, "A planned filter bank's %s is frozen", what);
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

void mb_plan_filter_bank(float *const *out, long nch, const struct mb_signal *x, const struct mb_signal *sig, long nsig, VALUE obj, size_t n)
{
	if (!id_config) {
		id_config = rb_intern("@config");
		id_state = rb_intern("@state");
		id_sample_rate = rb_intern("@sample_rate");
	}

	double rate = NUM2DBL(rb_ivar_get(obj, id_sample_rate));
	if (!(rate > 0) || !isfinite(rate)) rb_raise(rb_eArgError, "Sample rate must be positive and finite");

	size_t cfglen, stlen;
	const double *cfg = fbank_ivar(obj, id_config, "config", 0, &cfglen);
	double *st = fbank_ivar(obj, id_state, "state", 1, &stlen);
	mb_fbank_check(cfg, cfglen, nsig, nch, stlen);
	mb_fbank_run(cfg, x, sig, nsig, (float **)out, st, rate, n);
}
