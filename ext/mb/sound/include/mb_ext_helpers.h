/*
 * Helpers shared by the purpose-specific C extensions (fast_synth,
 * fast_clip): NArray buffer checks and signal inputs that may be a Numeric
 * or an NArray.  Each extension's extconf.rb adds this directory to the
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

// Replaces *narray with a contiguous 1D SComplex NArray.
static inline void mb_ensure_scomplex(VALUE *narray)
{
	int dim = RNARRAY_NDIM(*narray);
	if (dim != 1) {
		rb_raise(rb_eArgError, "Only 1D NArrays may be processed (got %d dimensions)", dim);
	}

	*narray = rb_funcall(numo_cSComplex, rb_intern("cast"), 1, *narray);

	if (!RTEST(nary_check_contiguous(*narray))) {
		*narray = nary_dup(*narray);
	}
}

// Reads a signal input: a Numeric (into *scalar, with *ptr set to NULL) or an
// NArray of +length+ values (cast to SComplex, whose real parts the caller
// reads through *ptr; *scalar gets the first).  nil is 0.  +name+ is for
// errors.
static inline void mb_read_signal_input(VALUE *value, size_t length, const char *name, double *scalar, complex float **ptr)
{
	*ptr = NULL;

	if (CLASS_OF(*value) == numo_cDFloat || CLASS_OF(*value) == numo_cSFloat || CLASS_OF(*value) == numo_cSComplex || CLASS_OF(*value) == numo_cDComplex) {
		if (RNARRAY_SHAPE(*value)[0] != length) {
			rb_raise(rb_eArgError, "%s array length does not match sample buffer length", name);
		}

		mb_ensure_scomplex(value);
		*ptr = (complex float *)(nary_get_pointer_for_read(*value) + nary_get_offset(*value));
		*scalar = crealf((*ptr)[0]);
	} else if (RTEST(*value)) {
		*scalar = NUM2DBL(*value);
	} else {
		*scalar = 0;
	}
}

// Returns the float data of an NArray already made contiguous.
static inline float *mb_sfloat_ptr(VALUE narray)
{
	return (float *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));
}

#endif
