/*
 * Low-level implementation of wavetable sampling.
 * (C)2025 Mike Bourgeous
 */
#include <samplerate.h>

#include <ruby.h>

#include "numo/narray.h"

static VALUE fast_wavetable_module;

static ID sym_cast;

// Interpolated 2D lookup.
// Port of Ruby outer_lookup and inner_lookup.
static double outer_lookup(float *wavetable, size_t rows, size_t columns, double number, double phase)
{
	double frow = (number >= 0 ? fmod(number, 1) : fmod(number, 1) + 1) * rows;
	size_t row1 = (size_t)floor(frow) % rows;
	size_t row2 = (size_t)ceil(frow) % rows;
	size_t offset1 = columns * row1;
	size_t offset2 = columns * row2;
	double rowratio = frow - row1;

	double fcol = (phase >= 0 ? fmod(phase, 1) : fmod(phase, 1) + 1) * columns;
	size_t col1 = (size_t)floor(fcol) % columns;
	size_t col2 = (size_t)ceil(fcol) % columns;
	double colratio = fcol - col1;

	double val1l = wavetable[offset1 + col1];
	double val1r = wavetable[offset1 + col2];
	double val2l = wavetable[offset2 + col1];
	double val2r = wavetable[offset2 + col2];

	double valtop = val1r * colratio + val1l * (1.0 - colratio);
	double valbot = val2r * colratio + val2l * (1.0 - colratio);

	return valbot * rowratio + valtop * (1.0 - rowratio);
}

// wavetable - a 2D Numo::SFloat (TODO: other types)
// number - a numeric from 0..1 (with wrapping)
// phase - a numeric from 0..1 (with wrapping)
static VALUE ruby_outer_lookup(VALUE self, VALUE wavetable, VALUE number, VALUE phase)
{
	double rho = NUM2DBL(number);
	double phi = NUM2DBL(phase);

	wavetable = rb_funcall(numo_cSFloat, sym_cast, 1, wavetable);

	if (RNARRAY_NDIM(wavetable) != 2) {
		rb_raise(rb_eArgError, "Wavetable must be a 2D Numo::SFloat");
	}

	float *ptr = (float *)(nary_get_pointer_for_read(wavetable) + nary_get_offset(wavetable));

	return DBL2NUM(outer_lookup(ptr, RNARRAY_SHAPE(wavetable)[0], RNARRAY_SHAPE(wavetable)[1], rho, phi));
}

static VALUE ruby_wavetable_lookup(VALUE self, VALUE wavetable, VALUE number, VALUE phase)
{
	rb_raise(rb_eNotImpError, "TODO: implement wavetable lookup loop");
}

void Init_fast_wavetable(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	fast_wavetable_module = rb_define_module_under(sound, "FastWavetable");

	rb_define_module_function(fast_wavetable_module, "outer_lookup", ruby_outer_lookup, 3);
	rb_define_module_function(fast_wavetable_module, "wavetable_lookup", ruby_wavetable_lookup, 3);

	sym_cast = rb_intern("cast");
}
