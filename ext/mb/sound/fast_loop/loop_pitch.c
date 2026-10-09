/*
 * FastLoop.pitch_track: a feedback loop's latency compensation at the
 * played pitch and its sustain shelf (Plan::Loop::Program#pitch_track), in
 * C.  Exact mirror: Program#pitch_track_ruby (the Ruby original; specs and
 * check mode compare every value bit for bit).  Built with
 * -ffp-contract=off like the rest of fast_loop.
 *
 * Program#pitch_code encodes the loop's response program (#response_program)
 * and the value expressions its parameters come from (#value_of chains:
 * constants, boundary inputs and params, products, sums, quotients, powers)
 * once; per block Ruby passes the expressions' sources (each a Float or an
 * NArray with a value per sample) after its own check that something moved.
 * This evaluates, at every PITCH_STEP-th sample of the stream in the block,
 * the DC moments (#latency's group delay and loop gain sign, at the point
 * only), the loop's response at the pitch with and without its SVFs, the
 * sustain shelf (#sustain_point, #sustain_stretch), and the phase-delay
 * latency (#pitch_points), then ramps between points (#pitch_track).
 *
 * Array-ness is tracked per value as in the Ruby version, since its NArray
 * and Float paths round one product differently (a lowpass SVF's DC delay:
 * fc * (pi / rate) per sample, fc * pi / rate for a Float).
 *
 * FastLoop.pitch_track(code, scalars, srcs, count, first, pos, state, outs)
 *   code:    Int32 NArray: [nv, nr, oa, ob, flags (1 history, 2 sustain,
 *            4 uneven filters), nsrc, t source, sustain rate scalar,
 *            then nv value entries of PC_VWORDS, then nr response entries
 *            of PC_RWORDS]
 *   scalars: DFloat NArray of constants and sample rates
 *   srcs:    Array of nsrc sources (Float, or DFloat/SFloat NArray of at
 *            least +count+ values)
 *   count:   samples in the block
 *   first:   the block's first point (sample index)
 *   pos:     the stream position of the block's start
 *   state:   DFloat [a0, a1, a2, b0, b1, b2, have, stretch, have stretch,
 *            sustain ratio], read and written
 *   outs:    Array of 3 DFloat NArrays of at least +count+ values (written
 *            when the values ramp)
 * Returns true if +outs+ hold ramps, false if the values hold (state b).
 */
#include <stdint.h>
#include <string.h>
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_svf.h"

#include "loop_pitch.h"

#define PC_STEP 16
#define PC_STRETCH_EVERY 4
#define PC_SUSTAIN_SHELF 0.85
#define PC_SUSTAIN_SHELF_Q 0.5
#define PC_SUSTAIN_MAX 2.0
#define PC_SUSTAIN_MIN (1.0 / 64)
#define PC_SVF_MAX_CUTOFF_RATIO 0.49

// Value expression kinds and words per entry: [kind, a, b]
enum { VK_CONST = 0, VK_SRC, VK_MUL, VK_ADD, VK_DIV, VK_POW };
#define PC_VWORDS 3

// Response entry kinds (#response_program) and words per entry:
// [kind, x, y, v1, v2, v3, flag, aux]
enum { RK_ONE_A = 0, RK_ONE_B, RK_ADD, RK_SCALE, RK_COPY, RK_DELAY, RK_HALF, RK_SVF };
#define PC_RWORDS 8

#define PC_HEADER 8

struct pc_src {
	const double *d;
	const float *f;
	double c;
	_Bool arr;
};

struct pc_ctx {
	long nv, nr;
	int oa, ob;
	_Bool history, sustain, uneven;
	const int32_t *vx;
	const int32_t *rx;
	const double *sc;
	struct pc_src *src;
	int tsrc;
	double sus_rate;

	// Per point
	double *vval;
	_Bool *varr;
	double *pv;            // scale values, delay times
	double *pfc, *pq, *pg; // SVF parameters
	double *ar, *ai, *br, *bi;
	_Bool *ha, *hb;
	double *mo;            // moments, 4 per entry
};

static void pc_get_src(struct pc_src *s, VALUE v, long count)
{
	s->d = NULL;
	s->f = NULL;
	s->c = 0;
	s->arr = 0;
	if (rb_obj_is_kind_of(v, numo_cNArray)) {
		if (RNARRAY_NDIM(v) != 1 || (long)RNARRAY_SIZE(v) < count) {
			rb_raise(rb_eArgError, "pitch_track sources must be 1-D NArrays of at least the block length");
		}
		if (!nary_check_contiguous(v)) {
			rb_raise(rb_eArgError, "pitch_track sources must be contiguous");
		}
		if (CLASS_OF(v) == numo_cDFloat) {
			s->d = (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
		} else if (CLASS_OF(v) == numo_cSFloat) {
			s->f = (const float *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
		} else {
			rb_raise(rb_eArgError, "pitch_track sources must be DFloat or SFloat");
		}
		s->arr = 1;
	} else {
		s->c = NUM2DBL(v);
	}
}

static inline double pc_at(const struct pc_src *s, long i)
{
	return s->d ? s->d[i] : (s->f ? (double)s->f[i] : s->c);
}

// m1 / m0, or 0 where m0 is 0 (#ratio)
static inline double pc_ratio(double m0, double m1)
{
	return m0 == 0 ? 0.0 : m1 / m0;
}

// An SVF's response at +w+ for its design (#svf_point)
static void pc_svf_point(int type, double fc, double q, double G, double rate, double w, double *cr, double *ci)
{
	double g, k, m[3];
	mb_svf_design(type, fc, q, G, M_PI / rate, rate * PC_SVF_MAX_CUTOFF_RATIO, &g, &k, m);

	double sr = 0.0;
	double si = tan(w * 0.5) / g;
	double nr = m[1] * sr + m[2], ni = m[1] * si;
	double dr = sr * sr - si * si + k * sr + 1.0, di = 2.0 * sr * si + k * si;
	double den = dr * dr + di * di;
	*cr = (nr * dr + ni * di) / den + m[0];
	*ci = (ni * dr - nr * di) / den;
}

// The sustain shelf's lowpass response (#svf_response with type 0, gain 1)
static void pc_shelf_lp(double fc, double rate, double w, double *lr, double *li)
{
	double g, k, m[3];
	mb_svf_design(SVF_LOWPASS, fc, PC_SUSTAIN_SHELF_Q, 1.0, M_PI / rate, rate * PC_SVF_MAX_CUTOFF_RATIO, &g, &k, m);

	double si = tan(w * 0.5) / g;
	double nr = m[2], ni = m[1] * si;
	double dr = 1.0 - si * si, di = k * si;
	double den = dr * dr + di * di;
	*lr = (nr * dr + ni * di) / den + m[0];
	*li = (ni * dr - nr * di) / den;
}

// Evaluates every value expression at sample +i+ (#value_of)
static void pc_values(struct pc_ctx *c, long i)
{
	for (long k = 0; k < c->nv; k++) {
		const int32_t *e = c->vx + k * PC_VWORDS;
		double a, b;
		switch (e[0]) {
			case VK_CONST:
				c->vval[k] = c->sc[e[1]];
				c->varr[k] = 0;
				break;
			case VK_SRC:
				c->vval[k] = pc_at(&c->src[e[1]], i);
				c->varr[k] = c->src[e[1]].arr;
				break;
			default:
				a = c->vval[e[1]];
				b = c->vval[e[2]];
				c->varr[k] = c->varr[e[1]] || c->varr[e[2]];
				switch (e[0]) {
					case VK_MUL: c->vval[k] = a * b; break;
					case VK_ADD: c->vval[k] = a + b; break;
					case VK_DIV: c->vval[k] = a / b; break;
					default: c->vval[k] = pow(a, b); break;
				}
				break;
		}
	}
}

// Each entry's parameters at the point (#pitch_points' params) and the DC
// moments (#moments), from the value expressions at the point.
static void pc_params_moments(struct pc_ctx *c, long i)
{
	for (long k = 0; k < c->nr; k++) {
		const int32_t *e = c->rx + k * PC_RWORDS;
		double *m = c->mo + 4 * k;
		const double *mx = c->mo + 4 * e[1];
		const double *my = c->mo + 4 * e[2];
		double v, d;

		switch (e[0]) {
			case RK_ONE_A:
				m[0] = 1.0; m[1] = 0.0; m[2] = 0.0; m[3] = 0.0;
				break;
			case RK_ONE_B:
				m[0] = 0.0; m[1] = 0.0; m[2] = 1.0; m[3] = 0.0;
				break;
			case RK_ADD:
				m[0] = mx[0] + my[0]; m[1] = mx[1] + my[1]; m[2] = mx[2] + my[2]; m[3] = mx[3] + my[3];
				break;
			case RK_SCALE:
				v = c->vval[e[3]];
				if (e[6]) {
					// #inverse: 1 / x per sample for an NArray, 0 for a Float 0
					v = c->varr[e[3]] ? 1.0 / v : (v == 0 ? 0.0 : 1.0 / v);
				}
				c->pv[k] = v;
				m[0] = mx[0] * v; m[1] = mx[1] * v; m[2] = mx[2] * v; m[3] = mx[3] * v;
				break;
			case RK_COPY:
				m[0] = mx[0]; m[1] = mx[1]; m[2] = mx[2]; m[3] = mx[3];
				break;
			case RK_DELAY:
				d = pc_at(&c->src[e[3]], i);
				c->pv[k] = d;
				m[0] = mx[0]; m[1] = mx[1] + mx[0] * d; m[2] = mx[2]; m[3] = mx[3] + mx[2] * d;
				break;
			case RK_HALF:
				m[0] = mx[0]; m[1] = mx[1] + mx[0] * 0.5; m[2] = mx[2]; m[3] = mx[3] + mx[2] * 0.5;
				break;
			case RK_SVF: {
				double fc = c->vval[e[3]], q = c->vval[e[4]];
				c->pfc[k] = fc;
				c->pq[k] = q;
				c->pg[k] = c->vval[e[5]];

				// #svf_latency: a lowpass's group delay at DC 1 / (2 g Q), an
				// allpass's twice that, other types none
				double factor = e[6] == SVF_LOWPASS ? 1.0 : (e[6] == SVF_ALLPASS ? 2.0 : 0.0);
				if (factor != 0.0) {
					double rate = c->sc[e[7]];
					double hi = rate * 0.49;
					double g;
					if (c->varr[e[3]]) {
						double f = fc < 1.0 ? 1.0 : (fc > hi ? hi : fc);
						g = tan(f * (M_PI / rate));
					} else {
						double f = fc < 1.0 ? 1.0 : (fc > hi ? hi : fc);
						g = tan(f * M_PI / rate);
					}
					double q2 = q < 1e-10 ? 1e-10 : q;
					d = factor / (g * q2 * 2.0);
					m[0] = mx[0]; m[1] = mx[1] + mx[0] * d; m[2] = mx[2]; m[3] = mx[3] + mx[2] * d;
				} else {
					m[0] = mx[0]; m[1] = mx[1]; m[2] = mx[2]; m[3] = mx[3];
				}
				break;
			}
		}
	}
}

// The loop's response at +w+ apart from the pitch delay (#loop_response);
// false without a path.  With +svf+ false every SVF counts as a wire.
static _Bool pc_response(struct pc_ctx *c, double w, _Bool svf, double *rr, double *ri)
{
	double *ar = c->ar, *ai = c->ai, *br = c->br, *bi = c->bi;
	_Bool *ha = c->ha, *hb = c->hb;

	for (long k = 0; k < c->nr; k++) {
		const int32_t *e = c->rx + k * PC_RWORDS;
		int x = e[1], y = e[2];
		double cr = 1.0, ci = 0.0;

		switch (e[0]) {
			case RK_ONE_A:
				ar[k] = 1.0; ai[k] = 0.0; ha[k] = 1; hb[k] = 0;
				continue;
			case RK_ONE_B:
				br[k] = 1.0; bi[k] = 0.0; hb[k] = 1; ha[k] = 0;
				continue;
			case RK_ADD:
				ha[k] = ha[x] || ha[y];
				hb[k] = hb[x] || hb[y];
				ar[k] = (ha[x] ? ar[x] : 0.0) + (ha[y] ? ar[y] : 0.0);
				ai[k] = (ha[x] ? ai[x] : 0.0) + (ha[y] ? ai[y] : 0.0);
				br[k] = (hb[x] ? br[x] : 0.0) + (hb[y] ? br[y] : 0.0);
				bi[k] = (hb[x] ? bi[x] : 0.0) + (hb[y] ? bi[y] : 0.0);
				continue;
			case RK_SCALE:
				cr = c->pv[k]; ci = 0.0;
				break;
			case RK_COPY:
				cr = 1.0; ci = 0.0;
				break;
			case RK_DELAY: {
				double ph = w * c->pv[k];
				cr = cos(ph); ci = -sin(ph);
				break;
			}
			case RK_HALF:
				cr = cos(w * 0.5); ci = -sin(w * 0.5);
				break;
			case RK_SVF:
				if (svf) {
					pc_svf_point(e[6], c->pfc[k], c->pq[k], c->pg[k], c->sc[e[7]], w, &cr, &ci);
				} else {
					cr = 1.0; ci = 0.0;
				}
				break;
		}

		ha[k] = ha[x]; hb[k] = hb[x];
		double xr = ar[x], xi = ai[x];
		ar[k] = xr * cr - xi * ci; ai[k] = xr * ci + xi * cr;
		xr = br[x]; xi = bi[x];
		br[k] = xr * cr - xi * ci; bi[k] = xr * ci + xi * cr;
	}

	int oa = c->oa, ob = c->ob;
	if (oa < 0 || ob < 0 || !(ha[oa] && hb[ob])) {
		return 0;
	}
	*rr = ar[oa] * br[ob] - ai[oa] * bi[ob];
	*ri = ar[oa] * bi[ob] + ai[oa] * br[ob];
	return 1;
}

static inline void pc_rotate(double *rr, double *ri, double cr, double ci)
{
	double r = *rr * cr - *ri * ci;
	double i = *rr * ci + *ri * cr;
	*rr = r;
	*ri = i;
}

// True when an SVF on the loop could have more gain above the pitch than
// at it (#harmonic_risk?).
static _Bool pc_harmonic_risk(struct pc_ctx *c)
{
	if (c->uneven) {
		return 1;
	}
	for (long k = 0; k < c->nr; k++) {
		const int32_t *e = c->rx + k * PC_RWORDS;
		if (e[0] == RK_SVF && (e[6] != SVF_LOWPASS || c->pq[k] > 0.7072)) {
			return 1;
		}
	}
	return 0;
}

// The sustain shelf at a point (#sustain_point): out = [gain, rest, hr, hi];
// *m0 is the unfiltered loop gain (computed unless *have_m0).
static void pc_sustain_point(struct pc_ctx *c, double w, double t, double rr, double ri, double stretch,
		double *m0, _Bool *have_m0, double *ratio, double out[4])
{
	double m = hypot(rr, ri);
	if (!*have_m0) {
		double r0, i0;
		*m0 = pc_response(c, w, 0, &r0, &i0) ? hypot(r0, i0) : 0.0;
		*have_m0 = 1;
	}
	if (!(*m0 > 1e-12 && m > 0 && isfinite(m))) {
		out[0] = 1.0; out[1] = 0.0; out[2] = 1.0; out[3] = 0.0;
		return;
	}

	double r = pow(*m0, stretch) / m;
	if (r <= 1) {
		if (r < PC_SUSTAIN_MIN) {
			r = PC_SUSTAIN_MIN;
		}
		*ratio = r;
		out[0] = r; out[1] = 0.0; out[2] = r; out[3] = 0.0;
		return;
	}

	if (pc_harmonic_risk(c)) {
		*ratio = 1.0;
		out[0] = 1.0; out[1] = 0.0; out[2] = 1.0; out[3] = 0.0;
		return;
	}

	double lr, li;
	pc_shelf_lp(PC_SUSTAIN_SHELF * c->sus_rate / t, c->sus_rate, w, &lr, &li);
	double xr = 1.0 - lr, xi = -li;
	double qa = xr * xr + xi * xi;
	double qb = 2.0 * (xr * lr + xi * li);
	double qc = lr * lr + li * li - r * r;
	double s = (-qb + sqrt(qb * qb - 4.0 * qa * qc)) / (2.0 * qa);

	if (s > PC_SUSTAIN_MAX) {
		s = PC_SUSTAIN_MAX;
	}
	if (s < 1.0) {
		s = 1.0;
	}

	double hr = s * xr + lr;
	double hi = s * xi + li;
	*ratio = hypot(hr, hi);
	out[0] = s; out[1] = 1.0 - s; out[2] = hr; out[3] = hi;
}

// The loop's response with the shelf (+g1+, +g2+) and the history at +wx+
// (#sustain_stretch's resp); *hr, *hi get the shelf's response there.
static void pc_shelf_response(struct pc_ctx *c, double wx, double fc, double g1, double g2, double *rr, double *ri,
		double *hr, double *hi)
{
	double lr, li;
	pc_response(c, wx, 1, rr, ri);
	pc_shelf_lp(fc, c->sus_rate, wx, &lr, &li);
	*hr = g1 + g2 * lr;
	*hi = g2 * li;
	pc_rotate(rr, ri, *hr, *hi);
	if (c->history) {
		pc_rotate(rr, ri, cos(wx), -sin(wx));
	}
}

// #sustain_stretch: the ratio of the loop's group delay at the pitch to its
// period, limited to 0.5..4.
static double pc_sustain_stretch(struct pc_ctx *c, double w, double t, double g1, double g2,
		double rr, double ri, double hr, double hi, double dcp, _Bool negative)
{
	double fc = PC_SUSTAIN_SHELF * c->sus_rate / t;
	double h = w * 1e-4;
	double ar, ai, br, bi;
	pc_shelf_response(c, w + h, fc, g1, g2, &ar, &ai, &hr, &hi);
	pc_shelf_response(c, w - h, fc, g1, g2, &br, &bi, &hr, &hi);
	double gd = -atan2(ai * br - ar * bi, ar * br + ai * bi) / (2.0 * h);

	// As #sustain_stretch: its resp lambda assigns the method's rr, ri, hr,
	// and hi, so the phase is taken from the response at w - h (shelf and
	// history included) with that point's shelf applied once more
	rr = br;
	ri = bi;
	pc_rotate(&rr, &ri, hr, hi);
	if (c->history) {
		pc_rotate(&rr, &ri, cos(w), -sin(w));
	}
	if (negative) {
		rr = -rr;
		ri = -ri;
	}
	double twopi = 2 * M_PI;
	double arg = atan2(ri, rr);
	double phase = (round((w * dcp + arg) / twopi) * twopi - arg) / w;

	double x = (t - phase + gd) / t;
	return x < 0.5 ? 0.5 : (x > 4.0 ? 4.0 : x);
}

// One point (#pitch_points' block): out = [latency, gain, rest]; updates
// the stretch and the sustain ratio in +st+.
static void pc_point(struct pc_ctx *c, long i, long stream_index, double *st, double out[3])
{
	pc_values(c, i);
	pc_params_moments(c, i);

	double ti = pc_at(&c->src[c->tsrc], i);
	double twopi = 2 * M_PI;
	double w = twopi / ti;

	// The DC estimate (#compute_latency) at the point
	double z[4] = { 0.0, 0.0, 0.0, 0.0 };
	const double *mo = c->oa >= 0 ? c->mo + 4 * c->oa : z;
	const double *mi = c->ob >= 0 ? c->mo + 4 * c->ob : z;
	double dcp = pc_ratio(mo[0], mo[1]) + pc_ratio(mi[2], mi[3]);
	if (c->history) {
		dcp = dcp + 1.0;
	}
	double gain = mo[0] * mi[2];

	out[0] = dcp; out[1] = 1.0; out[2] = 0.0;
	if (c->oa < 0 || c->ob < 0) {
		return;
	}

	double rr, ri;
	if (!pc_response(c, w, 1, &rr, &ri)) {
		return;
	}

	double g1 = 1.0, g2 = 0.0;
	if (c->sustain) {
		double sp[4], m0 = 0.0;
		_Bool have_m0 = 0;
		double stretch = st[8] != 0 ? st[7] : 1.0;
		pc_sustain_point(c, w, ti, rr, ri, stretch, &m0, &have_m0, &st[9], sp);
		g1 = sp[0]; g2 = sp[1];
		if (!(g1 == 1.0 && g2 == 0.0) && (st[8] == 0 || (stream_index / PC_STEP) % PC_STRETCH_EVERY == 0)) {
			st[7] = pc_sustain_stretch(c, w, ti, g1, g2, rr, ri, sp[2], sp[3], dcp, gain < 0);
			st[8] = 1;
			pc_sustain_point(c, w, ti, rr, ri, st[7], &m0, &have_m0, &st[9], sp);
			g1 = sp[0]; g2 = sp[1];
		}
		pc_rotate(&rr, &ri, sp[2], sp[3]);
	}

	if (c->history) {
		pc_rotate(&rr, &ri, cos(w), -sin(w));
	}
	if (gain < 0) {
		rr = -rr;
		ri = -ri;
	}

	double arg = atan2(ri, rr);
	double l = (round((w * dcp + arg) / twopi) * twopi - arg) / w;
	out[0] = fabs(l - dcp) < 1e-9 ? dcp : l;
	out[1] = g1;
	out[2] = g2;
}

static VALUE pc_track(VALUE self, VALUE code, VALUE scalars, VALUE srcs, VALUE count_v, VALUE first_v, VALUE pos_v,
		VALUE state, VALUE outs)
{
	if (CLASS_OF(code) != numo_cInt32 || !nary_check_contiguous(code)) {
		rb_raise(rb_eArgError, "pitch_track code must be a contiguous Int32 NArray");
	}
	if (CLASS_OF(scalars) != numo_cDFloat || !nary_check_contiguous(scalars)) {
		rb_raise(rb_eArgError, "pitch_track scalars must be a contiguous DFloat NArray");
	}
	if (CLASS_OF(state) != numo_cDFloat || !nary_check_contiguous(state) || RNARRAY_SIZE(state) < 10) {
		rb_raise(rb_eArgError, "pitch_track state must be a contiguous DFloat NArray of 10 values");
	}
	Check_Type(srcs, T_ARRAY);
	Check_Type(outs, T_ARRAY);

	long count = NUM2LONG(count_v);
	long first = NUM2LONG(first_v);
	long pos = NUM2LONG(pos_v);
	if (count <= 0 || first < 0 || pos < 0) {
		rb_raise(rb_eArgError, "pitch_track count must be positive, first and pos not negative");
	}

	const int32_t *w32 = (const int32_t *)(nary_get_pointer_for_read(code) + nary_get_offset(code));
	long nwords = RNARRAY_SIZE(code);
	if (nwords < PC_HEADER) {
		rb_raise(rb_eArgError, "pitch_track code too short");
	}

	struct pc_ctx c;
	c.nv = w32[0];
	c.nr = w32[1];
	c.oa = w32[2];
	c.ob = w32[3];
	c.history = (w32[4] & 1) != 0;
	c.sustain = (w32[4] & 2) != 0;
	c.uneven = (w32[4] & 4) != 0;
	long nsrc = w32[5];
	c.tsrc = w32[6];
	long nscalars = RNARRAY_SIZE(scalars);
	c.sc = (const double *)(nary_get_pointer_for_read(scalars) + nary_get_offset(scalars));

	if (c.nv < 0 || c.nr < 0 || nwords != PC_HEADER + c.nv * PC_VWORDS + c.nr * PC_RWORDS) {
		rb_raise(rb_eArgError, "pitch_track code length doesn't match its header");
	}
	if (nsrc != RARRAY_LEN(srcs) || c.tsrc < 0 || c.tsrc >= nsrc || c.oa >= c.nr || c.ob >= c.nr) {
		rb_raise(rb_eArgError, "pitch_track sources don't match the code");
	}
	if (c.sustain && (w32[7] < 0 || w32[7] >= nscalars)) {
		rb_raise(rb_eArgError, "pitch_track sustain rate scalar out of range");
	}
	c.sus_rate = c.sustain ? c.sc[w32[7]] : 0.0;
	c.vx = w32 + PC_HEADER;
	c.rx = c.vx + c.nv * PC_VWORDS;

	// Validate every index once, so the point loops don't
	for (long k = 0; k < c.nv; k++) {
		const int32_t *e = c.vx + k * PC_VWORDS;
		switch (e[0]) {
			case VK_CONST:
				if (e[1] < 0 || e[1] >= nscalars) rb_raise(rb_eArgError, "pitch_track constant out of range");
				break;
			case VK_SRC:
				if (e[1] < 0 || e[1] >= nsrc) rb_raise(rb_eArgError, "pitch_track source out of range");
				break;
			case VK_MUL: case VK_ADD: case VK_DIV: case VK_POW:
				if (e[1] < 0 || e[1] >= k || e[2] < 0 || e[2] >= k) rb_raise(rb_eArgError, "pitch_track value operand out of order");
				break;
			default:
				rb_raise(rb_eArgError, "pitch_track unknown value kind %d", e[0]);
		}
	}
	for (long k = 0; k < c.nr; k++) {
		const int32_t *e = c.rx + k * PC_RWORDS;
		if (e[0] < RK_ONE_A || e[0] > RK_SVF) rb_raise(rb_eArgError, "pitch_track unknown response kind %d", e[0]);
		if (e[0] != RK_ONE_A && e[0] != RK_ONE_B && (e[1] < 0 || e[1] >= k)) rb_raise(rb_eArgError, "pitch_track response operand out of order");
		if (e[0] == RK_ADD && (e[2] < 0 || e[2] >= k)) rb_raise(rb_eArgError, "pitch_track response operand out of order");
		if (e[0] == RK_SCALE && (e[3] < 0 || e[3] >= c.nv)) rb_raise(rb_eArgError, "pitch_track scale value out of range");
		if (e[0] == RK_DELAY && (e[3] < 0 || e[3] >= nsrc)) rb_raise(rb_eArgError, "pitch_track delay source out of range");
		if (e[0] == RK_SVF) {
			for (int j = 3; j <= 5; j++) {
				if (e[j] < 0 || e[j] >= c.nv) rb_raise(rb_eArgError, "pitch_track SVF value out of range");
			}
			if (e[6] < 0 || e[6] > SVF_BANDPASS_SKIRT || e[7] < 0 || e[7] >= nscalars) rb_raise(rb_eArgError, "pitch_track SVF type or rate out of range");
		}
	}
	if (RARRAY_LEN(outs) != 3) {
		rb_raise(rb_eArgError, "pitch_track needs three output NArrays");
	}
	double *o[3];
	for (int k = 0; k < 3; k++) {
		VALUE v = rb_ary_entry(outs, k);
		if (CLASS_OF(v) != numo_cDFloat || !nary_check_contiguous(v) || (long)RNARRAY_SIZE(v) < count) {
			rb_raise(rb_eArgError, "pitch_track outputs must be contiguous DFloat NArrays of at least the block length");
		}
		o[k] = (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
	}

	struct pc_src src[nsrc > 0 ? nsrc : 1];
	for (long k = 0; k < nsrc; k++) {
		pc_get_src(&src[k], rb_ary_entry(srcs, k), count);
	}
	c.src = src;

	long nv1 = c.nv > 0 ? c.nv : 1, nr1 = c.nr > 0 ? c.nr : 1;
	double vval[nv1];
	_Bool varr[nv1];
	double pv[nr1], pfc[nr1], pq[nr1], pg[nr1], ar[nr1], ai[nr1], br[nr1], bi[nr1], mo[4 * nr1];
	_Bool ha[nr1], hb[nr1];
	memset(ar, 0, sizeof(ar)); memset(ai, 0, sizeof(ai)); memset(br, 0, sizeof(br)); memset(bi, 0, sizeof(bi));
	memset(ha, 0, sizeof(ha)); memset(hb, 0, sizeof(hb)); memset(pv, 0, sizeof(pv));
	memset(pfc, 0, sizeof(pfc)); memset(pq, 0, sizeof(pq)); memset(pg, 0, sizeof(pg)); memset(mo, 0, sizeof(mo));
	c.vval = vval; c.varr = varr; c.pv = pv; c.pfc = pfc; c.pq = pq; c.pg = pg;
	c.ar = ar; c.ai = ai; c.br = br; c.bi = bi; c.ha = ha; c.hb = hb; c.mo = mo;

	double *st = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));

	long m = first < count ? (count - 1 - first) / PC_STEP + 1 : 0;
	double *lpd = ALLOCA_N(double, 3 * (m > 0 ? m : 1));
#define LP(p, k) lpd[3 * (p) + (k)]
	for (long p = 0; p < m; p++) {
		long i = first + p * PC_STEP;
		pc_point(&c, i, pos + i, st, &LP(p, 0));
	}

	if (m > 0 && st[6] == 0) {
		memcpy(st, &LP(0, 0), sizeof(double) * 3);
		memcpy(st + 3, &LP(0, 0), sizeof(double) * 3);
		st[6] = 1;
	}
	if (st[6] == 0) {
		rb_raise(rb_eRuntimeError, "pitch_track has no values yet");
	}

	double a[3] = { st[0], st[1], st[2] };
	double b[3] = { st[3], st[4], st[5] };
	_Bool all = a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
	for (long p = 0; all && p < m; p++) {
		all = LP(p, 0) == b[0] && LP(p, 1) == b[1] && LP(p, 2) == b[2];
	}
	if (all) {
		RB_GC_GUARD(srcs);
		return Qfalse;
	}

	// Sample i is in segment j (0 before the block's first point), ramping
	// from chain[j] to chain[j + 1], chain = [a, b, points...]
	for (int k = 0; k < 3; k++) {
		for (long i = 0; i < count; i++) {
			long j = i < first ? 0 : (i - first) / PC_STEP + 1;
			double frac = (double)((i + pos) % PC_STEP) / PC_STEP;
			double ca = j == 0 ? a[k] : (j == 1 ? b[k] : LP(j - 2, k));
			double cb = j == 0 ? b[k] : LP(j - 1, k);
			o[k][i] = frac * (cb - ca) + ca;
		}
	}
	if (m > 0) {
		for (int k = 0; k < 3; k++) {
			st[k] = m == 1 ? b[k] : LP(m - 2, k);
			st[3 + k] = LP(m - 1, k);
		}
	}

#undef LP
	RB_GC_GUARD(srcs);
	RB_GC_GUARD(outs);
	return Qtrue;
}

void mb_loop_pitch_init(VALUE fast_loop)
{
	rb_define_module_function(fast_loop, "pitch_track", pc_track, 8);
}
