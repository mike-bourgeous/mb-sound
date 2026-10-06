/*
 * MB::Sound::FastArithmetic: allocation-free products and sums of full
 * buffers for GraphNode::Multiplier and GraphNode::Mixer.
 *
 * Every Numo operation allocates a few Ruby objects (ndloop's Arrays, plus a
 * view for .inplace and a cast copy when a real input meets a complex
 * buffer), which at 128-sample buffers made the arithmetic nodes the largest
 * source of garbage.  These kernels do the same arithmetic in one call
 * without allocating.
 *
 * The Ruby mirror is the Numo code of the Multiplier and Mixer fast paths
 * (their fallback when a kernel returns nil), and specs compare both for
 * exactly equal values, so the operations are Numo's, in Numo's order:
 * the output is filled with the constant (cast to the buffer type), then
 * each input is multiplied in (Multiplier) or added (Mixer; an input whose
 * gain isn't == 1 is first multiplied by the gain cast to the buffer type).
 * Real inputs to complex buffers are promoted to (x, 0) and go through the
 * full complex product, as Numo's cast does.  Complex products are written
 * out (not C99's complex *, which adds Annex G infinity handling), and the
 * extension is built with -ffp-contract=off so nothing is fused.
 *
 * Numo itself may be built with FMA contraction (clang's default on arm64
 * Macs fuses a * b - c * d), which no flag here can match, so the kernels
 * only compute complex products in which one factor has an imaginary part
 * of exactly zero: a real input promoted to (x, 0), a real gain, or a
 * running product that is still real (a real constant times real inputs,
 * whose imaginary part stays +-0).  Then one term of each part is y * 0, an
 * exact zero, and fused and unfused evaluation give the same value
 * (re = a*x - b*0 is a*x either way).  Products of two truly complex
 * factors (a complex input after a complex constant or another complex
 * input, or a complex input times a complex gain) return nil for Numo.  The
 * only difference left possible under contraction is the sign of a zero
 * from a product that underflows (below ~1e-45 in float).
 *
 * .copy copies a buffer into another (for nodes that work in place on a
 * copy of a frozen input), and .min_max finds Numo's min and max of a real
 * buffer at once (for Synth's lane levels).  .divide and .power are the
 * in-place / and ** of GraphNode arithmetic procs for real buffers, and
 * .circular_read/.circular_write are MB::M's ring buffer copies (delay
 * lines, CircularBuffer) without the Ranges and views; .wet_dry is
 * Filter::Delay's output mix.
 *
 * Buffer types: SFloat (SFloat inputs), DFloat (DFloat), SComplex (SComplex
 * or SFloat), DComplex (DComplex or DFloat), every input exactly as long as
 * the output and contiguous, and the output writable.  Anything else returns
 * nil without touching the output, and the caller falls back to Numo.
 */

#include <string.h>
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

enum mb_arith_type { MB_ARITH_NONE, MB_ARITH_SF, MB_ARITH_DF, MB_ARITH_SC, MB_ARITH_DC };

typedef struct { float r, i; } mb_sc;
typedef struct { double r, i; } mb_dc;

static size_t elem_size(enum mb_arith_type t);

static enum mb_arith_type arith_type(VALUE v)
{
	VALUE c = CLASS_OF(v);
	if (c == numo_cSFloat) return MB_ARITH_SF;
	if (c == numo_cDFloat) return MB_ARITH_DF;
	if (c == numo_cSComplex) return MB_ARITH_SC;
	if (c == numo_cDComplex) return MB_ARITH_DC;
	return MB_ARITH_NONE;
}

// True if +in+ can be read directly as an input to a buffer of type +out+.
static _Bool input_type_ok(enum mb_arith_type out, enum mb_arith_type in)
{
	switch (out) {
		case MB_ARITH_SF: return in == MB_ARITH_SF;
		case MB_ARITH_DF: return in == MB_ARITH_DF;
		case MB_ARITH_SC: return in == MB_ARITH_SC || in == MB_ARITH_SF;
		case MB_ARITH_DC: return in == MB_ARITH_DC || in == MB_ARITH_DF;
		default: return 0;
	}
}

// True if +v+ is a contiguous 1D NArray of +length+ values.
static _Bool shape_ok(VALUE v, size_t length)
{
	return RNARRAY_NDIM(v) == 1 && RNARRAY_SIZE(v) == length && RTEST(nary_check_contiguous(v));
}

static const char *read_ptr(VALUE v)
{
	return nary_get_pointer_for_read(v) + nary_get_offset(v);
}

// Reads a Ruby Numeric (possibly Complex) as Numo's fill would see it.
static void num_parts(VALUE n, double *r, double *i)
{
	if (RB_TYPE_P(n, T_COMPLEX)) {
		*r = NUM2DBL(rb_complex_real(n));
		*i = NUM2DBL(rb_complex_imag(n));
	} else {
		*r = NUM2DBL(n);
		*i = 0;
	}
}

// Checks the output and every [buffer, extra] pair of +sampled+; returns the
// output type, or MB_ARITH_NONE if the kernel can't take them.
static enum mb_arith_type check_args(VALUE out, VALUE sampled, size_t *length)
{
	if (!RB_TYPE_P(sampled, T_ARRAY)) {
		rb_raise(rb_eTypeError, "Inputs must be an Array of [buffer, extra] Arrays");
	}

	enum mb_arith_type ot = arith_type(out);
	if (ot == MB_ARITH_NONE || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		return MB_ARITH_NONE;
	}

	// The data (not just a view) must be writable
	VALUE data = out;
	if (RNARRAY_TYPE(out) == NARRAY_VIEW_T) {
		data = RNARRAY_VIEW(out)->data;
	}
	if (OBJ_FROZEN(data)) {
		return MB_ARITH_NONE;
	}

	*length = RNARRAY_SIZE(out);

	long n = RARRAY_LEN(sampled);
	for (long k = 0; k < n; k++) {
		VALUE pair = RARRAY_AREF(sampled, k);
		if (!RB_TYPE_P(pair, T_ARRAY) || RARRAY_LEN(pair) < 1) {
			return MB_ARITH_NONE;
		}

		VALUE v = RARRAY_AREF(pair, 0);
		if (!input_type_ok(ot, arith_type(v)) || !shape_ok(v, *length)) {
			return MB_ARITH_NONE;
		}
	}

	return ot;
}

// Numo's complex product (types/complex.h c_mul), written out.
#define CMUL(z, xr, xi, yr, yi) do { \
	(z).r = (xr) * (yr) - (xi) * (yi); \
	(z).i = (xr) * (yi) + (xi) * (yr); \
} while (0)

/*
 * call-seq: MB::Sound::FastArithmetic.product(out, constant, sampled) -> out or nil
 *
 * Fills +out+ with +constant+, then multiplies it by the buffer of each
 * [buffer, extra] pair in +sampled+ (extra is ignored), in place.  Returns
 * nil without changing +out+ if a buffer type, length, or layout doesn't
 * fit (see the file comment).
 */
static VALUE ruby_product(VALUE self, VALUE out, VALUE constant, VALUE sampled)
{
	size_t length;
	enum mb_arith_type ot = check_args(out, sampled, &length);
	if (ot == MB_ARITH_NONE) {
		return Qnil;
	}

	double cr, ci;
	num_parts(constant, &cr, &ci);
	if (ci != 0 && (ot == MB_ARITH_SF || ot == MB_ARITH_DF)) {
		return Qnil;
	}

	long n = RARRAY_LEN(sampled);
	if (ot == MB_ARITH_SC || ot == MB_ARITH_DC) {
		// At most one truly complex factor (see the file comment)
		_Bool complex_so_far = ci != 0;
		for (long k = 0; k < n; k++) {
			enum mb_arith_type it = arith_type(RARRAY_AREF(RARRAY_AREF(sampled, k), 0));
			if (it == MB_ARITH_SC || it == MB_ARITH_DC) {
				if (complex_so_far) {
					return Qnil;
				}
				complex_so_far = 1;
			}
		}
	}

	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);

	switch (ot) {
		case MB_ARITH_SF:
			{
				float *o = (float *)outp;
				float c = (float)cr;
				for (size_t i = 0; i < length; i++) o[i] = c;
				for (long k = 0; k < n; k++) {
					const float *x = (const float *)read_ptr(RARRAY_AREF(RARRAY_AREF(sampled, k), 0));
					for (size_t i = 0; i < length; i++) o[i] = o[i] * x[i];
				}
			}
			break;

		case MB_ARITH_DF:
			{
				double *o = (double *)outp;
				for (size_t i = 0; i < length; i++) o[i] = cr;
				for (long k = 0; k < n; k++) {
					const double *x = (const double *)read_ptr(RARRAY_AREF(RARRAY_AREF(sampled, k), 0));
					for (size_t i = 0; i < length; i++) o[i] = o[i] * x[i];
				}
			}
			break;

		case MB_ARITH_SC:
			{
				mb_sc *o = (mb_sc *)outp;
				mb_sc c = { (float)cr, (float)ci };
				for (size_t i = 0; i < length; i++) o[i] = c;
				for (long k = 0; k < n; k++) {
					VALUE v = RARRAY_AREF(RARRAY_AREF(sampled, k), 0);
					if (arith_type(v) == MB_ARITH_SC) {
						const mb_sc *x = (const mb_sc *)read_ptr(v);
						for (size_t i = 0; i < length; i++) {
							mb_sc z;
							CMUL(z, o[i].r, o[i].i, x[i].r, x[i].i);
							o[i] = z;
						}
					} else {
						const float *x = (const float *)read_ptr(v);
						const float zero = 0.0f;
						for (size_t i = 0; i < length; i++) {
							mb_sc z;
							CMUL(z, o[i].r, o[i].i, x[i], zero);
							o[i] = z;
						}
					}
				}
			}
			break;

		case MB_ARITH_DC:
			{
				mb_dc *o = (mb_dc *)outp;
				mb_dc c = { cr, ci };
				for (size_t i = 0; i < length; i++) o[i] = c;
				for (long k = 0; k < n; k++) {
					VALUE v = RARRAY_AREF(RARRAY_AREF(sampled, k), 0);
					if (arith_type(v) == MB_ARITH_DC) {
						const mb_dc *x = (const mb_dc *)read_ptr(v);
						for (size_t i = 0; i < length; i++) {
							mb_dc z;
							CMUL(z, o[i].r, o[i].i, x[i].r, x[i].i);
							o[i] = z;
						}
					} else {
						const double *x = (const double *)read_ptr(v);
						const double zero = 0.0;
						for (size_t i = 0; i < length; i++) {
							mb_dc z;
							CMUL(z, o[i].r, o[i].i, x[i], zero);
							o[i] = z;
						}
					}
				}
			}
			break;

		default:
			return Qnil;
	}

	RB_GC_GUARD(sampled);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.mix(out, constant, sampled) -> out or nil
 *
 * Fills +out+ with +constant+, then adds the buffer of each [buffer, gain]
 * pair in +sampled+, multiplied by its gain unless the gain is == 1 (as
 * Mixer#sample's Numo path does).  Returns nil without changing +out+ if a
 * buffer type, length, layout, or gain doesn't fit (a complex gain or
 * constant needs a complex buffer).
 */
static VALUE ruby_mix(VALUE self, VALUE out, VALUE constant, VALUE sampled)
{
	size_t length;
	enum mb_arith_type ot = check_args(out, sampled, &length);
	if (ot == MB_ARITH_NONE) {
		return Qnil;
	}

	_Bool real = ot == MB_ARITH_SF || ot == MB_ARITH_DF;

	double cr, ci;
	num_parts(constant, &cr, &ci);
	if (ci != 0 && real) {
		return Qnil;
	}

	long n = RARRAY_LEN(sampled);
	VALUE one = INT2FIX(1);
	for (long k = 0; k < n; k++) {
		VALUE pair = RARRAY_AREF(sampled, k);
		if (RARRAY_LEN(pair) < 2) {
			return Qnil;
		}
		VALUE gain = RARRAY_AREF(pair, 1);
		if (!rb_obj_is_kind_of(gain, rb_cNumeric) || (real && RB_TYPE_P(gain, T_COMPLEX))) {
			return Qnil;
		}

		// A complex input times a gain with an imaginary part is a product
		// of two truly complex factors (see the file comment)
		enum mb_arith_type it = arith_type(RARRAY_AREF(pair, 0));
		if ((it == MB_ARITH_SC || it == MB_ARITH_DC) && RB_TYPE_P(gain, T_COMPLEX) && !RTEST(rb_equal(gain, one))) {
			double gr, gi;
			num_parts(gain, &gr, &gi);
			if (gi != 0) {
				return Qnil;
			}
		}
	}

	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);

	for (long k = 0; k < n; k++) {
		VALUE pair = RARRAY_AREF(sampled, k);
		VALUE v = RARRAY_AREF(pair, 0);
		VALUE gain = RARRAY_AREF(pair, 1);
		_Bool unity = RTEST(rb_equal(gain, one));
		double gr, gi;
		num_parts(gain, &gr, &gi);

		switch (ot) {
			case MB_ARITH_SF:
				{
					float *o = (float *)outp;
					if (k == 0) { float c = (float)cr; for (size_t i = 0; i < length; i++) o[i] = c; }
					const float *x = (const float *)read_ptr(v);
					if (unity) {
						for (size_t i = 0; i < length; i++) o[i] = o[i] + x[i];
					} else {
						float g = (float)gr;
						for (size_t i = 0; i < length; i++) {
							float t = g * x[i];
							o[i] = o[i] + t;
						}
					}
				}
				break;

			case MB_ARITH_DF:
				{
					double *o = (double *)outp;
					if (k == 0) { for (size_t i = 0; i < length; i++) o[i] = cr; }
					const double *x = (const double *)read_ptr(v);
					if (unity) {
						for (size_t i = 0; i < length; i++) o[i] = o[i] + x[i];
					} else {
						for (size_t i = 0; i < length; i++) {
							double t = gr * x[i];
							o[i] = o[i] + t;
						}
					}
				}
				break;

			case MB_ARITH_SC:
				{
					mb_sc *o = (mb_sc *)outp;
					if (k == 0) { mb_sc c = { (float)cr, (float)ci }; for (size_t i = 0; i < length; i++) o[i] = c; }
					float g_r = (float)gr, g_i = (float)gi;
					if (arith_type(v) == MB_ARITH_SC) {
						const mb_sc *x = (const mb_sc *)read_ptr(v);
						for (size_t i = 0; i < length; i++) {
							mb_sc t;
							if (unity) {
								t = x[i];
							} else {
								CMUL(t, g_r, g_i, x[i].r, x[i].i);
							}
							o[i].r = o[i].r + t.r;
							o[i].i = o[i].i + t.i;
						}
					} else {
						const float *x = (const float *)read_ptr(v);
						const float zero = 0.0f;
						for (size_t i = 0; i < length; i++) {
							mb_sc t;
							if (unity) {
								t.r = x[i];
								t.i = zero;
							} else {
								CMUL(t, g_r, g_i, x[i], zero);
							}
							o[i].r = o[i].r + t.r;
							o[i].i = o[i].i + t.i;
						}
					}
				}
				break;

			case MB_ARITH_DC:
				{
					mb_dc *o = (mb_dc *)outp;
					if (k == 0) { mb_dc c = { cr, ci }; for (size_t i = 0; i < length; i++) o[i] = c; }
					if (arith_type(v) == MB_ARITH_DC) {
						const mb_dc *x = (const mb_dc *)read_ptr(v);
						for (size_t i = 0; i < length; i++) {
							mb_dc t;
							if (unity) {
								t = x[i];
							} else {
								CMUL(t, gr, gi, x[i].r, x[i].i);
							}
							o[i].r = o[i].r + t.r;
							o[i].i = o[i].i + t.i;
						}
					} else {
						const double *x = (const double *)read_ptr(v);
						const double zero = 0.0;
						for (size_t i = 0; i < length; i++) {
							mb_dc t;
							if (unity) {
								t.r = x[i];
								t.i = zero;
							} else {
								CMUL(t, gr, gi, x[i], zero);
							}
							o[i].r = o[i].r + t.r;
							o[i].i = o[i].i + t.i;
						}
					}
				}
				break;

			default:
				return Qnil;
		}
	}

	// No inputs: just the constant
	if (n == 0) {
		switch (ot) {
			case MB_ARITH_SF: { float *o = (float *)outp; float c = (float)cr; for (size_t i = 0; i < length; i++) o[i] = c; } break;
			case MB_ARITH_DF: { double *o = (double *)outp; for (size_t i = 0; i < length; i++) o[i] = cr; } break;
			case MB_ARITH_SC: { mb_sc *o = (mb_sc *)outp; mb_sc c = { (float)cr, (float)ci }; for (size_t i = 0; i < length; i++) o[i] = c; } break;
			case MB_ARITH_DC: { mb_dc *o = (mb_dc *)outp; mb_dc c = { cr, ci }; for (size_t i = 0; i < length; i++) o[i] = c; } break;
			default: return Qnil;
		}
	}

	RB_GC_GUARD(sampled);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.copy(out, src) -> out or nil
 *
 * Copies +src+ into +out+ (e.g. a reused buffer for a node that works in
 * place on a frozen input) without allocating.  Both must be contiguous 1D
 * NArrays of the same type (SFloat, DFloat, SComplex, or DComplex) and
 * length, and +out+ writable; otherwise returns nil without writing.
 */
static VALUE ruby_copy(VALUE self, VALUE out, VALUE src)
{
	enum mb_arith_type ot = arith_type(out);
	if (ot == MB_ARITH_NONE || ot != arith_type(src) || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		return Qnil;
	}

	size_t length = RNARRAY_SIZE(out);
	if (!shape_ok(src, length)) {
		return Qnil;
	}

	VALUE data = out;
	if (RNARRAY_TYPE(out) == NARRAY_VIEW_T) {
		data = RNARRAY_VIEW(out)->data;
	}
	if (OBJ_FROZEN(data)) {
		return Qnil;
	}

	size_t elsize = elem_size(ot);

	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);
	const char *srcp = read_ptr(src);
	if (length > 0) {
		memmove(outp, srcp, length * elsize);
	}

	RB_GC_GUARD(src);
	return out;
}

// Numo's default min/max (types/real_accum.h f_min/f_max): leading NaNs
// are skipped, later NaNs never compare, and an all-NaN buffer gives its last
// value.
#define MB_MINMAX(type, data, n, lt_or_gt, result) do { \
	type mm_y = 0; \
	size_t mm_i = 0; \
	while (mm_i < (n)) { \
		mm_y = (data)[mm_i++]; \
		if (!isnan(mm_y)) { \
			for (; mm_i < (n); mm_i++) { \
				type mm_v = (data)[mm_i]; \
				if (mm_v lt_or_gt mm_y) mm_y = mm_v; \
			} \
			break; \
		} \
	} \
	(result) = mm_y; \
} while (0)

/*
 * call-seq: MB::Sound::FastArithmetic.min_max(buf, result) -> result or nil
 *
 * Stores buf.min and buf.max (as Numo computes them, as Floats) in
 * result[0] and result[1] (a 2-element Array, reused by the caller), for a
 * contiguous 1D SFloat or DFloat +buf+ with at least one value.  Returns
 * nil for anything else.
 */
static VALUE ruby_min_max(VALUE self, VALUE buf, VALUE result)
{
	Check_Type(result, T_ARRAY);
	enum mb_arith_type t = arith_type(buf);
	if ((t != MB_ARITH_SF && t != MB_ARITH_DF) || RNARRAY_NDIM(buf) != 1 || !RTEST(nary_check_contiguous(buf))) {
		return Qnil;
	}

	size_t n = RNARRAY_SIZE(buf);
	if (n == 0) {
		return Qnil;
	}

	double lo, hi;
	if (t == MB_ARITH_SF) {
		const float *x = (const float *)read_ptr(buf);
		float a, b;
		MB_MINMAX(float, x, n, <, a);
		MB_MINMAX(float, x, n, >, b);
		lo = a;
		hi = b;
	} else {
		const double *x = (const double *)read_ptr(buf);
		MB_MINMAX(double, x, n, <, lo);
		MB_MINMAX(double, x, n, >, hi);
	}

	rb_ary_store(result, 0, DBL2NUM(lo));
	rb_ary_store(result, 1, DBL2NUM(hi));

	RB_GC_GUARD(buf);
	return result;
}

// Checks a real, contiguous, writable output for .divide and .power;
// returns its type or MB_ARITH_NONE.
static enum mb_arith_type writable_real(VALUE out)
{
	enum mb_arith_type ot = arith_type(out);
	if ((ot != MB_ARITH_SF && ot != MB_ARITH_DF) || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		return MB_ARITH_NONE;
	}

	VALUE data = RNARRAY_TYPE(out) == NARRAY_VIEW_T ? RNARRAY_VIEW(out)->data : out;
	return OBJ_FROZEN(data) || OBJ_FROZEN(out) ? MB_ARITH_NONE : ot;
}

/*
 * call-seq: MB::Sound::FastArithmetic.divide(out, divisor) -> out or nil
 *
 * Divides the real buffer +out+ in place by +divisor+ (a contiguous NArray
 * of the same type and length, or a Float or Integer cast to the buffer's
 * type), as Numo's out.inplace / divisor does.  Returns nil without
 * writing for anything else (complex, other types, promotion).
 */
static VALUE ruby_divide(VALUE self, VALUE out, VALUE divisor)
{
	enum mb_arith_type ot = writable_real(out);
	if (ot == MB_ARITH_NONE) {
		return Qnil;
	}

	size_t length = RNARRAY_SIZE(out);
	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);

	if (RB_FLOAT_TYPE_P(divisor) || RB_INTEGER_TYPE_P(divisor)) {
		double d = NUM2DBL(divisor);
		if (ot == MB_ARITH_SF) {
			float *o = (float *)outp;
			float df = (float)d;
			for (size_t i = 0; i < length; i++) o[i] = o[i] / df;
		} else {
			double *o = (double *)outp;
			for (size_t i = 0; i < length; i++) o[i] = o[i] / d;
		}
		return out;
	}

	if (arith_type(divisor) != ot || !shape_ok(divisor, length)) {
		return Qnil;
	}

	if (ot == MB_ARITH_SF) {
		float *o = (float *)outp;
		const float *x = (const float *)read_ptr(divisor);
		for (size_t i = 0; i < length; i++) o[i] = o[i] / x[i];
	} else {
		double *o = (double *)outp;
		const double *x = (const double *)read_ptr(divisor);
		for (size_t i = 0; i < length; i++) o[i] = o[i] / x[i];
	}

	RB_GC_GUARD(divisor);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.power(out, exponent) -> out or nil
 *
 * Raises the real buffer +out+ in place to the powers in +exponent+ (a
 * contiguous NArray of the same type and length), as Numo's
 * out.inplace ** exponent does (numo's m_pow: C's double pow, rounded to
 * the buffer type).  Scalar exponents (Numo uses repeated multiplication
 * for Integers) and anything else return nil without writing.
 */
static VALUE ruby_power(VALUE self, VALUE out, VALUE exponent)
{
	enum mb_arith_type ot = writable_real(out);
	if (ot == MB_ARITH_NONE) {
		return Qnil;
	}

	size_t length = RNARRAY_SIZE(out);
	if (arith_type(exponent) != ot || !shape_ok(exponent, length)) {
		return Qnil;
	}

	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);
	if (ot == MB_ARITH_SF) {
		float *o = (float *)outp;
		const float *x = (const float *)read_ptr(exponent);
		for (size_t i = 0; i < length; i++) o[i] = pow(o[i], x[i]);
	} else {
		double *o = (double *)outp;
		const double *x = (const double *)read_ptr(exponent);
		for (size_t i = 0; i < length; i++) o[i] = pow(o[i], x[i]);
	}

	RB_GC_GUARD(exponent);
	return out;
}

// The element size of an arithmetic type.
static size_t elem_size(enum mb_arith_type t)
{
	switch (t) {
		case MB_ARITH_SF: return sizeof(float);
		case MB_ARITH_DF: return sizeof(double);
		case MB_ARITH_SC: return sizeof(mb_sc);
		case MB_ARITH_DC: return sizeof(mb_dc);
		default: return 0;
	}
}

// True if +v+ is a writable contiguous 1D NArray.
static _Bool writable_contiguous(VALUE v)
{
	if (RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || OBJ_FROZEN(v)) {
		return 0;
	}
	VALUE data = RNARRAY_TYPE(v) == NARRAY_VIEW_T ? RNARRAY_VIEW(v)->data : v;
	return !OBJ_FROZEN(data);
}

/*
 * call-seq: MB::Sound::FastArithmetic.circular_read(source, offset, length, target) -> target or nil
 *
 * MB::M.circular_read(source, offset, length, target: target) without
 * allocating: copies +length+ values of +source+ from +offset+ (negative
 * counts from the end), wrapping at its end, into the start of +target+.
 * Both must be contiguous 1D NArrays of one type, +target+ writable and at
 * least +length+ long, +length+ from 1 to the source length, and +offset+
 * within the source; otherwise returns nil (MB::M then raises or casts).
 */
static VALUE ruby_circular_read(VALUE self, VALUE source, VALUE offset_v, VALUE length_v, VALUE target)
{
	enum mb_arith_type t = arith_type(source);
	if (t == MB_ARITH_NONE || arith_type(target) != t || !RB_INTEGER_TYPE_P(offset_v) || !RB_INTEGER_TYPE_P(length_v)) {
		return Qnil;
	}
	if (RNARRAY_NDIM(source) != 1 || !RTEST(nary_check_contiguous(source)) || !writable_contiguous(target)) {
		return Qnil;
	}

	long n = (long)RNARRAY_SIZE(source);
	long offset = NUM2LONG(offset_v);
	long length = NUM2LONG(length_v);
	if (offset < -n || offset >= n || length < 1 || length > n || (size_t)length > RNARRAY_SIZE(target)) {
		return Qnil;
	}
	if (offset < 0) {
		offset += n;
	}

	size_t es = elem_size(t);
	const char *src = read_ptr(source);
	char *dst = nary_get_pointer_for_write(target) + nary_get_offset(target);
	long before = n - offset;
	if (length <= before) {
		memmove(dst, src + offset * es, length * es);
	} else {
		memmove(dst, src + offset * es, before * es);
		memmove(dst + before * es, src, (length - before) * es);
	}

	RB_GC_GUARD(source);
	return target;
}

/*
 * call-seq: MB::Sound::FastArithmetic.circular_write(target, source, offset) -> target or nil
 *
 * MB::M.circular_write(target, source, offset) without allocating: copies
 * +source+ into +target+ from +offset+ (negative counts from the end),
 * wrapping at its end.  Both must be contiguous 1D NArrays of one type,
 * +target+ writable and at least as long as +source+ (not empty), and
 * +offset+ within the target; otherwise returns nil (MB::M then raises or
 * casts).
 */
static VALUE ruby_circular_write(VALUE self, VALUE target, VALUE source, VALUE offset_v)
{
	enum mb_arith_type t = arith_type(target);
	if (t == MB_ARITH_NONE || arith_type(source) != t || !RB_INTEGER_TYPE_P(offset_v)) {
		return Qnil;
	}
	if (RNARRAY_NDIM(source) != 1 || !RTEST(nary_check_contiguous(source)) || !writable_contiguous(target)) {
		return Qnil;
	}

	long n = (long)RNARRAY_SIZE(target);
	long length = (long)RNARRAY_SIZE(source);
	long offset = NUM2LONG(offset_v);
	if (offset < -n || offset >= n || length < 1 || length > n) {
		return Qnil;
	}
	if (offset < 0) {
		offset += n;
	}

	size_t es = elem_size(t);
	const char *src = read_ptr(source);
	char *dst = nary_get_pointer_for_write(target) + nary_get_offset(target);
	long before = n - offset;
	if (length <= before) {
		memmove(dst + offset * es, src, length * es);
	} else {
		memmove(dst + offset * es, src, before * es);
		memmove(dst, src + before * es, (length - before) * es);
	}

	RB_GC_GUARD(source);
	return target;
}

/*
 * call-seq: MB::Sound::FastArithmetic.wet_dry(out, delayed, wet, data, dry) -> out or nil
 *
 * Computes wet * delayed + dry * data (or just wet * delayed when +dry+ is
 * nil) into +out+, as Filter::Delay's Numo expression does for SFloat
 * buffers and Numeric gains: each product rounded to float, then the sum.
 * +out+ may be +data+ (each sample reads its inputs before writing).  All
 * buffers must be contiguous SFloat of one length, +out+ writable, and
 * +wet+/+dry+ Floats or Integers; otherwise returns nil without writing.
 */
static VALUE ruby_wet_dry(VALUE self, VALUE out, VALUE delayed, VALUE wet, VALUE data, VALUE dry)
{
	if (arith_type(out) != MB_ARITH_SF || !writable_contiguous(out)) {
		return Qnil;
	}
	size_t length = RNARRAY_SIZE(out);
	if (arith_type(delayed) != MB_ARITH_SF || !shape_ok(delayed, length)) {
		return Qnil;
	}
	if (!(RB_FLOAT_TYPE_P(wet) || RB_INTEGER_TYPE_P(wet))) {
		return Qnil;
	}
	_Bool use_dry = !NIL_P(dry);
	if (use_dry && (!(RB_FLOAT_TYPE_P(dry) || RB_INTEGER_TYPE_P(dry)) || arith_type(data) != MB_ARITH_SF || !shape_ok(data, length))) {
		return Qnil;
	}

	float w = (float)NUM2DBL(wet);
	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	const float *d = (const float *)read_ptr(delayed);
	if (use_dry) {
		float g = (float)NUM2DBL(dry);
		const float *x = (const float *)read_ptr(data);
		for (size_t i = 0; i < length; i++) {
			float a = w * d[i];
			float b = g * x[i];
			o[i] = a + b;
		}
	} else {
		for (size_t i = 0; i < length; i++) {
			o[i] = w * d[i];
		}
	}

	RB_GC_GUARD(delayed);
	RB_GC_GUARD(data);
	return out;
}

void Init_fast_arithmetic(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_arithmetic = rb_define_module_under(sound, "FastArithmetic");

	rb_define_module_function(fast_arithmetic, "product", ruby_product, 3);
	rb_define_module_function(fast_arithmetic, "mix", ruby_mix, 3);
	rb_define_module_function(fast_arithmetic, "copy", ruby_copy, 2);
	rb_define_module_function(fast_arithmetic, "min_max", ruby_min_max, 2);
	rb_define_module_function(fast_arithmetic, "divide", ruby_divide, 2);
	rb_define_module_function(fast_arithmetic, "power", ruby_power, 2);
	rb_define_module_function(fast_arithmetic, "circular_read", ruby_circular_read, 4);
	rb_define_module_function(fast_arithmetic, "circular_write", ruby_circular_write, 3);
	rb_define_module_function(fast_arithmetic, "wet_dry", ruby_wet_dry, 5);
}
