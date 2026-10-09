/*
 * MB::Sound::FastControl: control-signal kernels.
 *
 * smooth(x, out, from, to, state, ring1, ring2): MB::Sound::Notes::Smoother's
 * filter over x[from...to] into out[from...to] (SFloat): two cascaded moving
 * averages of n1 = ring1.length and n2 = ring2.length samples (a triangle
 * kernel of n1 + n2 - 1 samples), as running sums of the deviation from a
 * reference value.  +state+ is a DFloat [ref, last, sum1, sum2, p1, p2,
 * since], updated in place: +last+ the latest input, +since+ the samples
 * since the input last changed.  Once the input has held for the kernel's
 * length (since >= n1 + n2 - 2) the output is the input exactly, and the
 * next change restarts the sums at zero with the held value as the
 * reference, so rounding never accumulates across settled stretches.
 *
 * The Ruby mirror (Notes::Smoother.smooth_ruby) gives exactly the same
 * samples (specs check it), so keep the operations identical; built with
 * -ffp-contract=off like the other kernels (there are no products to fuse
 * here, but the flag keeps that true if the code changes).
 */

#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_smooth.h"

#define STATE_LENGTH 7
#define ADAPTIVE_STATE_LENGTH 8

// Checks that +narray+ is a writable contiguous 1D NArray of class +klass+
// with at least +min+ values; returns its length.
static size_t check_array(VALUE narray, VALUE klass, size_t min, const char *name)
{
	if (CLASS_OF(narray) != klass || RNARRAY_NDIM(narray) != 1) {
		rb_raise(rb_eArgError, "%s must be a 1D %s", name, klass == numo_cSFloat ? "SFloat" : "DFloat");
	}
	if (!RTEST(nary_check_contiguous(narray))) {
		rb_raise(rb_eArgError, "%s must be contiguous", name);
	}

	size_t length = RNARRAY_SHAPE(narray)[0];
	if (length < min) {
		rb_raise(rb_eArgError, "%s must have at least %zu values (got %zu)", name, min, length);
	}

	return length;
}

static double *dfloat_ptr(VALUE narray)
{
	return (double *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));
}

static VALUE ruby_smooth(VALUE self, VALUE x, VALUE out, VALUE from_v, VALUE to_v, VALUE state, VALUE ring1, VALUE ring2)
{
	size_t length = check_array(x, numo_cSFloat, 0, "The input");
	if (check_array(out, numo_cSFloat, 0, "The output") != length) {
		rb_raise(rb_eArgError, "The output must have as many values as the input");
	}
	check_array(state, numo_cDFloat, STATE_LENGTH, "The state");
	size_t n1 = check_array(ring1, numo_cDFloat, 1, "Ring 1");
	size_t n2 = check_array(ring2, numo_cDFloat, 1, "Ring 2");
	rb_check_frozen(out);
	rb_check_frozen(state);
	rb_check_frozen(ring1);
	rb_check_frozen(ring2);

	long from = NUM2LONG(from_v);
	long to = NUM2LONG(to_v);
	if (from < 0 || to < from || (size_t)to > length) {
		rb_raise(rb_eRangeError, "Range %ld...%ld is outside the %zu-sample buffer", from, to, length);
	}

	const float *xp = (const float *)(nary_get_pointer_for_read(x) + nary_get_offset(x));
	float *op = mb_sfloat_ptr(out);
	double *st = dfloat_ptr(state);
	double *r1 = dfloat_ptr(ring1);
	double *r2 = dfloat_ptr(ring2);

	if (mb_smooth_run(xp, op, from, to, st, r1, n1, r2, n2) != 0) {
		rb_raise(rb_eArgError, "Ring positions %zu and %zu are outside rings of %zu and %zu", (size_t)st[4], (size_t)st[5], n1, n2);
	}

	return out;
}

static VALUE ruby_adaptive(VALUE self, VALUE x, VALUE out, VALUE from_v, VALUE to_v, VALUE state)
{
	size_t length = check_array(x, numo_cSFloat, 0, "The input");
	if (check_array(out, numo_cSFloat, 0, "The output") != length) {
		rb_raise(rb_eArgError, "The output must have as many values as the input");
	}
	if (check_array(state, numo_cDFloat, ADAPTIVE_STATE_LENGTH, "The state") != ADAPTIVE_STATE_LENGTH) {
		rb_raise(rb_eArgError, "The adaptive state must have %d values", ADAPTIVE_STATE_LENGTH);
	}
	rb_check_frozen(out);
	rb_check_frozen(state);

	long from = NUM2LONG(from_v);
	long to = NUM2LONG(to_v);
	if (from < 0 || to < from || (size_t)to > length) {
		rb_raise(rb_eRangeError, "Range %ld...%ld is outside the %zu-sample buffer", from, to, length);
	}

	const float *xp = (const float *)(nary_get_pointer_for_read(x) + nary_get_offset(x));
	mb_adaptive_run(xp, mb_sfloat_ptr(out), from, to, dfloat_ptr(state));

	return out;
}

void Init_fast_control(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_control = rb_define_module_under(sound, "FastControl");

	rb_define_module_function(fast_control, "smooth", ruby_smooth, 7);
	rb_define_module_function(fast_control, "adaptive", ruby_adaptive, 5);
}
