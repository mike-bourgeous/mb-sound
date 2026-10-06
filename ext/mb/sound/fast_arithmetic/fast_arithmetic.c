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
 * The Ruby mirror is the Numo code in Multiplier#sample_numo and
 * Mixer#sample_numo (the fast paths' former bodies), and specs compare both
 * for exactly equal values, so the operations are Numo's, in Numo's order:
 * the output is filled with the constant (cast to the buffer type), then
 * each input is multiplied in (Multiplier) or added (Mixer; an input whose
 * gain isn't == 1 is first multiplied by the gain cast to the buffer type).
 * Real inputs to complex buffers are promoted to (x, 0) and go through the
 * full complex product, as Numo's cast does.  Complex products are written
 * out (not C99's complex *, which adds Annex G infinity handling), and the
 * extension is built with -ffp-contract=off so nothing is fused.
 *
 * Buffer types: SFloat (SFloat inputs), DFloat (DFloat), SComplex (SComplex
 * or SFloat), DComplex (DComplex or DFloat), every input exactly as long as
 * the output and contiguous, and the output writable.  Anything else returns
 * nil without touching the output, and the caller falls back to Numo.
 */

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

enum mb_arith_type { MB_ARITH_NONE, MB_ARITH_SF, MB_ARITH_DF, MB_ARITH_SC, MB_ARITH_DC };

typedef struct { float r, i; } mb_sc;
typedef struct { double r, i; } mb_dc;

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

	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);
	long n = RARRAY_LEN(sampled);

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

void Init_fast_arithmetic(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_arithmetic = rb_define_module_under(sound, "FastArithmetic");

	rb_define_module_function(fast_arithmetic, "product", ruby_product, 3);
	rb_define_module_function(fast_arithmetic, "mix", ruby_mix, 3);
}
