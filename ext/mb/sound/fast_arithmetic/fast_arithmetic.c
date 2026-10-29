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
 * .scale multiplies a real or complex float buffer by a real gain in place
 * (Tone#gain).  .copy copies a buffer into another (for nodes that work in place on a
 * copy of a frozen input), and .min_max finds Numo's min and max of a real
 * buffer at once (for Synth's lane levels).  .divide and .power are the
 * in-place / and ** of GraphNode arithmetic procs for real buffers, and
 * .circular_read/.circular_write are MB::M's ring buffer copies (delay
 * lines, CircularBuffer) without the Ranges and views; .wet_dry is
 * Filter::Delay's output mix, and .complex_part copies real or imaginary
 * parts out of complex buffers.  .pan is ChannelMixer::Pan with a moving
 * position (PanLaws.gains and the mix, in Numo's float steps).  .add_at
 * adds a (ramped) buffer into part of another (Session's player mix), and
 * .fill_range stores a number into part of a buffer (held note values).
 * .accumulate is add_at with offsets and two factors (bus deliveries and
 * sends), .last_at_least finds a bus's last loud sample, and .copy_range
 * copies part of a buffer into part of another (bus taps; alloc-2).
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
#include "mb_vec_exp2.h"

enum mb_arith_type { MB_ARITH_NONE, MB_ARITH_SF, MB_ARITH_DF, MB_ARITH_SC, MB_ARITH_DC };

typedef struct { float r, i; } mb_sc;
typedef struct { double r, i; } mb_dc;

static size_t elem_size(enum mb_arith_type t);
static enum mb_arith_type writable_real(VALUE out);

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

/*
 * call-seq: MB::Sound::FastArithmetic.cast_copy(out, src) -> out or nil
 *
 * Copies +src+ into +out+ converting between SFloat and DFloat as Numo's
 * cast does ((float) or (double) of each value), without allocating, for
 * contiguous 1D buffers of the same length (+out+ writable).  Returns nil
 * without writing for anything else (dropouts-2: a feedback loop's moving
 * delay times and sustain params, every block).
 */
static VALUE ruby_cast_copy(VALUE self, VALUE out, VALUE src)
{
	enum mb_arith_type ot = writable_real(out);
	enum mb_arith_type st = arith_type(src);
	if (ot == MB_ARITH_NONE || (st != MB_ARITH_SF && st != MB_ARITH_DF)) {
		return Qnil;
	}

	size_t length = RNARRAY_SIZE(out);
	if (!shape_ok(src, length)) {
		return Qnil;
	}

	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);
	const char *srcp = read_ptr(src);
	if (ot == st) {
		if (length > 0) {
			memmove(outp, srcp, length * elem_size(ot));
		}
	} else if (ot == MB_ARITH_SF) {
		float *o = (float *)outp;
		const double *d = (const double *)srcp;
		for (size_t i = 0; i < length; i++) {
			o[i] = (float)d[i];
		}
	} else {
		double *o = (double *)outp;
		const float *f = (const float *)srcp;
		for (size_t i = 0; i < length; i++) {
			o[i] = (double)f[i];
		}
	}

	RB_GC_GUARD(src);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.ease_plain(out, data, in_lo, in_scale, kind, clamp, out_scale, out_lo) -> out or nil
 *
 * GraphNode::CurveShaper's exact (plain, not antialiased) shaper for the
 * linear (+kind+ 0) and smoothstep (+kind+ 1) curves, as its Numo code
 * computes it (CurveShaper#plain): x = (double(data) - in_lo) * in_scale,
 * clipped to 0..1 if +clamp+, y = x (linear) or x * x * (3 - 2x) (as
 * (x * x) * (x * -2 + 3), the same rounding), then y * out_scale + out_lo,
 * stored as float in +out+ (an SFloat as long as +data+, an SFloat or
 * DFloat).  Each Numo step allocated a few objects every buffer
 * (dropouts-2).  Returns nil without writing for anything else.
 */
static VALUE ruby_ease_plain(VALUE self, VALUE out, VALUE data, VALUE in_lo_v, VALUE in_scale_v, VALUE kind_v, VALUE clamp_v, VALUE out_scale_v, VALUE out_lo_v)
{
	if (writable_real(out) != MB_ARITH_SF) {
		return Qnil;
	}
	enum mb_arith_type dt = arith_type(data);
	size_t length = RNARRAY_SIZE(out);
	if ((dt != MB_ARITH_SF && dt != MB_ARITH_DF) || !shape_ok(data, length)) {
		return Qnil;
	}
	if (!RB_FLOAT_TYPE_P(in_lo_v) || !RB_FLOAT_TYPE_P(in_scale_v) || !RB_FLOAT_TYPE_P(out_scale_v) || !RB_FLOAT_TYPE_P(out_lo_v) || !RB_INTEGER_TYPE_P(kind_v)) {
		return Qnil;
	}
	long kind = NUM2LONG(kind_v);
	if (kind != 0 && kind != 1) {
		return Qnil;
	}

	double in_lo = RFLOAT_VALUE(in_lo_v);
	double in_scale = RFLOAT_VALUE(in_scale_v);
	double out_scale = RFLOAT_VALUE(out_scale_v);
	double out_lo = RFLOAT_VALUE(out_lo_v);
	_Bool clamp = RTEST(clamp_v);

	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	const char *srcp = read_ptr(data);
	for (size_t i = 0; i < length; i++) {
		double x = dt == MB_ARITH_SF ? (double)((const float *)srcp)[i] : ((const double *)srcp)[i];
		x = x - in_lo;
		x = x * in_scale;
		if (clamp) {
			// (Numo's clip: below min gives min, above max gives max)
			if (x < 0.0) x = 0.0;
			if (x > 1.0) x = 1.0;
		}
		double y = x;
		if (kind == 1) {
			double s = x * -2.0;
			s = s + 3.0;
			double q = x * x;
			y = q * s;
		}
		y = y * out_scale;
		y = y + out_lo;
		o[i] = (float)y;
	}

	RB_GC_GUARD(data);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.knob_ramp(out, pos, n, j0, length, curve, exp, mul, add1, add2, to) -> out or nil
 *
 * GraphNode::Knob#ramp_values written into out[pos, n] (an SFloat) as its
 * Numo code computes them (dropouts-2: about ten Numo steps a buffer while
 * a knob turns): t = (j0 + 1 + i) / length, clipped to 0..1 on the ramp's
 * last block (j0 + n >= length); the curve (+curve+ 0: none or linear, 1:
 * smoothstep as Curve#map! computes it); then x * mul + add1 (linear knob
 * scales, +exp+ false) or exp(x * mul + add1 + add2) (:exp knobs; two
 * additions, as Ruby's `c + a + b` does), and +to+ where t reached 1;
 * stored as float.  Returns nil without writing for other arguments.
 */
static VALUE ruby_knob_ramp(VALUE self, VALUE out, VALUE pos_v, VALUE n_v, VALUE j0_v, VALUE length_v, VALUE curve_v, VALUE exp_v, VALUE mul_v, VALUE add1_v, VALUE add2_v, VALUE to_v)
{
	if (writable_real(out) != MB_ARITH_SF) {
		return Qnil;
	}
	if (!RB_INTEGER_TYPE_P(pos_v) || !RB_INTEGER_TYPE_P(n_v) || !RB_INTEGER_TYPE_P(j0_v) || !RB_INTEGER_TYPE_P(length_v) || !RB_INTEGER_TYPE_P(curve_v)) {
		return Qnil;
	}
	if (!RB_FLOAT_TYPE_P(mul_v) || !RB_FLOAT_TYPE_P(add1_v) || !RB_FLOAT_TYPE_P(add2_v) || !RB_FLOAT_TYPE_P(to_v)) {
		return Qnil;
	}
	long pos = NUM2LONG(pos_v), n = NUM2LONG(n_v), j0 = NUM2LONG(j0_v), length = NUM2LONG(length_v), curve = NUM2LONG(curve_v);
	long size = (long)RNARRAY_SIZE(out);
	if (pos < 0 || n < 0 || pos + n > size || length <= 0 || (curve != 0 && curve != 1)) {
		return Qnil;
	}

	_Bool exp_scale = RTEST(exp_v);
	double mul = RFLOAT_VALUE(mul_v), add1 = RFLOAT_VALUE(add1_v), add2 = RFLOAT_VALUE(add2_v), to = RFLOAT_VALUE(to_v);
	double len = (double)length;
	_Bool ends = j0 + n >= length;
	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out)) + pos;
	for (long i = 0; i < n; i++) {
		double t = (double)(j0 + 1) + (double)i;
		t = t / len;
		if (ends) {
			if (t < 0.0) t = 0.0;
			if (t > 1.0) t = 1.0;
		}
		double x = t;
		if (curve == 1) {
			double sc = x * -2.0;
			sc = sc + 3.0;
			double q = x * x;
			x = q * sc;
		}
		x = x * mul;
		x = x + add1;
		if (exp_scale) {
			x = x + add2;
			x = exp(x);
		}
		if (ends && t >= 1.0) {
			x = to;
		}
		o[i] = (float)x;
	}

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
// Stores +v+ at +idx+ of Array +ary+, keeping the Float already there if
// it has exactly the same bits: values that aren't flonums (-0.0, and
// magnitudes beyond ~1e+-77) would otherwise be a new heap Float on every
// call (a silent Synth lane's -0.0 twice a buffer; alloc-2).
static void store_double(VALUE ary, long idx, double v)
{
	if (idx < RARRAY_LEN(ary)) {
		VALUE old = RARRAY_AREF(ary, idx);
		if (RB_FLOAT_TYPE_P(old)) {
			double o = RFLOAT_VALUE(old);
			if (memcmp(&o, &v, sizeof(double)) == 0) {
				return;
			}
		}
	}
	rb_ary_store(ary, idx, DBL2NUM(v));
}

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

	store_double(result, 0, lo);
	store_double(result, 1, hi);

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
 * the buffer type), or to a Float exponent (cast to the buffer type, as
 * Numo's out ** exponent does).  Integer exponents (Numo uses repeated
 * multiplication) and anything else return nil without writing.
 */
static VALUE ruby_power(VALUE self, VALUE out, VALUE exponent)
{
	enum mb_arith_type ot = writable_real(out);
	if (ot == MB_ARITH_NONE) {
		return Qnil;
	}

	size_t length = RNARRAY_SIZE(out);

	// A Float exponent, cast to the buffer type as Numo casts it (Integer
	// exponents take Numo's repeated multiplication, so they stay in Numo)
	if (RB_FLOAT_TYPE_P(exponent)) {
		char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);
		double e = RFLOAT_VALUE(exponent);
		if (ot == MB_ARITH_SF) {
			float *o = (float *)outp;
			float ef = (float)e;
			for (size_t i = 0; i < length; i++) o[i] = pow(o[i], ef);
		} else {
			double *o = (double *)outp;
			for (size_t i = 0; i < length; i++) o[i] = pow(o[i], e);
		}
		return out;
	}

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

/*
 * call-seq: MB::Sound::FastArithmetic.power_fast(out, exponent) -> out or nil
 *
 * Like .power, for a single-precision +out+ holding a patch-constant base
 * (a Constant or Knob raised to a signal): MB::Sound.precision :fast's
 * 2^(b log2 a) (mb_vec_pow, the plan layer's Op::Pow with a Constant base),
 * so unplanned graphs compute what plans compute.  +exponent+ is a
 * contiguous SFloat of the same length or a Float (cast to float, as a
 * plan fills it).  Returns nil without writing for anything else.
 */
static VALUE ruby_power_fast(VALUE self, VALUE out, VALUE exponent)
{
	if (writable_real(out) != MB_ARITH_SF) {
		return Qnil;
	}

	size_t length = RNARRAY_SIZE(out);
	_Bool scalar = RB_FLOAT_TYPE_P(exponent);
	if (!scalar && (arith_type(exponent) != MB_ARITH_SF || !shape_ok(exponent, length))) {
		return Qnil;
	}

	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	const float *x = scalar ? NULL : (const float *)read_ptr(exponent);
	float ef = scalar ? (float)RFLOAT_VALUE(exponent) : 0.0f;

	// Copies of the bases (and a filled exponent): the kernel's inputs and
	// output may not overlap
	float a[MB_VEC_CHUNK], b[MB_VEC_CHUNK];
	if (scalar) {
		for (size_t i = 0; i < MB_VEC_CHUNK; i++) b[i] = ef;
	}
	for (size_t start = 0; start < length; start += MB_VEC_CHUNK) {
		size_t m = length - start < MB_VEC_CHUNK ? length - start : MB_VEC_CHUNK;
		memcpy(a, o + start, m * sizeof(float));
		mb_vec_pow(o + start, a, scalar ? b : x + start, m);
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

/*
 * call-seq: MB::Sound::FastArithmetic.complex_part(out, src, imag) -> out or nil
 *
 * Copies the real parts (or imaginary parts if +imag+ is true) of the
 * contiguous SComplex/DComplex +src+ into +out+ (a writable contiguous
 * SFloat/DFloat of the same precision and length), as src.real / src.imag
 * would return them.  Returns nil without writing for anything else.
 */
static VALUE ruby_complex_part(VALUE self, VALUE out, VALUE src, VALUE imag)
{
	enum mb_arith_type st = arith_type(src);
	enum mb_arith_type ot = arith_type(out);
	if (!((st == MB_ARITH_SC && ot == MB_ARITH_SF) || (st == MB_ARITH_DC && ot == MB_ARITH_DF)) || !writable_contiguous(out)) {
		return Qnil;
	}
	size_t length = RNARRAY_SIZE(out);
	if (!shape_ok(src, length)) {
		return Qnil;
	}

	char *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);
	_Bool im = RTEST(imag);
	if (st == MB_ARITH_SC) {
		const mb_sc *x = (const mb_sc *)read_ptr(src);
		float *o = (float *)outp;
		for (size_t i = 0; i < length; i++) o[i] = im ? x[i].i : x[i].r;
	} else {
		const mb_dc *x = (const mb_dc *)read_ptr(src);
		double *o = (double *)outp;
		for (size_t i = 0; i < length; i++) o[i] = im ? x[i].i : x[i].r;
	}

	RB_GC_GUARD(src);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.pan(law, position, input, gains, outs) -> outs or nil
 *
 * ChannelMixer::Pan with a moving position: writes the left and right
 * gains (ChannelMixer::PanLaws.gains) for the SFloat +position+ into the
 * two SFloats of the Array +gains+, and the gains times the SFloat +input+
 * into the two SFloats of +outs+.  +law+ is 0 (:equal_power), 1 (:linear),
 * or 2 (:minus_4_5db).  Every buffer must be contiguous and as long as
 * +input+, and the gains and outputs writable; otherwise returns nil without
 * writing.
 *
 * The steps are Numo's, each rounded to float as Numo stores it: the
 * position clipped to -1..1 (clip), then for :equal_power the angle
 * (p + 1) * (float)(pi / 4) and the gains cos and sin of it (Numo's
 * SFloat cos/sin call the double functions on the float and round the
 * result); for :linear (1 - p) * 0.5 and (p + 1) * 0.5; for :minus_4_5db
 * those raised to (float)0.75 with pow.  Each output is gain * input.
 */
static VALUE ruby_pan(VALUE self, VALUE law, VALUE position, VALUE input, VALUE gains, VALUE outs)
{
	if (!RB_TYPE_P(gains, T_ARRAY) || RARRAY_LEN(gains) != 2 || !RB_TYPE_P(outs, T_ARRAY) || RARRAY_LEN(outs) != 2) {
		return Qnil;
	}
	if (arith_type(input) != MB_ARITH_SF || RNARRAY_NDIM(input) != 1 || !RTEST(nary_check_contiguous(input))) {
		return Qnil;
	}
	size_t length = RNARRAY_SIZE(input);
	if (arith_type(position) != MB_ARITH_SF || !shape_ok(position, length)) {
		return Qnil;
	}

	VALUE gl_v = rb_ary_entry(gains, 0), gr_v = rb_ary_entry(gains, 1);
	VALUE ol_v = rb_ary_entry(outs, 0), or_v = rb_ary_entry(outs, 1);
	VALUE writes[4] = { gl_v, gr_v, ol_v, or_v };
	for (int j = 0; j < 4; j++) {
		if (writable_real(writes[j]) != MB_ARITH_SF || RNARRAY_SIZE(writes[j]) != length) {
			return Qnil;
		}
	}

	int lw = NUM2INT(law);
	if (lw < 0 || lw > 2) {
		return Qnil;
	}

	const float *pos = (const float *)read_ptr(position);
	const float *x = (const float *)read_ptr(input);
	float *gl = (float *)(nary_get_pointer_for_write(gl_v) + nary_get_offset(gl_v));
	float *gr = (float *)(nary_get_pointer_for_write(gr_v) + nary_get_offset(gr_v));
	float *ol = (float *)(nary_get_pointer_for_write(ol_v) + nary_get_offset(ol_v));
	float *orr = (float *)(nary_get_pointer_for_write(or_v) + nary_get_offset(or_v));

	const float quarter_pi = (float)(M_PI / 4);
	const float half = 0.5f;
	const float exponent = 0.75f;

	if (lw == 0) {
		// Separate loops for cos and sin, as Numo calls them: a compiler may
		// otherwise merge the two into sincos(), which isn't guaranteed to
		// round the same as cos() and sin() on every platform
		for (size_t i = 0; i < length; i++) {
			float p = pos[i];
			if (p < -1.0f) p = -1.0f;
			if (p > 1.0f) p = 1.0f;
			float angle = (p + 1.0f) * quarter_pi;
			gr[i] = angle;
			gl[i] = (float)cos((double)angle);
		}
		for (size_t i = 0; i < length; i++) {
			gr[i] = (float)sin((double)gr[i]);
		}
	} else {
		for (size_t i = 0; i < length; i++) {
			float p = pos[i];
			if (p < -1.0f) p = -1.0f;
			if (p > 1.0f) p = 1.0f;

			float l = (1.0f - p) * half;
			float r = (p + 1.0f) * half;
			if (lw == 2) {
				l = (float)pow((double)l, (double)exponent);
				r = (float)pow((double)r, (double)exponent);
			}
			gl[i] = l;
			gr[i] = r;
		}
	}

	for (size_t i = 0; i < length; i++) {
		ol[i] = gl[i] * x[i];
		orr[i] = gr[i] * x[i];
	}

	RB_GC_GUARD(position);
	RB_GC_GUARD(input);
	RB_GC_GUARD(gains);
	RB_GC_GUARD(outs);
	return outs;
}

/*
 * call-seq: MB::Sound::FastArithmetic.scale(out, gain) -> out or nil
 *
 * Multiplies +out+ (SFloat or SComplex, contiguous, writable) by +gain+ in
 * place: a real Numeric (cast to float, as Numo's fill of a Multiplier's
 * constant), or a contiguous SFloat as long as +out+.  The same values as
 * Multiplier's product of the buffer and the gain (a real factor's
 * imaginary part is zero; complex buffers use the full product, as Numo
 * does, for the same signed zeros and NaNs).  Returns nil
 * without changing +out+ for anything else (Tone#gain then uses Numo).
 */
static VALUE ruby_scale(VALUE self, VALUE out, VALUE gain)
{
	enum mb_arith_type ot = arith_type(out);
	if ((ot != MB_ARITH_SF && ot != MB_ARITH_SC) || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		return Qnil;
	}
	VALUE data = out;
	if (RNARRAY_TYPE(out) == NARRAY_VIEW_T) {
		data = RNARRAY_VIEW(out)->data;
	}
	if (OBJ_FROZEN(data)) {
		return Qnil;
	}

	size_t length = RNARRAY_SIZE(out);
	const float *g = NULL;
	float gc = 0;
	if (RB_INTEGER_TYPE_P(gain) || RB_FLOAT_TYPE_P(gain)) {
		gc = (float)NUM2DBL(gain);
	} else if (arith_type(gain) == MB_ARITH_SF && shape_ok(gain, length)) {
		g = (const float *)read_ptr(gain);
	} else {
		return Qnil;
	}

	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	if (ot == MB_ARITH_SF) {
		if (g) {
			for (size_t i = 0; i < length; i++) o[i] = o[i] * g[i];
		} else {
			for (size_t i = 0; i < length; i++) o[i] = o[i] * gc;
		}
	} else {
		// Numo promotes the real gain to (x, 0) and multiplies in full
		// (CMUL), which keeps its signed zeros and inf * 0 = NaN
		const float zero = 0.0f;
		for (size_t i = 0; i < length; i++) {
			float x = g ? g[i] : gc;
			float a = o[2 * i];
			float b = o[2 * i + 1];
			o[2 * i] = a * x - b * zero;
			o[2 * i + 1] = a * zero + b * x;
		}
	}

	RB_GC_GUARD(gain);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.add_at(out, offset, data, length, ramp) -> out or nil
 *
 * Adds the first +length+ values of +data+ (times the first +length+ of
 * +ramp+, unless +ramp+ is nil) into +out+ from index +offset+, without
 * allocating: the Numo mirror is
 *     d = data[0...length]
 *     d = d * ramp[0...length] if ramp
 *     out[offset...(offset + length)] = out[offset...(offset + length)] + d
 * (Session's player mix, drum kits, master chains), in float steps.  Only
 * for SFloat +out+, +data+, and +ramp+ (contiguous 1D, +out+ writable,
 * +data+ and +ramp+ at least +length+ long, +offset+ + +length+ within
 * +out+, +length+ at least 1, as Numo needs); otherwise returns nil
 * without touching +out+.
 */
static VALUE ruby_add_at(VALUE self, VALUE out, VALUE offset_v, VALUE data, VALUE length_v, VALUE ramp)
{
	if (!RB_INTEGER_TYPE_P(offset_v) || !RB_INTEGER_TYPE_P(length_v)) {
		return Qnil;
	}
	if (arith_type(out) != MB_ARITH_SF || arith_type(data) != MB_ARITH_SF || !writable_contiguous(out)) {
		return Qnil;
	}
	if (RNARRAY_NDIM(data) != 1 || !RTEST(nary_check_contiguous(data))) {
		return Qnil;
	}
	if (!NIL_P(ramp) && (arith_type(ramp) != MB_ARITH_SF || RNARRAY_NDIM(ramp) != 1 || !RTEST(nary_check_contiguous(ramp)))) {
		return Qnil;
	}

	long offset = NUM2LONG(offset_v);
	long length = NUM2LONG(length_v);
	if (offset < 0 || length <= 0 || (size_t)(offset + length) > RNARRAY_SIZE(out) ||
			(size_t)length > RNARRAY_SIZE(data) || (!NIL_P(ramp) && (size_t)length > RNARRAY_SIZE(ramp))) {
		return Qnil;
	}

	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out)) + offset;
	const float *x = (const float *)read_ptr(data);
	if (NIL_P(ramp)) {
		for (long i = 0; i < length; i++) {
			o[i] = o[i] + x[i];
		}
	} else {
		const float *r = (const float *)read_ptr(ramp);
		for (long i = 0; i < length; i++) {
			float t = x[i] * r[i];
			o[i] = o[i] + t;
		}
	}

	RB_GC_GUARD(data);
	RB_GC_GUARD(ramp);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.fill_range(out, from, to, value) -> out or nil
 *
 * out[from...to] = value without allocating, for a real Numeric +value+
 * and an SFloat or DFloat +out+ (contiguous 1D, writable, 0 <= from <= to
 * <= its length); otherwise returns nil without touching +out+.  The value
 * is cast as Numo's store casts it (a C double, then float for SFloat).
 */
static VALUE ruby_fill_range(VALUE self, VALUE out, VALUE from_v, VALUE to_v, VALUE value)
{
	enum mb_arith_type t = arith_type(out);
	if ((t != MB_ARITH_SF && t != MB_ARITH_DF) || !writable_contiguous(out) ||
			!RB_INTEGER_TYPE_P(from_v) || !RB_INTEGER_TYPE_P(to_v) ||
			!(RB_FLOAT_TYPE_P(value) || RB_INTEGER_TYPE_P(value))) {
		return Qnil;
	}

	long from = NUM2LONG(from_v);
	long to = NUM2LONG(to_v);
	if (from < 0 || to < from || (size_t)to > RNARRAY_SIZE(out)) {
		return Qnil;
	}

	double v = NUM2DBL(value);
	char *p = nary_get_pointer_for_write(out) + nary_get_offset(out);
	if (t == MB_ARITH_SF) {
		float *o = (float *)p;
		float f = (float)v;
		for (long i = from; i < to; i++) {
			o[i] = f;
		}
	} else {
		double *o = (double *)p;
		for (long i = from; i < to; i++) {
			o[i] = v;
		}
	}

	return out;
}

// A factor of .accumulate: nil (none), a real Integer/Float (cast to float,
// as Numo casts a scalar for an SFloat), or an SFloat read from +offset+.
// Returns 0 if +f+ isn't one of those or is too short.
static _Bool acc_factor(VALUE f, VALUE offset_v, long length, float *scalar, const float **vec)
{
	*vec = NULL;
	*scalar = 1;
	if (NIL_P(f)) {
		return 1;
	}
	if (RB_INTEGER_TYPE_P(f) || RB_FLOAT_TYPE_P(f)) {
		*scalar = (float)NUM2DBL(f);
		return 2;
	}
	if (arith_type(f) != MB_ARITH_SF || RNARRAY_NDIM(f) != 1 || !RTEST(nary_check_contiguous(f)) || !RB_INTEGER_TYPE_P(offset_v)) {
		return 0;
	}
	long off = NUM2LONG(offset_v);
	if (off < 0 || (size_t)(off + length) > RNARRAY_SIZE(f)) {
		return 0;
	}
	*vec = (const float *)read_ptr(f) + off;
	return 3;
}

/*
 * call-seq: MB::Sound::FastArithmetic.accumulate(out, out_offset, data, data_offset, length, a, a_offset, b, b_offset) -> out or nil
 *
 * Adds +length+ values of +data+ from +data_offset+, each times factor
 * +a+ and then factor +b+, into +out+ from +out_offset+, without
 * allocating.  A factor is nil (skipped), a real Integer or Float (cast to
 * float, as Numo casts a scalar), or an SFloat read from its offset.  The
 * Numo mirror (Session::Buses' deliveries and bus outputs), in the same
 * float steps:
 *     d = data[data_offset, length]
 *     d = d * a[a_offset, length] (or d * a)  if a
 *     d = d * b[b_offset, length] (or d * b)  if b
 *     out[out_offset, length].inplace + d
 * Only for SFloat +out+ and +data+ (contiguous 1D, +out+ writable, ranges
 * inside, +length+ at least 1); otherwise returns nil without writing.
 */
static VALUE ruby_accumulate(int argc, VALUE *argv, VALUE self)
{
	if (argc != 9) {
		rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected 9)", argc);
	}
	VALUE out = argv[0], data = argv[2];
	if (!RB_INTEGER_TYPE_P(argv[1]) || !RB_INTEGER_TYPE_P(argv[3]) || !RB_INTEGER_TYPE_P(argv[4])) {
		return Qnil;
	}
	if (arith_type(out) != MB_ARITH_SF || arith_type(data) != MB_ARITH_SF || !writable_contiguous(out)) {
		return Qnil;
	}
	if (RNARRAY_NDIM(data) != 1 || !RTEST(nary_check_contiguous(data))) {
		return Qnil;
	}
	long oo = NUM2LONG(argv[1]), doff = NUM2LONG(argv[3]), length = NUM2LONG(argv[4]);
	if (oo < 0 || doff < 0 || length <= 0 || (size_t)(oo + length) > RNARRAY_SIZE(out) || (size_t)(doff + length) > RNARRAY_SIZE(data)) {
		return Qnil;
	}

	float as, bs;
	const float *av, *bv;
	_Bool ak = acc_factor(argv[5], argv[6], length, &as, &av);
	_Bool bk = acc_factor(argv[7], argv[8], length, &bs, &bv);
	if (!ak || !bk) {
		return Qnil;
	}
	_Bool use_a = !NIL_P(argv[5]), use_b = !NIL_P(argv[7]);

	float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out)) + oo;
	const float *x = (const float *)read_ptr(data) + doff;
	for (long i = 0; i < length; i++) {
		float t = x[i];
		if (use_a) {
			t = t * (av ? av[i] : as);
		}
		if (use_b) {
			t = t * (bv ? bv[i] : bs);
		}
		o[i] = o[i] + t;
	}

	RB_GC_GUARD(data);
	RB_GC_GUARD(argv[5]);
	RB_GC_GUARD(argv[7]);
	return out;
}

/*
 * call-seq: MB::Sound::FastArithmetic.last_at_least(buf, offset, length, threshold) -> Integer or nil
 *
 * The index (counted from +offset+) of the last of +length+ values of an
 * SFloat +buf+ from +offset+ whose absolute value is at least +threshold+
 * (a Float, compared as Numo's buf.abs.ge(threshold) compares: cast to
 * float), or -1 if none is; nil for anything else (the caller uses Numo).
 */
static VALUE ruby_last_at_least(VALUE self, VALUE buf, VALUE offset_v, VALUE length_v, VALUE threshold)
{
	if (!RB_INTEGER_TYPE_P(offset_v) || !RB_INTEGER_TYPE_P(length_v) || !(RB_FLOAT_TYPE_P(threshold) || RB_INTEGER_TYPE_P(threshold))) {
		return Qnil;
	}
	if (arith_type(buf) != MB_ARITH_SF || RNARRAY_NDIM(buf) != 1 || !RTEST(nary_check_contiguous(buf))) {
		return Qnil;
	}
	long off = NUM2LONG(offset_v), length = NUM2LONG(length_v);
	if (off < 0 || length < 0 || (size_t)(off + length) > RNARRAY_SIZE(buf)) {
		return Qnil;
	}
	float t = (float)NUM2DBL(threshold);
	const float *x = (const float *)read_ptr(buf) + off;
	for (long i = length - 1; i >= 0; i--) {
		if (fabsf(x[i]) >= t) {
			RB_GC_GUARD(buf);
			return LONG2NUM(i);
		}
	}
	RB_GC_GUARD(buf);
	return LONG2NUM(-1);
}

/*
 * call-seq: MB::Sound::FastArithmetic.copy_range(out, out_offset, src, src_offset, length) -> out or nil
 *
 * out[out_offset, length] = src[src_offset, length] without views, for
 * SFloat +out+ and +src+ (contiguous 1D, +out+ writable, ranges inside,
 * +length+ at least 0); otherwise returns nil without writing.
 */
static VALUE ruby_copy_range(VALUE self, VALUE out, VALUE oo_v, VALUE src, VALUE so_v, VALUE length_v)
{
	if (!RB_INTEGER_TYPE_P(oo_v) || !RB_INTEGER_TYPE_P(so_v) || !RB_INTEGER_TYPE_P(length_v)) {
		return Qnil;
	}
	if (arith_type(out) != MB_ARITH_SF || arith_type(src) != MB_ARITH_SF || !writable_contiguous(out)) {
		return Qnil;
	}
	if (RNARRAY_NDIM(src) != 1 || !RTEST(nary_check_contiguous(src))) {
		return Qnil;
	}
	long oo = NUM2LONG(oo_v), so = NUM2LONG(so_v), length = NUM2LONG(length_v);
	if (oo < 0 || so < 0 || length < 0 || (size_t)(oo + length) > RNARRAY_SIZE(out) || (size_t)(so + length) > RNARRAY_SIZE(src)) {
		return Qnil;
	}
	if (length > 0) {
		float *o = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out)) + oo;
		const float *x = (const float *)read_ptr(src) + so;
		memmove(o, x, (size_t)length * sizeof(float));
	}
	RB_GC_GUARD(src);
	return out;
}

void Init_fast_arithmetic(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_arithmetic = rb_define_module_under(sound, "FastArithmetic");

	rb_define_module_function(fast_arithmetic, "product", ruby_product, 3);
	rb_define_module_function(fast_arithmetic, "scale", ruby_scale, 2);
	rb_define_module_function(fast_arithmetic, "mix", ruby_mix, 3);
	rb_define_module_function(fast_arithmetic, "copy", ruby_copy, 2);
	rb_define_module_function(fast_arithmetic, "cast_copy", ruby_cast_copy, 2);
	rb_define_module_function(fast_arithmetic, "ease_plain", ruby_ease_plain, 8);
	rb_define_module_function(fast_arithmetic, "knob_ramp", ruby_knob_ramp, 11);
	rb_define_module_function(fast_arithmetic, "min_max", ruby_min_max, 2);
	rb_define_module_function(fast_arithmetic, "divide", ruby_divide, 2);
	rb_define_module_function(fast_arithmetic, "power", ruby_power, 2);
	rb_define_module_function(fast_arithmetic, "power_fast", ruby_power_fast, 2);
	rb_define_module_function(fast_arithmetic, "circular_read", ruby_circular_read, 4);
	rb_define_module_function(fast_arithmetic, "circular_write", ruby_circular_write, 3);
	rb_define_module_function(fast_arithmetic, "wet_dry", ruby_wet_dry, 5);
	rb_define_module_function(fast_arithmetic, "complex_part", ruby_complex_part, 3);
	rb_define_module_function(fast_arithmetic, "pan", ruby_pan, 5);
	rb_define_module_function(fast_arithmetic, "add_at", ruby_add_at, 5);
	rb_define_module_function(fast_arithmetic, "fill_range", ruby_fill_range, 4);
	rb_define_module_function(fast_arithmetic, "accumulate", ruby_accumulate, -1);
	rb_define_module_function(fast_arithmetic, "last_at_least", ruby_last_at_least, 4);
	rb_define_module_function(fast_arithmetic, "copy_range", ruby_copy_range, 5);
}
