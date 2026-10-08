/*
 * Helpers shared by the purpose-specific C extensions (fast_synth,
 * fast_clip, fast_filter, ...): NArray buffer checks, signal inputs that may
 * be a Numeric or an NArray, state Array reads, and math approximations
 * that give the same results on every libm (and in the Ruby mirrors).  Each extension's extconf.rb adds this directory to the
 * include path.  Everything is static inline, so an extension compiles only
 * what it uses (and -Wunused doesn't complain about the rest).
 *
 * (fast_sound.c has older copies of some of these under other names.)
 */
#ifndef MB_EXT_HELPERS_H
#define MB_EXT_HELPERS_H

#include <math.h>
#include <complex.h>

#include <ruby.h>
#include "numo/narray.h"

// Wraps +x+ to 0...+y+ like Ruby's % operator (not fmod, which keeps the
// sign of +x+).
static inline double mb_wrap(double x, double y)
{
	return x - y * floor(x / y);
}

// Replaces *narray with a contiguous, inplace 1D SFloat NArray (a copy unless
// it already was one and was marked inplace), storing in *was_inplace
// whether the caller's NArray will be written directly.
static inline void mb_ensure_inplace_sfloat(VALUE *narray, _Bool *was_inplace)
{
	int dim = RNARRAY_NDIM(*narray);
	if (dim != 1) {
		rb_raise(rb_eArgError, "Only 1D NArrays may be processed (got %d dimensions)", dim);
	}

	_Bool prior_inplace = !!TEST_INPLACE(*narray);

	*narray = rb_funcall(numo_cSFloat, rb_intern("cast"), 1, *narray);

	if (!RTEST(nary_check_contiguous(*narray)) || !prior_inplace) {
		*narray = nary_dup(*narray);
		SET_INPLACE(*narray);
		prior_inplace = 0;
	}

	if (was_inplace != NULL) {
		*was_inplace = prior_inplace;
	}
}

// Reads a signal input: a Numeric (into *scalar, with *ptr set to NULL) or an
// NArray of +length+ values, whose real parts the caller reads as float32
// values (*ptr)[i * *step] (*scalar gets the first).  Contiguous SFloat
// (step 1) and SComplex (step 2, the real parts) NArrays are read where they
// are, so the usual inputs allocate nothing; others (DFloat, DComplex,
// non-contiguous views) are cast to SFloat or SComplex first, which rounds
// to float32 the same way.  nil is 0.  +name+ is for errors.
static inline void mb_read_signal_input(VALUE *value, size_t length, const char *name, double *scalar, const float **ptr, size_t *step)
{
	*ptr = NULL;
	*step = 1;

	VALUE cls = CLASS_OF(*value);
	if (cls == numo_cDFloat || cls == numo_cSFloat || cls == numo_cSComplex || cls == numo_cDComplex) {
		if (RNARRAY_NDIM(*value) != 1) {
			rb_raise(rb_eArgError, "%s array must be 1D (got %d dimensions)", name, RNARRAY_NDIM(*value));
		}
		if (RNARRAY_SHAPE(*value)[0] != length) {
			rb_raise(rb_eArgError, "%s array length does not match sample buffer length", name);
		}

		_Bool is_complex = cls == numo_cSComplex || cls == numo_cDComplex;
		VALUE target = is_complex ? numo_cSComplex : numo_cSFloat;
		if (cls != target) {
			*value = rb_funcall(target, rb_intern("cast"), 1, *value);
		}
		if (!RTEST(nary_check_contiguous(*value))) {
			*value = nary_dup(*value);
		}

		*step = is_complex ? 2 : 1;
		*ptr = (const float *)(nary_get_pointer_for_read(*value) + nary_get_offset(*value));
		*scalar = length > 0 ? (*ptr)[0] : 0;
	} else if (RTEST(*value)) {
		*scalar = NUM2DBL(*value);
	} else {
		*scalar = 0;
	}
}

// A signal input opened by mb_signal_input: a Numeric (+scalar+, with +ptr+
// NULL) or float32 values ptr[i * step] (see mb_read_signal_input).
struct mb_signal {
	double scalar;
	const float *ptr;
	size_t step;
};

// Opens *value (a Numeric, nil, or an NArray of +length+ values; replaced
// by a cast copy if needed, so keep it GC-guarded) as a signal input.
static inline void mb_signal_input(VALUE *value, size_t length, const char *name, struct mb_signal *sig)
{
	mb_read_signal_input(value, length, name, &sig->scalar, &sig->ptr, &sig->step);
}

// The signal's value at sample +i+ (the scalar for a Numeric).
static inline double mb_signal_at(const struct mb_signal *sig, size_t i)
{
	return sig->ptr ? sig->ptr[i * sig->step] : sig->scalar;
}

// Element +idx+ of a Ruby Array of numbers as a double, 0 if not finite
// (filter states read back from Ruby).
static inline double mb_finite_entry(VALUE ary, long idx)
{
	double v = NUM2DBL(rb_ary_entry(ary, idx));
	return isfinite(v) ? v : 0.0;
}

// tan(w) for 0 <= w < pi/2: a [5/4] Pade approximation of tan(w / 2) (good
// to about 1e-16 at pi/4), then the double-angle formula.  Relative error
// under 4e-7 up to 0.49 pi.  Only + - * /, so every platform and the Ruby
// mirror (MB::Sound::Filter::FourPole.tan) agree exactly (build with
// -ffp-contract=off).  Used by the four-pole and SVF filter kernels.
static inline double mb_tan_pade(double w)
{
	double y = w * 0.5;
	double y2 = y * y;
	double t = y * (945.0 - 105.0 * y2 + y2 * y2) / (945.0 - 420.0 * y2 + 15.0 * y2 * y2);
	return 2.0 * t / (1.0 - t * t);
}

// Returns the float data of an NArray already made contiguous.
static inline float *mb_sfloat_ptr(VALUE narray)
{
	return (float *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));
}

#endif
