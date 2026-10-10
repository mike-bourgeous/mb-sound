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

// A cookbook filter's settings, coefficients, and state, read from the
// Filter::Cookbook +filter+ each block.
struct pb_lane {
	VALUE filter;
	double rate, g, f0_max;
	struct biquad_coeffs bq;
	double st[4];
};

static void pb_read(struct pb_lane *f, VALUE filter)
{
	f->filter = filter;
	f->rate = NUM2DBL(rb_ivar_get(filter, id_sample_rate));
	VALUE gain_v = rb_ivar_get(filter, id_db_gain);
	f->g = RTEST(gain_v) ? NUM2DBL(gain_v) : NAN;
	f->f0_max = NUM2DBL(rb_ivar_get(filter, id_f0_max));

	struct biquad_coeffs bq = {
		.b0 = NUM2DBL(rb_ivar_get(filter, id_b0)),
		.b1 = NUM2DBL(rb_ivar_get(filter, id_b1)),
		.b2 = NUM2DBL(rb_ivar_get(filter, id_b2)),
		.a1 = NUM2DBL(rb_ivar_get(filter, id_a1)),
		.a2 = NUM2DBL(rb_ivar_get(filter, id_a2)),
	};
	f->bq = bq;
	f->st[0] = NUM2DBL(rb_ivar_get(filter, id_x1));
	f->st[1] = NUM2DBL(rb_ivar_get(filter, id_x2));
	f->st[2] = NUM2DBL(rb_ivar_get(filter, id_y1));
	f->st[3] = NUM2DBL(rb_ivar_get(filter, id_y2));
}

// Stores the coefficients and state, and the last quality and cutoff as
// Cookbook#dynamic_process_c does (+n+ > 0).
static void pb_write(struct pb_lane *f, const float *cut, const float *q, size_t n)
{
	VALUE filter = f->filter;
	rb_ivar_set(filter, id_omega, rb_float_new(f->bq.omega));
	rb_ivar_set(filter, id_b0, rb_float_new(f->bq.b0));
	rb_ivar_set(filter, id_b1, rb_float_new(f->bq.b1));
	rb_ivar_set(filter, id_b2, rb_float_new(f->bq.b2));
	rb_ivar_set(filter, id_a1, rb_float_new(f->bq.a1));
	rb_ivar_set(filter, id_a2, rb_float_new(f->bq.a2));
	rb_ivar_set(filter, id_x1, rb_float_new(f->st[0]));
	rb_ivar_set(filter, id_x2, rb_float_new(f->st[1]));
	rb_ivar_set(filter, id_y1, rb_float_new(f->st[2]));
	rb_ivar_set(filter, id_y2, rb_float_new(f->st[3]));

	// Cookbook#dynamic_process_c: the last quality (at least 1e-10) and
	// cutoff (clamped as the kernel clamps it)
	double qv = q[n - 1];
	if (qv < 1e-10) {
		qv = 1e-10;
	}
	rb_ivar_set(filter, id_quality, rb_float_new(qv));
	double f0 = cut[n - 1];
	f0 = f0 >= DYNAMIC_MIN_CUTOFF ? (f0 <= f->f0_max ? f0 : f->f0_max) : DYNAMIC_MIN_CUTOFF;
	rb_ivar_set(filter, id_center_frequency, rb_float_new(f0));
	rb_ivar_set(filter, id_cutoff, rb_float_new(f0));
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

	struct pb_lane f;
	pb_read(&f, obj);
	mb_dynamic_biquad_run((enum filter_types)type, f.rate, f.g, a, d, cut, q, n, &f.bq, f.st);
	pb_write(&f, cut, q, n);

	RB_GC_GUARD(obj);
}

// Samples per pass of mb_plan_biquad_lanes (see plan_filters.c's PF_CHUNK).
#define PB_CHUNK 64

void mb_plan_biquad_lanes(int lanes, float *const *d, const float *const *a, const float *const *cut, const float *const *q,
		int type, const VALUE *objs, size_t n)
{
	pb_ids();
	if (type < FILT_LOWPASS || type > FILT_BANDPASS_SKIRT) {
		rb_raise(rb_eArgError, "Bad plan biquad filter type %d", type);
	}
	if (n == 0) {
		return;
	}

	size_t L = (size_t)lanes;
	struct pb_lane f[L];
	for (size_t l = 0; l < L; l++) {
		pb_read(&f[l], objs[l]);
	}

	VALUE tmpv;
	char *mem = ALLOCV_N(char, tmpv, PB_CHUNK * L * (sizeof(struct biquad_coeffs) + sizeof(double)));
	double *X = (double *)mem;
	struct biquad_coeffs *C = (struct biquad_coeffs *)(mem + PB_CHUNK * L * sizeof(double));

	for (size_t c0 = 0; c0 < n; c0 += PB_CHUNK) {
		size_t m = n - c0 < PB_CHUNK ? n - c0 : PB_CHUNK;

		// Coefficients, lane by lane, as mb_dynamic_biquad_run computes them
		for (size_t l = 0; l < L; l++) {
			const double f0_max = 0.49 * f[l].rate;
			const float *cl = cut[l], *ql = q[l];
			for (size_t k = 0; k < m; k++) {
				size_t i = c0 + k;
				double f0 = cl[i] >= DYNAMIC_MIN_CUTOFF ? fmin(cl[i], f0_max) : DYNAMIC_MIN_CUTOFF;
				double quality = fmax(ql[i], 1e-10);
				C[k * L + l] = cookbook((enum filter_types)type, f[l].rate, f0, f[l].g, quality, NAN, NAN);
				X[k * L + l] = a[l][i];
			}
		}

		// The recursions, lanes interleaved
		for (size_t k = 0; k < m; k++) {
			for (size_t l = 0; l < L; l++) {
				const struct biquad_coeffs *bq = &C[k * L + l];
				double *st = f[l].st;
				double x0 = X[k * L + l];
				double y0 = biquad_filter(bq->b0, bq->b1, bq->b2, bq->a1, bq->a2, x0, st[0], st[1], st[2], st[3]);
				X[k * L + l] = y0;
				st[3] = st[2];
				st[2] = y0;
				st[1] = st[0];
				st[0] = x0;
			}
		}

		for (size_t l = 0; l < L; l++) {
			float *dl = d[l] + c0;
			for (size_t k = 0; k < m; k++) {
				dl[k] = X[k * L + l];
			}
		}

		if (c0 + m == n) {
			for (size_t l = 0; l < L; l++) {
				f[l].bq = C[(m - 1) * L + l];
			}
		}
	}

	for (size_t l = 0; l < L; l++) {
		pb_write(&f[l], cut[l], q[l], n);
	}

	ALLOCV_END(tmpv);
}
