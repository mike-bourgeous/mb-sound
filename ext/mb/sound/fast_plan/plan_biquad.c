/*
 * The cookbook biquad as a plan op (see plan_filters.h): FastSound's
 * dynamic_biquad loop through mb_biquad.h on registers.  A file of its own
 * so it is compiled as fast_sound compiles the same code (clang's default
 * contraction included), not with plan_filters.c's FP_CONTRACT OFF.
 */
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_biquad.h"

#include "plan_filters.h"

static ID id_sample_rate, id_db_gain, id_f0_max, id_x1, id_x2, id_y1, id_y2;
static ID id_omega, id_b0, id_b1, id_b2, id_a1, id_a2, id_quality, id_center_frequency, id_cutoff;

static void pb_ids(void)
{
	if (!id_sample_rate) {
		id_sample_rate = rb_intern("@sample_rate");
		id_db_gain = rb_intern("@db_gain");
		id_f0_max = rb_intern("@f0_max");
		id_x1 = rb_intern("@x1");
		id_x2 = rb_intern("@x2");
		id_y1 = rb_intern("@y1");
		id_y2 = rb_intern("@y2");
		id_omega = rb_intern("@omega");
		id_b0 = rb_intern("@b0");
		id_b1 = rb_intern("@b1");
		id_b2 = rb_intern("@b2");
		id_a1 = rb_intern("@a1");
		id_a2 = rb_intern("@a2");
		id_quality = rb_intern("@quality");
		id_center_frequency = rb_intern("@center_frequency");
		id_cutoff = rb_intern("@cutoff");
	}
}

void mb_plan_biquad(float *d, const float *a, const float *cut, const float *q, int type, VALUE obj, size_t n)
{
	pb_ids();
	if (type < FILT_LOWPASS || type > FILT_BANDPASS_SKIRT) {
		rb_raise(rb_eArgError, "Bad plan biquad filter type %d", type);
	}
	if (n == 0) {
		return;
	}

	VALUE filter = obj;
	double rate = NUM2DBL(rb_ivar_get(filter, id_sample_rate));
	VALUE gain_v = rb_ivar_get(filter, id_db_gain);
	double g = RTEST(gain_v) ? NUM2DBL(gain_v) : NAN;
	double f0_max = NUM2DBL(rb_ivar_get(filter, id_f0_max));

	struct biquad_coeffs bq = {
		.b0 = NUM2DBL(rb_ivar_get(filter, id_b0)),
		.b1 = NUM2DBL(rb_ivar_get(filter, id_b1)),
		.b2 = NUM2DBL(rb_ivar_get(filter, id_b2)),
		.a1 = NUM2DBL(rb_ivar_get(filter, id_a1)),
		.a2 = NUM2DBL(rb_ivar_get(filter, id_a2)),
	};
	double st[4] = {
		NUM2DBL(rb_ivar_get(filter, id_x1)), NUM2DBL(rb_ivar_get(filter, id_x2)),
		NUM2DBL(rb_ivar_get(filter, id_y1)), NUM2DBL(rb_ivar_get(filter, id_y2)),
	};

	mb_dynamic_biquad_run((enum filter_types)type, rate, g, a, d, cut, q, n, &bq, st);

	rb_ivar_set(filter, id_omega, rb_float_new(bq.omega));
	rb_ivar_set(filter, id_b0, rb_float_new(bq.b0));
	rb_ivar_set(filter, id_b1, rb_float_new(bq.b1));
	rb_ivar_set(filter, id_b2, rb_float_new(bq.b2));
	rb_ivar_set(filter, id_a1, rb_float_new(bq.a1));
	rb_ivar_set(filter, id_a2, rb_float_new(bq.a2));
	rb_ivar_set(filter, id_x1, rb_float_new(st[0]));
	rb_ivar_set(filter, id_x2, rb_float_new(st[1]));
	rb_ivar_set(filter, id_y1, rb_float_new(st[2]));
	rb_ivar_set(filter, id_y2, rb_float_new(st[3]));

	// Cookbook#dynamic_process_c: the last quality (at least 1e-10) and
	// cutoff (clamped as the kernel clamps it)
	double qv = q[n - 1];
	if (qv < 1e-10) {
		qv = 1e-10;
	}
	rb_ivar_set(filter, id_quality, rb_float_new(qv));
	double f0 = cut[n - 1];
	f0 = f0 >= DYNAMIC_MIN_CUTOFF ? (f0 <= f0_max ? f0 : f0_max) : DYNAMIC_MIN_CUTOFF;
	rb_ivar_set(filter, id_center_frequency, rb_float_new(f0));
	rb_ivar_set(filter, id_cutoff, rb_float_new(f0));

	RB_GC_GUARD(obj);
}
