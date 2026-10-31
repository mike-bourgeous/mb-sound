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

// FastFilter's highest cutoff ratio (states flush on the grid of
// MB_FLUSH_GRID in mb_svf.h)
#define PF_MAX_CUTOFF_RATIO 0.49

// Samples per pass of the lane-major kernels: each pass first works out
// every lane's coefficients for these samples (lane by lane, as the single
// filter kernel does, with its caching), then runs the recursions with the
// lanes interleaved.
#define PF_CHUNK 64

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
	long fk; // samples since the last flush grid point (see MB_FLUSH_GRID)
};

static void pf_svf_read(struct pf_svf_lane *f, VALUE filter)
{
	f->filter = filter;
	f->state = rb_ivar_get(filter, id_state);
	Check_Type(f->state, T_ARRAY);
	if (RARRAY_LEN(f->state) != 2 && RARRAY_LEN(f->state) != 3) {
		rb_raise(rb_eArgError, "SVF state must have two elements (three with the flush grid count)");
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
	f->fk = mb_flush_count_read(f->state, 2);
	f->pi_over_rate = M_PI / rate;
	f->fc_max = rate * PF_MAX_CUTOFF_RATIO;
}

// Counts one sample of lane +f+ on the flush grid, flushing its states
// *ic1 and *ic2 at the grid point.
static inline void pf_svf_tick(struct pf_svf_lane *f, double *ic1, double *ic2)
{
	if (++f->fk >= MB_FLUSH_GRID) {
		f->fk = 0;
		mb_flush_value(ic1);
		mb_flush_value(ic2);
	}
}

// Stores the state (flushed on the grid while running) with its flush grid
// count, and remembers the last parameters as SVF#remember does (cutoff,
// quality, and with a gain input the gain).
static void pf_svf_write(struct pf_svf_lane *f, const struct mb_plan_param *fc, const struct mb_plan_param *q,
		const struct mb_plan_param *g, _Bool remember_gain, size_t n)
{
	rb_ary_store(f->state, 0, rb_float_new(f->ic1));
	rb_ary_store(f->state, 1, rb_float_new(f->ic2));
	rb_ary_store(f->state, 2, rb_float_new((double)f->fk));

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
		pf_svf_tick(&f, &f.ic1, &f.ic2);
	}

	pf_svf_write(&f, fc, q, g, remember_gain, n);

	RB_GC_GUARD(f.state);
	RB_GC_GUARD(obj);
}


// True if parameter +p+ holds one value over samples +from+ to +to+
// (exclusive): a number, or a register whose samples there are all equal
// (bitwise, so a NaN or -0 counts as a change, as the coefficient caches
// see them).
static inline _Bool pf_param_steady(const struct mb_plan_param *p, size_t from, size_t to)
{
	if (!p->p) {
		return 1;
	}

	const float *v = p->p;
	float first = v[from];
	_Bool same = 1;
	for (size_t i = from + 1; i < to; i++) {
		same &= v[i] == first;
	}
	return same && first == first;
}

void mb_plan_svf_lanes(int lanes, float *const *d, const float *const *a, const struct mb_plan_param *prm,
		const _Bool *remember_gain, const VALUE *objs, size_t n)
{
	pf_ids();
	size_t L = (size_t)lanes;

	VALUE tmpv;
	size_t nd = 7 * PF_CHUNK * L + 8 * L;
	double *mem = ALLOCV_N(double, tmpv, nd);
	double *X = mem, *A1 = X + PF_CHUNK * L, *A2 = A1 + PF_CHUNK * L, *A3 = A2 + PF_CHUNK * L;
	double *M0 = A3 + PF_CHUNK * L, *M1 = M0 + PF_CHUNK * L, *M2 = M1 + PF_CHUNK * L;
	double *IC1 = M2 + PF_CHUNK * L, *IC2 = IC1 + L;
	double *B1 = IC2 + L, *B2 = B1 + L, *B3 = B2 + L, *N0 = B3 + L, *N1 = N0 + L, *N2 = N1 + L;

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

		// Coefficients (and inputs), lane by lane: one set for a lane whose
		// parameters hold for the whole pass (the single kernel's cache would
		// compute it on the pass's first sample and keep it), else one per
		// sample
		_Bool all_steady = 1;
		for (size_t l = 0; l < L; l++) {
			const struct mb_plan_param *p = prm + 3 * l;
			struct mb_svf *s = &svf[l];
			const float *al = a[l] + c0;
			if (pf_param_steady(&p[0], c0, c0 + m) && pf_param_steady(&p[1], c0, c0 + m) && pf_param_steady(&p[2], c0, c0 + m)) {
				mb_svf_coefficients(s, f[l].type, mb_plan_param_at(&p[0], c0), mb_plan_param_at(&p[1], c0), mb_plan_param_at(&p[2], c0),
						f[l].pi_over_rate, f[l].fc_max);
				B1[l] = s->a1;
				B2[l] = s->a2;
				B3[l] = s->a3;
				N0[l] = s->m0;
				N1[l] = s->m1;
				N2[l] = s->m2;
				for (size_t k = 0; k < m; k++) {
					X[k * L + l] = al[k];
				}
				if (!all_steady) {
					for (size_t k = 0; k < m; k++) {
						size_t j = k * L + l;
						A1[j] = s->a1;
						A2[j] = s->a2;
						A3[j] = s->a3;
						M0[j] = s->m0;
						M1[j] = s->m1;
						M2[j] = s->m2;
					}
				}
				continue;
			}

			if (all_steady) {
				// Lanes before this one held their coefficients: spread them
				// over the pass for the per-sample loop
				all_steady = 0;
				for (size_t q = 0; q < l; q++) {
					for (size_t k = 0; k < m; k++) {
						size_t j = k * L + q;
						A1[j] = B1[q];
						A2[j] = B2[q];
						A3[j] = B3[q];
						M0[j] = N0[q];
						M1[j] = N1[q];
						M2[j] = N2[q];
					}
				}
			}

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
				X[j] = al[k];
			}
		}

		// The recursions, every lane's sample k before any lane's k + 1
		if (all_steady) {
			for (size_t k = 0; k < m; k++) {
				double *x = X + k * L;
				for (size_t l = 0; l < L; l++) {
					x[l] = mb_svf_step_with(B1[l], B2[l], B3[l], N0[l], N1[l], N2[l], x[l], &IC1[l], &IC2[l]);
					pf_svf_tick(&f[l], &IC1[l], &IC2[l]);
				}
			}
		} else {
			for (size_t k = 0; k < m; k++) {
				for (size_t l = 0; l < L; l++) {
					size_t j = k * L + l;
					X[j] = mb_svf_step_with(A1[j], A2[j], A3[j], M0[j], M1[j], M2[j], X[j], &IC1[l], &IC2[l]);
					pf_svf_tick(&f[l], &IC1[l], &IC2[l]);
				}
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

// A four-pole's (or diode ladder's) settings and state, read from the
// Filter::FourPole +filter+ (its @state and @sample_rate, read each block:
// FourPole#reset replaces the state Array) and the op's settings +cfg+.
struct pf_fp_lane {
	VALUE filter, state;
	struct mb_fp_args args;
	_Bool diode;
	double st[4];
	long fk; // samples since the last flush grid point (see MB_FLUSH_GRID)
};

static void pf_fp_read(struct pf_fp_lane *f, VALUE filter, const double *cfg)
{
	f->filter = filter;
	f->state = rb_ivar_get(filter, id_state);
	Check_Type(f->state, T_ARRAY);
	if (RARRAY_LEN(f->state) != 4 && RARRAY_LEN(f->state) != 5) {
		rb_raise(rb_eArgError, "Four-pole state must have four elements (five with the flush grid count)");
	}
	double rate = NUM2DBL(rb_ivar_get(filter, id_sample_rate));
	if (!(rate > 0) || !isfinite(rate)) {
		rb_raise(rb_eArgError, "Sample rate must be positive and finite");
	}

	struct mb_fp_args args = {
		.rate = rate, .k_max = cfg[0], .comp = cfg[1], .drive = cfg[2],
		.mix = { cfg[3], cfg[4], cfg[5], cfg[6], cfg[7] },
		.curve = (int)cfg[8], .drive_mode = (int)cfg[9], .clip = (int)cfg[10], .normalize = (int)cfg[11],
		.tuning = (int)cfg[13],
	};
	f->args = args;
	f->diode = cfg[12] != 0;
	if (!isfinite(args.k_max) || !isfinite(args.comp) || !(args.drive >= 0) || !isfinite(args.drive) ||
			args.curve < FP_CURVE_LINEAR || args.curve > FP_CURVE_SELF_OSC_DB ||
			args.drive_mode < FP_DRIVE_INPUT || args.drive_mode > FP_DRIVE_FEEDBACK || (f->diode && args.drive_mode == FP_DRIVE_STAGES) ||
			args.clip < FP_CLIP_SOFT || args.clip > FP_CLIP_HARD ||
			!fp_tuning_valid(args.tuning, f->diode)) {
		rb_raise(rb_eArgError, "Bad plan four-pole settings");
	}

	for (int j = 0; j < 4; j++) {
		f->st[j] = mb_finite_entry(f->state, j);
	}
	f->fk = mb_flush_count_read(f->state, 4);
}

// Stores the state (flushed on the grid while running) with its flush grid
// count, and remembers the last parameters (FourPole#remember).
static void pf_fp_write(struct pf_fp_lane *f, const struct mb_plan_param *fc, const struct mb_plan_param *res, size_t n)
{
	for (int j = 0; j < 4; j++) {
		rb_ary_store(f->state, j, rb_float_new(f->st[j]));
	}
	rb_ary_store(f->state, 4, rb_float_new((double)f->fk));

	if (n > 0) {
		rb_ivar_set(f->filter, id_cutoff, rb_float_new(mb_plan_param_at(fc, n - 1)));
		rb_ivar_set(f->filter, id_resonance, rb_float_new(mb_plan_param_at(res, n - 1)));
	}
}

void mb_plan_four_pole(float *d, const float *a, const struct mb_plan_param *fc, const struct mb_plan_param *res,
		const struct mb_plan_param *drive, const double *cfg, VALUE obj, size_t n)
{
	pf_ids();
	struct pf_fp_lane f;
	pf_fp_read(&f, obj, cfg);

	struct mb_signal fc_sig = { .scalar = fc->scalar, .ptr = fc->p, .step = 1 };
	struct mb_signal res_sig = { .scalar = res->scalar, .ptr = res->p, .step = 1 };
	struct mb_signal drive_sig = { .scalar = 0.0, .ptr = drive ? drive->p : NULL, .step = 1 };
	const struct mb_signal *live = drive && drive->p ? &drive_sig : NULL;
	if (live) {
		// (as FastFilter's live drive: starting linear, set by the first sample)
		f.args.drive = 0.0;
	}

	if (f.diode) {
		mb_diode_ladder_run(&f.args, a, d, n, &fc_sig, &res_sig, live, f.st, &f.fk);
	} else {
		mb_four_pole_run(&f.args, a, d, n, &fc_sig, &res_sig, live, f.st, &f.fk);
	}

	pf_fp_write(&f, fc, res, n);

	RB_GC_GUARD(f.state);
	RB_GC_GUARD(obj);
}

void mb_plan_four_pole_lanes(int lanes, float *const *d, const float *const *a, const struct mb_plan_param *prm,
		const double *const *cfg, const VALUE *objs, size_t n)
{
	pf_ids();
	size_t L = (size_t)lanes;

	struct pf_fp_lane f[L];
	for (size_t l = 0; l < L; l++) {
		pf_fp_read(&f[l], objs[l], cfg[l]);
	}

	// Four-poles and diode ladders, each lane-major among their own kind
	size_t nfp = 0, ndl = 0;
	size_t fp_lane[L], dl_lane[L];
	for (size_t l = 0; l < L; l++) {
		if (f[l].diode) {
			dl_lane[ndl++] = l;
		} else {
			fp_lane[nfp++] = l;
		}
	}

	VALUE tmpv;
	size_t ncoef = sizeof(struct mb_dl_coef) > sizeof(struct mb_fp_coef) ? sizeof(struct mb_dl_coef) : sizeof(struct mb_fp_coef);
	char *mem = ALLOCV_N(char, tmpv, PF_CHUNK * L * (ncoef + sizeof(double)));
	double *X = (double *)mem;
	void *coefs = mem + PF_CHUNK * L * sizeof(double);
	struct mb_fp_coef *FC = coefs;
	struct mb_dl_coef *DC = coefs;

	if (nfp > 0) {
		struct mb_fp_cache cc[nfp];
		double pi_over_rate[nfp], fc_max[nfp], inv_drive[nfp];
		_Bool driven[nfp];
		for (size_t j = 0; j < nfp; j++) {
			const struct mb_fp_args *args = &f[fp_lane[j]].args;
			mb_fp_cache_init(&cc[j]);
			pi_over_rate[j] = M_PI / args->rate;
			fc_max[j] = args->rate * FP_MAX_CUTOFF_RATIO;
			inv_drive[j] = args->drive > 0 ? 1.0 / args->drive : 0.0;
			driven[j] = args->drive > 0;
		}

		_Bool steady[nfp];
		for (size_t c0 = 0; c0 < n; c0 += PF_CHUNK) {
			size_t m = n - c0 < PF_CHUNK ? n - c0 : PF_CHUNK;
			for (size_t j = 0; j < nfp; j++) {
				size_t l = fp_lane[j];
				const struct mb_plan_param *p = prm + 2 * l;
				// Parameters that hold for the pass: the cache's one set (see
				// mb_plan_svf_lanes)
				steady[j] = pf_param_steady(&p[0], c0, c0 + m) && pf_param_steady(&p[1], c0, c0 + m);
				if (steady[j]) {
					mb_fp_coef_update(&cc[j], &f[l].args, mb_plan_param_at(&p[0], c0), mb_plan_param_at(&p[1], c0), pi_over_rate[j], fc_max[j]);
				}
				for (size_t k = 0; k < m; k++) {
					size_t i = c0 + k;
					if (!steady[j]) {
						mb_fp_coef_update(&cc[j], &f[l].args, mb_plan_param_at(&p[0], i), mb_plan_param_at(&p[1], i), pi_over_rate[j], fc_max[j]);
						FC[k * nfp + j] = cc[j].c;
					}
					X[k * nfp + j] = a[l][i];
				}
			}
			for (size_t k = 0; k < m; k++) {
				for (size_t j = 0; j < nfp; j++) {
					size_t l = fp_lane[j];
					const struct mb_fp_coef *c = steady[j] ? &cc[j].c : &FC[k * nfp + j];
					X[k * nfp + j] = mb_fp_step(&f[l].args, c, inv_drive[j], driven[j], X[k * nfp + j], f[l].st);
					mb_fp_flush_tick(&f[l].fk, f[l].st);
				}
			}
			for (size_t j = 0; j < nfp; j++) {
				float *dl = d[fp_lane[j]] + c0;
				for (size_t k = 0; k < m; k++) {
					dl[k] = (float)X[k * nfp + j];
				}
			}
		}
	}

	if (ndl > 0) {
		struct mb_dl_cache cc[ndl];
		double pi_over_rate[ndl], fc_max[ndl];
		_Bool driven[ndl];
		for (size_t j = 0; j < ndl; j++) {
			const struct mb_fp_args *args = &f[dl_lane[j]].args;
			mb_dl_cache_init(&cc[j], args);
			pi_over_rate[j] = M_PI / args->rate;
			fc_max[j] = args->rate * FP_MAX_CUTOFF_RATIO;
			driven[j] = args->drive > 0;
		}

		_Bool steady[ndl];
		for (size_t c0 = 0; c0 < n; c0 += PF_CHUNK) {
			size_t m = n - c0 < PF_CHUNK ? n - c0 : PF_CHUNK;
			for (size_t j = 0; j < ndl; j++) {
				size_t l = dl_lane[j];
				const struct mb_plan_param *p = prm + 2 * l;
				steady[j] = pf_param_steady(&p[0], c0, c0 + m) && pf_param_steady(&p[1], c0, c0 + m);
				if (steady[j]) {
					mb_dl_coef_update(&cc[j], &f[l].args, mb_plan_param_at(&p[0], c0), mb_plan_param_at(&p[1], c0), pi_over_rate[j], fc_max[j]);
				}
				for (size_t k = 0; k < m; k++) {
					size_t i = c0 + k;
					if (!steady[j]) {
						mb_dl_coef_update(&cc[j], &f[l].args, mb_plan_param_at(&p[0], i), mb_plan_param_at(&p[1], i), pi_over_rate[j], fc_max[j]);
						DC[k * ndl + j] = cc[j].c;
					}
					X[k * ndl + j] = a[l][i];
				}
			}
			for (size_t k = 0; k < m; k++) {
				for (size_t j = 0; j < ndl; j++) {
					size_t l = dl_lane[j];
					const struct mb_dl_coef *c = steady[j] ? &cc[j].c : &DC[k * ndl + j];
					X[k * ndl + j] = mb_dl_step(&f[l].args, c, driven[j], X[k * ndl + j], f[l].st);
					mb_fp_flush_tick(&f[l].fk, f[l].st);
				}
			}
			for (size_t j = 0; j < ndl; j++) {
				float *dl = d[dl_lane[j]] + c0;
				for (size_t k = 0; k < m; k++) {
					dl[k] = (float)X[k * ndl + j];
				}
			}
		}
	}

	for (size_t l = 0; l < L; l++) {
		const struct mb_plan_param *p = prm + 2 * l;
		pf_fp_write(&f[l], &p[0], &p[1], n);
		RB_GC_GUARD(f[l].state);
	}

	ALLOCV_END(tmpv);
}
