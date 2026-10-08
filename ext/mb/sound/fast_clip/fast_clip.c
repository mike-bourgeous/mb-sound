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
 */

#include <stdlib.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_clip_shape.h"

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
};

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
#define CURVE_NODE_SNAP 1e-6

struct curve_params {
	enum curve_form form;
	enum curve_edges edges;
	_Bool natural;          // the form holds outside 0..1 (extend uses it)
	int ncoeff;
	double coeff[CURVE_MAX_COEFFS]; // poly: a0..an; cos: a, b, w, phase; exp: c, inv
	size_t cells;
	const double *ti, *tfl, *tfr; // table: integral, left and right limits of f at nodes
	double f0, f1, s0, s1, i1;
};

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
 * e^c)).  Tables (DFloat, cells + 1 values each) hold the integral from 0
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
	if (form_int < CURVE_TABLE || form_int > CURVE_EXP) {
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
 * Between nodes the curve is a cubic Hermite from the right values of one
 * node to the left values of the next; exactly on a node it is the left
 * value (so staircases jump just after each node, like Curve.steps; within
 * CURVE_NODE_SNAP of a cell after it, as Curve.steps snaps rounding).  Used
 * by glides (Notes::Glide with a shape); Curve.lookup_ruby is the exact
 * Ruby mirror.
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
	const double *fl = curve_dfloat_ptr(f_left, nodes, "left values");
	const double *fr = curve_dfloat_ptr(f_right, nodes, "right values");
	const double *dl = curve_dfloat_ptr(d_left, nodes, "left slopes");
	const double *dr = curve_dfloat_ptr(d_right, nodes, "right slopes");
	size_t cells = nodes - 1;
	double h = 1.0 / (double)cells;

	size_t length = RNARRAY_SIZE(t);
	double *x = (double *)(nary_get_pointer_for_write(t) + nary_get_offset(t));

	for (size_t i = 0; i < length; i++) {
		double pos = x[i] * (double)cells;
		if (!(pos > 0)) pos = 0; // also NaN
		if (pos > (double)cells) pos = (double)cells;
		size_t j = (size_t)pos;
		double u = pos - (double)j;
		if (u < CURVE_NODE_SNAP) {
			x[i] = fl[j];
			continue;
		}
		double u2 = u * u, u3 = u2 * u;
		double h00 = 2.0 * u3 - 3.0 * u2 + 1.0;
		double h10 = u3 - 2.0 * u2 + u;
		double h01 = -2.0 * u3 + 3.0 * u2;
		double h11 = u3 - u2;
		x[i] = h00 * fr[j] + h10 * h * dr[j] + h01 * fl[j + 1] + h11 * h * dl[j + 1];
	}

	RB_GC_GUARD(t);
	RB_GC_GUARD(f_left);
	RB_GC_GUARD(f_right);
	RB_GC_GUARD(d_left);
	RB_GC_GUARD(d_right);

	return t;
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
}
