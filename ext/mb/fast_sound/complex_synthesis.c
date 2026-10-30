/*
 * The complex synthesis functions as Ruby methods, kept aside from the
 * live paths (omnibus18, 2026-10-30; the maintainer: "Keep and move the
 * complex synthesis functions aside because I want to blog or video about
 * them at some point").
 *
 * The naive complex (analytic) square, triangle, and ramp shapes of
 * FastSound's oscillators and the plan executor (OSC_COMPLEX_SQUARE,
 * OSC_COMPLEX_TRIANGLE, OSC_COMPLEX_RAMP in mb_osc_shapes.h's osc_sample)
 * are built from these integrals, defined in mb_osc_shapes.h:
 * - csc_int(z): an antiderivative of csc(z), -2 conj(atanh(e^iz)) + pi/2i
 *   (the square).
 * - csc_int_int(x): its integral along the real line, from a lookup table
 *   of the integral of 2 atanh(e^ix) (the triangle).
 * - cot_int(z): an antiderivative of cot(z), -2/pi log(e^iz + i) + i (the
 *   ramp).
 * The Ruby references are mb-math's MB::M.csc_int, .csc_int_int, and
 * .cot_int (what Tone's Ruby mirror uses); spec/ext/mb/fast_sound/
 * complex_synthesis_spec.rb compares them.  Until 2026-10-30 these were
 * FastSound.csc_int, .csc_int_int, and .cot_int, with no callers.
 *
 * (C)2021 Mike Bourgeous
 */
#include <complex.h>
#include <math.h>

#include <ruby.h>

#include "mb_osc_shapes.h"
#include "complex_synthesis.h"

static double complex cs_num_to_complex(VALUE z)
{
	if (RB_TYPE_P(z, T_COMPLEX)) {
		return NUM2DBL(rb_complex_real(z)) + I * NUM2DBL(rb_complex_imag(z));
	}
	return NUM2DBL(z);
}

static VALUE cs_complex_to_num(double complex z)
{
	return rb_dbl_complex_new(creal(z), cimag(z));
}

/*
 * call-seq:
 *   MB::FastSound::ComplexSynthesis.csc_int(z) -> Complex
 *
 * An antiderivative of csc(+z+) (see the file comment).
 */
static VALUE ruby_csc_int(VALUE self, VALUE z)
{
	return cs_complex_to_num(csc_int(cs_num_to_complex(z)));
}

/*
 * call-seq:
 *   MB::FastSound::ComplexSynthesis.csc_int_int(x) -> Complex
 *
 * An antiderivative of csc_int along the real line at the real part of +x+
 * (see the file comment).
 */
static VALUE ruby_csc_int_int(VALUE self, VALUE x)
{
	return cs_complex_to_num(csc_int_int(creal(cs_num_to_complex(x))));
}

/*
 * call-seq:
 *   MB::FastSound::ComplexSynthesis.cot_int(z) -> Complex
 *
 * An antiderivative of cot(+z+) whose imaginary part is a ramp (see the
 * file comment).
 */
static VALUE ruby_cot_int(VALUE self, VALUE z)
{
	return cs_complex_to_num(cot_int(cs_num_to_complex(z)));
}

void mb_complex_synthesis_init(VALUE fast_sound)
{
	VALUE mod = rb_define_module_under(fast_sound, "ComplexSynthesis");
	rb_define_module_function(mod, "csc_int", ruby_csc_int, 1);
	rb_define_module_function(mod, "csc_int_int", ruby_csc_int_int, 1);
	rb_define_module_function(mod, "cot_int", ruby_cot_int, 1);
}
