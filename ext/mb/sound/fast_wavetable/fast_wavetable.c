/*
 * Low-level implementation of wavetable sampling.
 * (C)2025 Mike Bourgeous
 */
#include <samplerate.h>

#include <ruby.h>

#include "numo/narray.h"

static VALUE fast_wavetable_module;

static ID sym_cast;

static ID sym_cubic;
static ID sym_linear;

static ID sym_wrap;
static ID sym_clamp;
static ID sym_zero;
static ID sym_bounce;

enum wrapping_mode {
	MODE_WRAP,
	MODE_BOUNCE,
	MODE_ZERO,
	MODE_CLAMP,
};

static inline double fetch_wrap(float *wavetable, ssize_t columns, ssize_t idx)
{
	if (idx < 0) {
		idx = idx % columns + columns;
	} else if (idx >= columns) {
		idx = idx % columns;
	}

	return wavetable[idx];
}

static inline double fetch_bounce(float *wavetable, ssize_t columns, ssize_t idx)
{
	if (columns == 1) {
		return wavetable[0];
	}

	idx = idx % (columns * 2 - 2);

	if (idx < 0) {
		idx = idx + columns * 2 - 2;
	}

	if (idx >= columns - 1) {
		idx = columns - (2 + idx);
	}

        return wavetable[idx];
}

static inline double fetch_clamp(float *wavetable, ssize_t columns, ssize_t idx)
{
	if (idx < 0) {
		return wavetable[0];
	} else if (idx >= columns) {
		return wavetable[columns - 1];
	} else {
		return wavetable[idx];
	}
}

static inline double fetch_zero(float *wavetable, ssize_t columns, ssize_t idx)
{
	if (idx < 0 || idx >= columns) {
		return 0;
	} else {
		return wavetable[idx];
	}
}

// Interpolated 2D lookup.
// Port of Ruby outer_linear and inner_lookup.
static double outer_linear(float *wavetable, size_t rows, size_t columns, double number, double phase, enum wrapping_mode wrap)
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

// Cubic interpolated lookup
static double outer_cubic(float *wavetable, size_t rows, size_t columns, double number, double phase, enum wrapping_mode wrap)
{
	rb_raise(rb_eNotImpError, "TODO: cubic C");
}

// Returns C enum for the wrapping mode of the given Ruby symbol, or raises an
// error if it's not valid.
static enum wrapping_mode get_wrapping_mode(ID wrap)
{
	if (wrap == sym_wrap) {
		return MODE_WRAP;
	}

	if (wrap == sym_bounce) {
		return MODE_BOUNCE;
	}

	if (wrap == sym_zero) {
		return MODE_ZERO;
	}

	if (wrap == sym_clamp) {
		return MODE_CLAMP;
	}

	rb_raise(rb_eArgError, "Unsupported wrapping mode: %"PRIsVALUE, ID2SYM(wrap));
}

// wavetable - a 2D Numo::SFloat (TODO: other types)
// number - a numeric from 0..1 (with wrapping)
// phase - a numeric from 0..1 (with wrapping)
// wrap - :wrap, :bounce, :clamp, or :zero
static VALUE ruby_outer_linear(VALUE self, VALUE wavetable, VALUE number, VALUE phase, VALUE wrap)
{
	enum wrapping_mode wrapmode = get_wrapping_mode(SYM2ID(wrap));

	double rho = NUM2DBL(number);
	double phi = NUM2DBL(phase);

	wavetable = rb_funcall(numo_cSFloat, sym_cast, 1, wavetable);

	if (RNARRAY_NDIM(wavetable) != 2) {
		rb_raise(rb_eArgError, "Wavetable must be a 2D Numo::SFloat");
	}

	float *ptr = (float *)(nary_get_pointer_for_read(wavetable) + nary_get_offset(wavetable));

	VALUE ret = DBL2NUM(outer_linear(ptr, RNARRAY_SHAPE(wavetable)[0], RNARRAY_SHAPE(wavetable)[1], rho, phi, wrapmode));
	RB_GC_GUARD(wavetable);
	return ret;
}

// Overwrites phase with the result of wavetable lookup in the given table,
// using the given number array.
//
// wavetable - a 2D Numo::SFloat
// number - a 1D Numo::SFloat from 0..1 (with wrapping)
// phase - a 1D Numo::SFloat from 0..1 (with wrapping)
static VALUE ruby_wavetable_lookup(VALUE self, VALUE wavetable, VALUE number, VALUE phase, VALUE lookup, VALUE wrap)
{
	ID symlookup = SYM2ID(lookup);
	enum wrapping_mode wrapmode = get_wrapping_mode(SYM2ID(wrap));

	wavetable = rb_funcall(numo_cSFloat, sym_cast, 1, wavetable);
	number = rb_funcall(numo_cSFloat, sym_cast, 1, number);
	phase = rb_funcall(numo_cSFloat, sym_cast, 1, phase);

	if (RNARRAY_NDIM(wavetable) != 2 || !RTEST(nary_check_contiguous(wavetable))) {
		rb_raise(rb_eArgError, "Wavetable must be a contiguous 2D Numo::SFloat");
	}

	if (RNARRAY_NDIM(number) != 1 || !RTEST(nary_check_contiguous(number)) ||
			RNARRAY_NDIM(phase) != 1 || !RTEST(nary_check_contiguous(phase))) {
		rb_raise(rb_eArgError, "Number and phase must be continuous 1D Numo::SFloat");
	}

	float *table_ptr = (float *)(nary_get_pointer_for_read(wavetable) + nary_get_offset(wavetable));
	float *rho_ptr = (float *)(nary_get_pointer_for_read(number) + nary_get_offset(number));
	float *phi_ptr = (float *)(nary_get_pointer_for_read_write(phase) + nary_get_offset(phase));

	size_t length = RNARRAY_SHAPE(phase)[0];
	if (RNARRAY_SHAPE(number)[0] != length) {
		rb_raise(rb_eArgError, "Number and phase must be the same length");
	}

	size_t rows = RNARRAY_SHAPE(wavetable)[0];
	size_t cols = RNARRAY_SHAPE(wavetable)[1];
	if (symlookup == sym_linear) {
		for (size_t i = 0; i < length; i++) {
			phi_ptr[i] = outer_linear(table_ptr, rows, cols, rho_ptr[i], phi_ptr[i], wrapmode);
		}
	} else if (symlookup == sym_cubic) {
		for (size_t i = 0; i < length; i++) {
			phi_ptr[i] = outer_cubic(table_ptr, rows, cols, rho_ptr[i], phi_ptr[i], wrapmode);
		}
	} else {
		rb_raise(rb_eArgError, "Invalid lookup mode %"PRIsVALUE, lookup);
	}

	RB_GC_GUARD(number);
	RB_GC_GUARD(phase);
	RB_GC_GUARD(wavetable);

	return phase;
}

void Init_fast_wavetable(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	fast_wavetable_module = rb_define_module_under(sound, "FastWavetable");

	rb_define_module_function(fast_wavetable_module, "outer_linear", ruby_outer_linear, 4);
	rb_define_module_function(fast_wavetable_module, "wavetable_lookup", ruby_wavetable_lookup, 5);

	sym_cast = rb_intern("cast");
	sym_cubic = rb_intern("cubic");
	sym_linear = rb_intern("linear");
	sym_wrap = rb_intern("wrap");
	sym_bounce = rb_intern("bounce");
	sym_clamp = rb_intern("clamp");
	sym_zero = rb_intern("zero");
}
