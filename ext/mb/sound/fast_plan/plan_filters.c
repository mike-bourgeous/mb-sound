/*
 * Filters as plan ops (see plan_filters.h and Plan::Op::FilterSvf, ...).
 * Each runs its node's kernel on registers: the same operations as the
 * node's #sample (bit for bit), with the node's state where the node keeps
 * it, so a plan can drop at any block boundary.  Built with
 * -ffp-contract=off like the rest of fast_plan.
 */
// Nothing is contracted into multiply-adds, as in fast_filter and fast_loop
// (built with -ffp-contract=off), whose kernels these share: GCC doesn't
// contract in ISO C mode, clang does by default.
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#endif

#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_svf.h"
#include "mb_four_pole.h"

#include "plan_filters.h"

// FastFilter's lowest kept state (fast_filter.c's FP_FLUSH) and highest
// cutoff ratio
#define PF_FLUSH 1e-30
#define PF_MAX_CUTOFF_RATIO 0.49

static ID id_sample_rate, id_type_id, id_cutoff, id_quality, id_gain, id_state, id_resonance;

static void pf_ids(void)
{
	if (!id_sample_rate) {
		id_sample_rate = rb_intern("@sample_rate");
		id_type_id = rb_intern("@type_id");
		id_cutoff = rb_intern("@cutoff");
		id_quality = rb_intern("@quality");
		id_gain = rb_intern("@gain");
		id_state = rb_intern("@state");
		id_resonance = rb_intern("@resonance");
	}
}

// An SVF's settings and state, read from the Filter::SVF +filter+ (its
// @state, @type_id, and @sample_rate, read each block: SVF#reset replaces
// the state Array).
struct pf_svf_lane {
	VALUE filter, state;
	int type;
	double pi_over_rate, fc_max;
	double ic1, ic2;
};

static void pf_svf_read(struct pf_svf_lane *f, VALUE filter)
{
	f->filter = filter;
	f->state = rb_ivar_get(filter, id_state);
	Check_Type(f->state, T_ARRAY);
	if (RARRAY_LEN(f->state) != 2) {
		rb_raise(rb_eArgError, "SVF state must have two elements");
	}

	f->type = NUM2INT(rb_ivar_get(filter, id_type_id));
	if (f->type < SVF_LOWPASS || f->type > SVF_BANDPASS_SKIRT) {
		rb_raise(rb_eArgError, "SVF filter type must be 0..8");
	}
	double rate = NUM2DBL(rb_ivar_get(filter, id_sample_rate));
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}

	f->ic1 = mb_finite_entry(f->state, 0);
	f->ic2 = mb_finite_entry(f->state, 1);
	f->pi_over_rate = M_PI / rate;
	f->fc_max = rate * PF_MAX_CUTOFF_RATIO;
}

// Flushes and stores the state, and remembers the last parameters as
// SVF#remember does (cutoff, quality, and with a gain input the gain).
static void pf_svf_write(struct pf_svf_lane *f, const struct mb_plan_param *fc, const struct mb_plan_param *q,
		const struct mb_plan_param *g, _Bool remember_gain, size_t n)
{
	double ic1 = f->ic1, ic2 = f->ic2;
	if (!isfinite(ic1) || fabs(ic1) < PF_FLUSH) {
		ic1 = 0.0;
	}
	if (!isfinite(ic2) || fabs(ic2) < PF_FLUSH) {
		ic2 = 0.0;
	}
	rb_ary_store(f->state, 0, rb_float_new(ic1));
	rb_ary_store(f->state, 1, rb_float_new(ic2));

	if (n > 0) {
		rb_ivar_set(f->filter, id_cutoff, rb_float_new(mb_plan_param_at(fc, n - 1)));
		rb_ivar_set(f->filter, id_quality, rb_float_new(mb_plan_param_at(q, n - 1)));
		if (remember_gain) {
			rb_ivar_set(f->filter, id_gain, rb_float_new(mb_plan_param_at(g, n - 1)));
		}
	}
}

void mb_plan_svf(float *d, const float *a, const struct mb_plan_param *fc, const struct mb_plan_param *q,
		const struct mb_plan_param *g, _Bool remember_gain, VALUE obj, size_t n)
{
	pf_ids();
	struct pf_svf_lane f;
	pf_svf_read(&f, obj);

	struct mb_svf svf;
	mb_svf_init(&svf);
	for (size_t i = 0; i < n; i++) {
		mb_svf_coefficients(&svf, f.type, mb_plan_param_at(fc, i), mb_plan_param_at(q, i), mb_plan_param_at(g, i), f.pi_over_rate, f.fc_max);
		d[i] = mb_svf_step(&svf, a[i], &f.ic1, &f.ic2);
	}

	pf_svf_write(&f, fc, q, g, remember_gain, n);

	RB_GC_GUARD(f.state);
	RB_GC_GUARD(obj);
}

// Samples per pass of the lane-major kernels: each pass first works out
// every lane's coefficients for these samples (lane by lane, as the single
// filter kernel does, with its caching), then runs the recursions with the
// lanes interleaved.
#define PF_CHUNK 64

void mb_plan_svf_lanes(int lanes, float *const *d, const float *const *a, const struct mb_plan_param *prm,
		const _Bool *remember_gain, const VALUE *objs, size_t n)
{
	pf_ids();
	size_t L = (size_t)lanes;

	VALUE tmpv;
	size_t nd = 7 * PF_CHUNK * L + 2 * L;
	double *mem = ALLOCV_N(double, tmpv, nd);
	double *X = mem, *A1 = X + PF_CHUNK * L, *A2 = A1 + PF_CHUNK * L, *A3 = A2 + PF_CHUNK * L;
	double *M0 = A3 + PF_CHUNK * L, *M1 = M0 + PF_CHUNK * L, *M2 = M1 + PF_CHUNK * L;
	double *IC1 = M2 + PF_CHUNK * L, *IC2 = IC1 + L;

	struct pf_svf_lane f[L];
	struct mb_svf svf[L];
	for (size_t l = 0; l < L; l++) {
		pf_svf_read(&f[l], objs[l]);
		mb_svf_init(&svf[l]);
		IC1[l] = f[l].ic1;
		IC2[l] = f[l].ic2;
	}

	for (size_t c0 = 0; c0 < n; c0 += PF_CHUNK) {
		size_t m = n - c0 < PF_CHUNK ? n - c0 : PF_CHUNK;

		// Coefficients (and inputs), lane by lane
		for (size_t l = 0; l < L; l++) {
			const struct mb_plan_param *p = prm + 3 * l;
			struct mb_svf *s = &svf[l];
			for (size_t k = 0; k < m; k++) {
				size_t i = c0 + k;
				mb_svf_coefficients(s, f[l].type, mb_plan_param_at(&p[0], i), mb_plan_param_at(&p[1], i), mb_plan_param_at(&p[2], i),
						f[l].pi_over_rate, f[l].fc_max);
				size_t j = k * L + l;
				A1[j] = s->a1;
				A2[j] = s->a2;
				A3[j] = s->a3;
				M0[j] = s->m0;
				M1[j] = s->m1;
				M2[j] = s->m2;
				X[j] = a[l][i];
			}
		}

		// The recursions, every lane's sample k before any lane's k + 1
		for (size_t k = 0; k < m; k++) {
			for (size_t l = 0; l < L; l++) {
				size_t j = k * L + l;
				X[j] = mb_svf_step_with(A1[j], A2[j], A3[j], M0[j], M1[j], M2[j], X[j], &IC1[l], &IC2[l]);
			}
		}

		for (size_t l = 0; l < L; l++) {
			float *dl = d[l] + c0;
			for (size_t k = 0; k < m; k++) {
				dl[k] = X[k * L + l];
			}
		}
	}

	for (size_t l = 0; l < L; l++) {
		f[l].ic1 = IC1[l];
		f[l].ic2 = IC2[l];
		const struct mb_plan_param *p = prm + 3 * l;
		pf_svf_write(&f[l], &p[0], &p[1], &p[2], remember_gain[l], n);
		RB_GC_GUARD(f[l].state);
	}

	ALLOCV_END(tmpv);
}

void mb_plan_four_pole(float *d, const float *a, const struct mb_plan_param *fc, const struct mb_plan_param *res,
		const double *cfg, VALUE obj, size_t n)
{
	pf_ids();
	VALUE filter = obj;
	VALUE state = rb_ivar_get(filter, id_state); // (read each block: FourPole#reset replaces it)
	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) {
		rb_raise(rb_eArgError, "Four-pole state must have four elements");
	}
	double rate = NUM2DBL(rb_ivar_get(filter, id_sample_rate));
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}

	struct mb_fp_args args = {
		.rate = rate, .k_max = cfg[0], .comp = cfg[1], .drive = cfg[2],
		.mix = { cfg[3], cfg[4], cfg[5], cfg[6], cfg[7] },
		.curve = (int)cfg[8], .drive_mode = (int)cfg[9], .clip = (int)cfg[10], .normalize = (int)cfg[11],
	};
	_Bool diode = cfg[12] != 0;
	if (!isfinite(args.k_max) || !isfinite(args.comp) || !(args.drive >= 0) || !isfinite(args.drive) ||
			args.curve < FP_CURVE_LINEAR || args.curve > FP_CURVE_SELF_OSC_DB ||
			args.drive_mode < FP_DRIVE_INPUT || args.drive_mode > FP_DRIVE_FEEDBACK || (diode && args.drive_mode == FP_DRIVE_STAGES) ||
			args.clip < FP_CLIP_SOFT || args.clip > FP_CLIP_HARD) {
		rb_raise(rb_eArgError, "Bad plan four-pole settings");
	}

	struct mb_signal fc_sig = { .scalar = fc->scalar, .ptr = fc->p, .step = 1 };
	struct mb_signal res_sig = { .scalar = res->scalar, .ptr = res->p, .step = 1 };
	double st[4];
	for (int j = 0; j < 4; j++) {
		st[j] = mb_finite_entry(state, j);
	}

	if (diode) {
		mb_diode_ladder_run(&args, a, d, n, &fc_sig, &res_sig, st);
	} else {
		mb_four_pole_run(&args, a, d, n, &fc_sig, &res_sig, st);
	}

	mb_fp_flush(st);
	for (int j = 0; j < 4; j++) {
		rb_ary_store(state, j, rb_float_new(st[j]));
	}

	// FourPole#remember
	if (n > 0) {
		rb_ivar_set(filter, id_cutoff, rb_float_new(mb_plan_param_at(fc, n - 1)));
		rb_ivar_set(filter, id_resonance, rb_float_new(mb_plan_param_at(res, n - 1)));
	}

	RB_GC_GUARD(state);
	RB_GC_GUARD(obj);
}
