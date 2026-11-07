/*
 * MB::Sound::FastClip: waveshapers (soft clip, hard clip, absolute value,
 * quantize) with antiderivative antialiasing (ADAA).
 *
 * A nonlinearity f creates harmonics above Nyquist that fold back down.
 * First-order ADAA replaces f(x[n]) with the average of f between the last
 * two inputs, (F(x[n]) - F(x[n-1])) / (x[n] - x[n-1]) where F is the
 * antiderivative of f: a one-sample boxcar applied before sampling, which
 * suppresses the aliases (most of all those below the fundamental) at about
 * the cost of the plain shaper, with half a sample of delay.
 *
 * Plain ADAA also averages the unclipped signal (-6 dB at 16 kHz), so each
 * shaper is split into x + g(x), where g = f - x is zero wherever the shaper
 * is linear: ADAA is applied to g only (antiderivative G = F - x^2/2), and x
 * goes through a first-order Thiran allpass with half a sample of delay, so
 * the dry signal stays flat in level and lines up with the ADAA path.
 *
 * Without antialiasing (+antialias+ false) the plain shaper is applied.  The
 * Ruby mirror is MB::Sound::Shaper (lib/mb/sound/shaper.rb); specs check that
 * both give the same samples.
 *
 * FastClip.shape_curve is the same ADAA for a tweening curve used as a
 * shaper (GraphNode::CurveShaper): the curve with its out-of-range mode
 * (clamp, extend, wrap, mirror, none, optionally odd-symmetric), integrated
 * in closed form (polynomial, cosine, exponential) or from a table of the
 * antiderivative with cubic Hermite interpolation.  Its Ruby mirror is
 * GraphNode::CurveShaper.shape_ruby.
 *
 * Its dB form (GraphNode::DbShaper, after Sonic Foundry's DirectX
 * Distortion) is a transfer curve on a dB-in / dB-out scale applied per
 * sample with the sign kept.  A straight line in dB is a power law in
 * linear terms (y dB = y0 + p (x dB - x0) is f(u) = f0 (u / u0)^p), so a
 * curve of dB-linear segments integrates in closed form: no table, exact
 * from the quietest input to inputs over full scale.  FastClip.shape_db is
 * its exact (plain) version, evaluating the dB curve itself.
 */

#include <stdlib.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_clip_shape.h"
#include "mb_curve_lookup.h"
#include "mb_dynamics.h"

static ID sym_softclip, sym_clip, sym_abs, sym_quantize;

/*
 * Applies a shaper to +buffer+ (SFloat, modified in place if marked
 * inplace):
 *   shape(buffer, mode, p1, p2, antialias, state)
 * +mode+ is :softclip (p1 threshold, p2 limit), :clip (p1 min, p2 max;
 * infinite for none), :abs, or :quantize (p1 step).  +state+ is [last
 * input, allpass last input, allpass last output, primed (0 or 1)].  The
 * shaper itself is in mb_clip_shape.h.
 */
static VALUE ruby_shape(VALUE self, VALUE buffer, VALUE mode, VALUE p1v, VALUE p2v, VALUE antialias, VALUE state)
{
	struct clip_params cp;
	enum clip_mode m;

	ID id = SYM2ID(mode);
	if (id == sym_softclip) {
		m = CLIP_SOFT;
	} else if (id == sym_clip) {
		m = CLIP_HARD;
	} else if (id == sym_abs) {
		m = CLIP_ABS;
	} else if (id == sym_quantize) {
		m = CLIP_QUANTIZE;
	} else {
		rb_raise(rb_eArgError, "Unknown shaper %"PRIsVALUE, mode);
	}

	const char *err = mb_clip_setup(&cp, m, NUM2DBL(p1v), NUM2DBL(p2v));
	if (err) {
		rb_raise(rb_eArgError, "%s", err);
	}

	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) {
		rb_raise(rb_eArgError, "Shaper state must have four elements");
	}
	double x1 = NUM2DBL(rb_ary_entry(state, 0));
	double ap_x1 = NUM2DBL(rb_ary_entry(state, 1));
	double ap_y1 = NUM2DBL(rb_ary_entry(state, 2));
	_Bool primed = NUM2INT(rb_ary_entry(state, 3)) != 0;
	_Bool aa = RTEST(antialias);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	mb_clip_run(&cp, data, data, length, aa, &x1, &ap_x1, &ap_y1, &primed);

	if (aa && length > 0) {
		rb_ary_store(state, 0, rb_float_new(x1));
		rb_ary_store(state, 1, rb_float_new(ap_x1));
		rb_ary_store(state, 2, rb_float_new(ap_y1));
		rb_ary_store(state, 3, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);

	return buffer;
}

// Curve sources for shape_curve (CurveShaper::FORMS)
enum curve_form {
	CURVE_TABLE = 0,
	CURVE_POLY = 1,
	CURVE_COS = 2,
	CURVE_EXP = 3,
	CURVE_DB = 4,
};

// The dB form's coefficients (CURVE_DB): a header of [mix, positive rows,
// negative rows (0: mirrored)], then rows of [u0, f0, p, c0]: from input
// magnitude u0 up to the next row's, f(u) = f0 (u / u0)^p and its integral
// from 0 is c0 + f0 u0 ((u / u0)^(p + 1) - 1) / (p + 1).  The first row
// (below the first point) starts at the same u0 as the second and is used
// below it.
#define DB_HEADER 3
#define DB_ROW 4

// Exponents p this close to -1 integrate as a logarithm.
#define DB_LOG_Q 1e-9

// Edge modes for shape_curve (CurveShaper::EDGES)
enum curve_edges {
	EDGE_CLAMP = 0,
	EDGE_EXTEND = 1,
	EDGE_WRAP = 2,
	EDGE_MIRROR = 3,
	EDGE_NONE = 4,
};

#define CURVE_MAX_COEFFS 16

// Positions this close after a table node (in cells) take the node's value.
struct curve_params {
	enum curve_form form;
	enum curve_edges edges;
	_Bool natural;          // the form holds outside 0..1 (extend uses it)
	int ncoeff;
	double coeff[CURVE_MAX_COEFFS]; // poly: a0..an; cos: a, b, w, phase; exp: c, inv
	size_t cells;
	const double *ti, *tfl, *tfr; // table: integral, left and right limits of f at nodes
	double f0, f1, s0, s1, i1;
	const double *db;       // dB form: the positive rows, then the negative ones
	long db_npos, db_nneg;
	double db_mix;
};

// The dB form's row for input magnitude +u+ (the last whose u0 <= u, the
// first below every u0).
static const double *db_row(const double *rows, long n, double u)
{
	long lo = 0;
	long hi = n - 1;
	while (lo < hi) {
		long mid = (lo + hi + 1) / 2;
		if (rows[mid * DB_ROW] <= u) {
			lo = mid;
		} else {
			hi = mid - 1;
		}
	}
	return rows + lo * DB_ROW;
}

// The dB form's half curve (rows +rows+, +n+ of them) at magnitude +u+.
static double db_half_f(const double *rows, long n, double u)
{
	if (!(u > 0)) {
		return 0;
	}
	const double *r = db_row(rows, n, u);
	return r[1] * pow(u / r[0], r[2]);
}

// The integral of db_half_f from 0 to +u+.
static double db_half_integral(const double *rows, long n, double u)
{
	if (!(u > 0)) {
		return 0;
	}
	const double *r = db_row(rows, n, u);
	double q = r[2] + 1.0;
	double v = u / r[0];
	if (fabs(q) < DB_LOG_Q) {
		return r[3] + r[1] * r[0] * log(v);
	}
	return r[3] + r[1] * r[0] * (pow(v, q) - 1.0) / q;
}

// The dB form at signed input +x+ (odd for mirrored curves), mixed with x.
static double db_f(const struct curve_params *p, double x)
{
	_Bool neg = x < 0 && p->db_nneg > 0;
	const double *rows = neg ? p->db + p->db_npos * DB_ROW : p->db;
	double f = db_half_f(rows, neg ? p->db_nneg : p->db_npos, fabs(x));
	if (x < 0) {
		f = -f;
	}
	return p->db_mix == 1.0 ? f : x + p->db_mix * (f - x);
}

// The integral of db_f from 0 to +x+ (even: the integral of an odd-signed
// half from 0 to |x|).
static double db_integral(const struct curve_params *p, double x)
{
	_Bool neg = x < 0 && p->db_nneg > 0;
	const double *rows = neg ? p->db + p->db_npos * DB_ROW : p->db;
	double big_f = db_half_integral(rows, neg ? p->db_nneg : p->db_npos, fabs(x));
	if (p->db_mix == 1.0) {
		return big_f;
	}
	double half = 0.5 * x * x;
	return half + p->db_mix * (big_f - half);
}

// The base curve on 0..1 (anywhere for natural forms).  Tables use the
// derivative of their Hermite interpolant, consistent with curve_integral.
static double curve_f(const struct curve_params *p, double x)
{
	switch (p->form) {
		case CURVE_POLY: {
			double v = 0;
			for (int k = p->ncoeff - 1; k >= 0; k--) {
				v = v * x + p->coeff[k];
			}
			return v;
		}

		case CURVE_COS:
			return p->coeff[0] + p->coeff[1] * cos(p->coeff[2] * x + p->coeff[3]);

		case CURVE_EXP:
			return (1.0 - exp(p->coeff[0] * x)) * p->coeff[1];

		case CURVE_DB:
			return db_f(p, x);

		case CURVE_TABLE: {
			double pos = x * (double)p->cells;
			if (pos < 0) pos = 0;
			if (pos > (double)p->cells) pos = (double)p->cells;
			size_t j = (size_t)pos;
			if (j >= p->cells) j = p->cells - 1;
			double t = pos - (double)j;
			double h = 1.0 / (double)p->cells;
			double d00 = 6.0 * t * t - 6.0 * t;
			double d10 = 3.0 * t * t - 4.0 * t + 1.0;
			double d11 = 3.0 * t * t - 2.0 * t;
			return (d00 * (p->ti[j] - p->ti[j + 1])) / h + d10 * p->tfr[j] + d11 * p->tfl[j + 1];
		}
	}

	return x;
}

// The integral of the base curve from 0 to x (on 0..1; anywhere for
// natural forms).
static double curve_integral(const struct curve_params *p, double x)
{
	switch (p->form) {
		case CURVE_POLY: {
			double v = 0;
			for (int k = p->ncoeff - 1; k >= 0; k--) {
				v = v * x + p->coeff[k] / (double)(k + 1);
			}
			return v * x;
		}

		case CURVE_COS: {
			double a = p->coeff[0], b = p->coeff[1], w = p->coeff[2], ph = p->coeff[3];
			return a * x + (b / w) * (sin(w * x + ph) - sin(ph));
		}

		case CURVE_EXP:
			return (x - (exp(p->coeff[0] * x) - 1.0) / p->coeff[0]) * p->coeff[1];

		case CURVE_DB:
			return db_integral(p, x);

		case CURVE_TABLE: {
			double pos = x * (double)p->cells;
			if (pos < 0) pos = 0;
			if (pos > (double)p->cells) pos = (double)p->cells;
			size_t j = (size_t)pos;
			if (j >= p->cells) j = p->cells - 1;
			double t = pos - (double)j;
			double h = 1.0 / (double)p->cells;
			double t2 = t * t, t3 = t2 * t;
			double h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
			double h10 = t3 - 2.0 * t2 + t;
			double h01 = -2.0 * t3 + 3.0 * t2;
			double h11 = t3 - t2;
			return h00 * p->ti[j] + h10 * h * p->tfr[j] + h01 * p->ti[j + 1] + h11 * h * p->tfl[j + 1];
		}
	}

	return 0;
}

// The curve with its edge mode, at u.
static double curve_edge_f(const struct curve_params *p, double u)
{
	switch (p->edges) {
		case EDGE_CLAMP:
			return u < 0 ? p->f0 : (u > 1 ? p->f1 : curve_f(p, u));

		case EDGE_EXTEND:
			if (p->natural) {
				return curve_f(p, u);
			}
			return u < 0 ? p->f0 + p->s0 * u : (u > 1 ? p->f1 + p->s1 * (u - 1.0) : curve_f(p, u));

		case EDGE_WRAP:
			return curve_f(p, u - floor(u));

		case EDGE_MIRROR: {
			double r = u - 2.0 * floor(u * 0.5);
			return curve_f(p, r <= 1.0 ? r : 2.0 - r);
		}

		case EDGE_NONE:
			return curve_f(p, u);
	}

	return u;
}

// The integral of curve_edge_f from 0 to u.
static double curve_edge_integral(const struct curve_params *p, double u)
{
	switch (p->edges) {
		case EDGE_CLAMP:
			if (u < 0) return p->f0 * u;
			if (u > 1) return p->i1 + p->f1 * (u - 1.0);
			return curve_integral(p, u);

		case EDGE_EXTEND:
			if (p->natural) {
				return curve_integral(p, u);
			}
			if (u < 0) return p->f0 * u + 0.5 * p->s0 * u * u;
			if (u > 1) {
				double d = u - 1.0;
				return p->i1 + p->f1 * d + 0.5 * p->s1 * d * d;
			}
			return curve_integral(p, u);

		case EDGE_WRAP: {
			double n = floor(u);
			return n * p->i1 + curve_integral(p, u - n);
		}

		case EDGE_MIRROR: {
			double n = floor(u * 0.5);
			double r = u - 2.0 * n;
			double part = r <= 1.0 ? curve_integral(p, r) : 2.0 * p->i1 - curve_integral(p, 2.0 - r);
			return 2.0 * n * p->i1 + part;
		}

		case EDGE_NONE:
			return curve_integral(p, u);
	}

	return 0;
}

// Reads a contiguous DFloat's data, or NULL for nil.
static const double *curve_dfloat_ptr(VALUE v, size_t min_length, const char *name)
{
	if (NIL_P(v)) {
		return NULL;
	}
	if (CLASS_OF(v) != numo_cDFloat || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "The curve %s must be a contiguous Numo::DFloat", name);
	}
	if (RNARRAY_SIZE(v) < min_length) {
		rb_raise(rb_eArgError, "The curve %s is too short", name);
	}
	return (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

/*
 * Applies a tweening curve as an antialiased shaper to +buffer+ (SFloat,
 * modified in place if marked inplace):
 *   shape_curve(buffer, form, coeffs, table_i, table_fl, table_fr, map, edges, symmetric, state)
 * +form+ is 0 (table), 1 (polynomial coefficients from x^0), 2 (cosine: a,
 * b, w, phase for a + b cos(w x + phase)), or 3 (exponential: c, 1 / (1 -
 * e^c)), or 4 (dB: piecewise power laws, see CURVE_DB; always natural, on
 * the signed input, for edges 4 (none) with the identity map).  Tables
 * (DFloat, cells + 1 values each) hold the integral from 0
 * and the left and right limits of the curve at each node.  +map+ is a
 * DFloat [in_lo, in_scale, out_lo, out_scale, f(0), f(1), slope at 0, slope
 * at 1, integral to 1, natural (0 or 1)].  +edges+ is 0 (clamp), 1
 * (extend), 2 (wrap), 3 (mirror), or 4 (none).  With +symmetric+ the curve
 * shapes |x| and the sign is restored (odd).  +state+ is [last normalized
 * input, allpass last input, allpass last output, primed (0 or 1)].
 */
static VALUE ruby_shape_curve(VALUE self, VALUE buffer, VALUE form, VALUE coeffs, VALUE table_i, VALUE table_fl, VALUE table_fr,
		VALUE map, VALUE edges, VALUE symmetric, VALUE state)
{
	struct curve_params p = { 0 };
	// Checked as ints (clang warns about comparing unsigned enums with 0)
	int form_int = NUM2INT(form);
	int edges_int = NUM2INT(edges);
	if (form_int < CURVE_TABLE || form_int > CURVE_DB) {
		rb_raise(rb_eArgError, "Unknown curve form %d", form_int);
	}
	if (edges_int < EDGE_CLAMP || edges_int > EDGE_NONE) {
		rb_raise(rb_eArgError, "Unknown curve edge mode %d", edges_int);
	}
	p.form = (enum curve_form)form_int;
	p.edges = (enum curve_edges)edges_int;

	const double *m = curve_dfloat_ptr(map, 10, "map");
	double in_lo = m[0], in_scale = m[1], out_lo = m[2], out_scale = m[3];
	p.f0 = m[4];
	p.f1 = m[5];
	p.s0 = m[6];
	p.s1 = m[7];
	p.i1 = m[8];
	p.natural = m[9] != 0;

	if (p.form == CURVE_TABLE) {
		if (NIL_P(table_i)) {
			rb_raise(rb_eArgError, "A curve table is required for form 0");
		}
		size_t length = RNARRAY_SIZE(table_i);
		if (length < 2) {
			rb_raise(rb_eArgError, "A curve table needs at least two values");
		}
		p.cells = length - 1;
		p.ti = curve_dfloat_ptr(table_i, length, "integral table");
		p.tfl = curve_dfloat_ptr(table_fl, length, "left table");
		p.tfr = curve_dfloat_ptr(table_fr, length, "right table");
		if (p.edges == EDGE_NONE) {
			rb_raise(rb_eArgError, "Curve tables cover only 0..1; edges :none needs a closed form");
		}
		p.natural = 0;
	} else if (p.form == CURVE_DB) {
		const double *c = curve_dfloat_ptr(coeffs, DB_HEADER, "coefficients");
		size_t n = RNARRAY_SIZE(coeffs);
		double npos = c[1], nneg = c[2];
		if (!(npos >= 1 && nneg >= 0 && npos == floor(npos) && nneg == floor(nneg)) ||
				(double)n != DB_HEADER + DB_ROW * (npos + nneg)) {
			rb_raise(rb_eArgError, "dB curve coefficients need [mix, rows, rows] and four values per row");
		}
		p.db_mix = c[0];
		p.db_npos = (long)npos;
		p.db_nneg = (long)nneg;
		p.db = c + DB_HEADER;
		p.natural = 1;
	} else {
		const double *c = curve_dfloat_ptr(coeffs, 1, "coefficients");
		size_t n = RNARRAY_SIZE(coeffs);
		if (n > CURVE_MAX_COEFFS || (p.form == CURVE_COS && n != 4) || (p.form == CURVE_EXP && n != 2)) {
			rb_raise(rb_eArgError, "Wrong number of curve coefficients (%zu)", n);
		}
		p.ncoeff = (int)n;
		for (size_t k = 0; k < n; k++) {
			p.coeff[k] = c[k];
		}
	}

	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) {
		rb_raise(rb_eArgError, "Shaper state must have four elements");
	}
	double x1 = NUM2DBL(rb_ary_entry(state, 0));
	double ap_x1 = NUM2DBL(rb_ary_entry(state, 1));
	double ap_y1 = NUM2DBL(rb_ary_entry(state, 2));
	_Bool primed = NUM2INT(rb_ary_entry(state, 3)) != 0;
	_Bool sym = RTEST(symmetric);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	for (size_t i = 0; i < length; i++) {
		double x = ((double)data[i] - in_lo) * in_scale;

		if (!primed) {
			x1 = x;
			ap_x1 = x;
			ap_y1 = x;
			primed = 1;
		}

		double d = x - x1;
		double g;
		if (fabs(d) < CLIP_TINY) {
			double mid = 0.5 * (x + x1);
			double e;
			if (sym) {
				e = curve_edge_f(&p, fabs(mid));
				e = mid < 0 ? -e : e;
			} else {
				e = curve_edge_f(&p, mid);
			}
			g = e - mid;
		} else {
			double fa = sym ? curve_edge_integral(&p, fabs(x)) : curve_edge_integral(&p, x);
			double fb = sym ? curve_edge_integral(&p, fabs(x1)) : curve_edge_integral(&p, x1);
			g = (fa - fb) / d - 0.5 * (x + x1);
		}

		double dry = CLIP_ALLPASS * x + ap_x1 - CLIP_ALLPASS * ap_y1;
		ap_x1 = x;
		ap_y1 = dry;
		x1 = x;

		data[i] = out_lo + out_scale * (dry + g);
	}

	if (length > 0) {
		rb_ary_store(state, 0, rb_float_new(x1));
		rb_ary_store(state, 1, rb_float_new(ap_x1));
		rb_ary_store(state, 2, rb_float_new(ap_y1));
		rb_ary_store(state, 3, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);
	RB_GC_GUARD(coeffs);
	RB_GC_GUARD(table_i);
	RB_GC_GUARD(table_fl);
	RB_GC_GUARD(table_fr);
	RB_GC_GUARD(map);

	return buffer;
}

/*
 * Evaluates a tweening curve from its value table, in place on +t+ (a
 * contiguous DFloat of positions, clamped to 0..1):
 *   curve_lookup(t, f_left, f_right, d_left, d_right)
 * The tables (DFloat, cells + 1 values) hold the curve's left and right
 * limits and slopes at each node (they differ only at jumps and kinks).
 * The curve is evaluated as in mb_curve_lookup.h (cubic Hermites between
 * nodes, the left value exactly on a node).  Used by glides (Notes::Glide
 * with a shape); Curve.lookup_ruby is the exact Ruby mirror.
 */
static VALUE ruby_curve_lookup(VALUE self, VALUE t, VALUE f_left, VALUE f_right, VALUE d_left, VALUE d_right)
{
	if (CLASS_OF(t) != numo_cDFloat || !RTEST(nary_check_contiguous(t))) {
		rb_raise(rb_eArgError, "Curve positions must be a contiguous Numo::DFloat");
	}
	if (NIL_P(f_left)) {
		rb_raise(rb_eArgError, "A curve table is required");
	}
	size_t nodes = RNARRAY_SIZE(f_left);
	if (nodes < 2) {
		rb_raise(rb_eArgError, "A curve table needs at least two values");
	}
	struct mb_curve_table table = {
		.fl = curve_dfloat_ptr(f_left, nodes, "left values"),
		.fr = curve_dfloat_ptr(f_right, nodes, "right values"),
		.dl = curve_dfloat_ptr(d_left, nodes, "left slopes"),
		.dr = curve_dfloat_ptr(d_right, nodes, "right slopes"),
		.cells = nodes - 1,
	};

	size_t length = RNARRAY_SIZE(t);
	double *x = (double *)(nary_get_pointer_for_write(t) + nary_get_offset(t));

	for (size_t i = 0; i < length; i++) {
		x[i] = mb_curve_lookup(&table, x[i]);
	}

	RB_GC_GUARD(t);
	RB_GC_GUARD(f_left);
	RB_GC_GUARD(f_right);
	RB_GC_GUARD(d_left);
	RB_GC_GUARD(d_right);

	return t;
}

// Reads a transfer curve's segment table (a contiguous DFloat of [x0, y0,
// b, c, d] rows), or NULL for nil.
static const double *db_segments(VALUE v, long *count, const char *name)
{
	if (NIL_P(v)) {
		*count = 0;
		return NULL;
	}
	const double *seg = curve_dfloat_ptr(v, 5, name);
	size_t n = RNARRAY_SIZE(v);
	if (n % 5 != 0) {
		rb_raise(rb_eArgError, "The %s needs five values per segment", name);
	}
	*count = (long)(n / 5);
	return seg;
}

/*
 * The exact (plain) dB shaper (GraphNode::DbShaper with antialias off), in
 * place on +buffer+ (SFloat, modified in place if marked inplace):
 *   shape_db(buffer, positive, negative, mix, floor_positive, floor_negative)
 * Each sample x becomes sign(x) 10^(T(20 log10 |x|) / 20), where T is the
 * transfer curve +positive+ (a Dynamics::Transfer#table: [x0, y0, b, c,
 * d] rows evaluated as mb_dyn_curve does) or, for negative x, +negative+
 * (nil: +positive+, mirrored).  Inputs below a half's floor (dB; -Infinity
 * for none) and zeros give 0.  +mix+ blends with the input: x + mix (y - x)
 * (y itself for 1).  The Ruby mirror is GraphNode::DbShaper.plain_ruby.
 */
static VALUE ruby_shape_db(VALUE self, VALUE buffer, VALUE positive, VALUE negative, VALUE mix, VALUE floor_positive, VALUE floor_negative)
{
	MB_DYN_NO_CONTRACT
	long npos, nneg;
	const double *pos = db_segments(positive, &npos, "positive curve");
	const double *neg = db_segments(negative, &nneg, "negative curve");
	if (pos == NULL) {
		rb_raise(rb_eArgError, "The dB shaper needs a positive curve");
	}
	if (neg == NULL) {
		neg = pos;
		nneg = npos;
	}
	double m = NUM2DBL(mix);
	double fl_pos = NUM2DBL(floor_positive);
	double fl_neg = NUM2DBL(floor_negative);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	for (size_t i = 0; i < length; i++) {
		double x = (double)data[i];
		double y = 0;
		if (x != 0) {
			_Bool is_neg = x < 0;
			double l = 20.0 * log10(fabs(x));
			if (!(l < (is_neg ? fl_neg : fl_pos))) {
				y = pow(10.0, mb_dyn_curve(is_neg ? neg : pos, is_neg ? nneg : npos, l) / 20.0);
				if (is_neg) {
					y = -y;
				}
			}
		}
		data[i] = (float)(m == 1.0 ? y : x + m * (y - x));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);
	RB_GC_GUARD(positive);
	RB_GC_GUARD(negative);

	return buffer;
}

void Init_fast_clip(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_clip = rb_define_module_under(sound, "FastClip");

	sym_softclip = rb_intern("softclip");
	sym_clip = rb_intern("clip");
	sym_abs = rb_intern("abs");
	sym_quantize = rb_intern("quantize");

	rb_define_module_function(fast_clip, "shape", ruby_shape, 6);
	rb_define_module_function(fast_clip, "shape_curve", ruby_shape_curve, 10);
	rb_define_module_function(fast_clip, "curve_lookup", ruby_curve_lookup, 5);
	rb_define_module_function(fast_clip, "shape_db", ruby_shape_db, 6);
}
