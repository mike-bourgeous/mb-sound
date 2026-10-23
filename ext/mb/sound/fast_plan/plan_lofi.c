/*
 * Lo-fi nodes as plan ops (fast_plan.c's OP_DECIMATE; see
 * Plan::Op::Decimate): FastLofi.decimate's kernel through mb_decimate.h,
 * so a planned decimator runs the same operations as its node, on the
 * node's own state and random state, followed by GraphNode::Decimator.mix's
 * Numo float steps when the node blends in its input.
 */
#include <stdint.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_decimate.h"

#include "plan_filters.h"

static ID id_state, id_rng, id_sample_rate, id_jitter, id_mode;

// A contiguous 1D NArray ivar +id+ of +obj+ of class +klass+ with exactly
// +len+ elements, for writing.
static void *lofi_ivar(VALUE obj, ID id, VALUE klass, long len, const char *what)
{
	VALUE v = rb_ivar_get(obj, id);
	if (CLASS_OF(v) != klass || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || (long)RNARRAY_SIZE(v) != len) {
		rb_raise(rb_eArgError, "A planned decimator's %s must be a contiguous NArray of %ld values", what, len);
	}
	if (OBJ_FROZEN(v)) rb_raise(rb_eFrozenError, "A planned decimator's %s is frozen", what);
	return nary_get_pointer_for_write(v) + nary_get_offset(v);
}

void mb_plan_decimate(float *d, const struct mb_signal *in, const struct mb_signal *rate, const struct mb_signal *mix, VALUE obj, size_t n)
{
	if (!id_state) {
		id_state = rb_intern("@state");
		id_rng = rb_intern("@rng");
		id_sample_rate = rb_intern("@sample_rate");
		id_jitter = rb_intern("@jitter");
		id_mode = rb_intern("@mode");
	}

	double fs = NUM2DBL(rb_ivar_get(obj, id_sample_rate));
	if (!(fs > 0)) rb_raise(rb_eArgError, "The sample rate must be positive");
	double jitter = NUM2DBL(rb_ivar_get(obj, id_jitter));
	if (!(jitter >= 0 && jitter <= 0.95)) rb_raise(rb_eArgError, "The jitter must be from 0 to 0.95");
	int mode = NUM2INT(rb_ivar_get(obj, id_mode));
	if (mode != 0 && mode != 1) rb_raise(rb_eArgError, "The mode must be 0 (hold) or 1 (linear)");

	double *st = lofi_ivar(obj, id_state, numo_cDFloat, MB_DECIMATE_STATE_LENGTH, "state");
	uint64_t *rp = lofi_ivar(obj, id_rng, numo_cUInt64, 1, "random state");

	mb_decimate(d, in, rate, st, rp, fs, jitter, mode, n);

	if (mix) {
		// GraphNode::Decimator.mix: out * mix + input * (1 - mix), as Numo
		// computes it on SFloats (a Float operand cast to float first; 1 -
		// an SFloat in float)
		const float *x = in->ptr;
		if (mix->ptr) {
			const float *m = mix->ptr;
			for (size_t i = 0; i < n; i++) {
				float wet = d[i] * m[i];
				float g = 1.0f - m[i];
				float dry = x[i] * g;
				d[i] = wet + dry;
			}
		} else {
			float m = (float)mix->scalar;
			float g = (float)(1.0 - mix->scalar);
			for (size_t i = 0; i < n; i++) {
				float wet = d[i] * m;
				float dry = x[i] * g;
				d[i] = wet + dry;
			}
		}
	}
}
