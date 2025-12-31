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

static inline double fetch_wrap(float *wavetable, ssize_t columns, ssize_t idx)
{
	if (idx < 0) {
		idx = idx % columns + columns;
	}

	if (idx >= columns) {
		idx = idx % columns;
	}

	return wavetable[idx];
}

static inline double fetch_bounce(float *wavetable, ssize_t columns, ssize_t idx)
{
	if (columns <= 1) {
		return wavetable[0];
	}

	ssize_t looplen = columns * 2 - 2;

	idx = llabs(idx) % looplen;
	if (idx > columns - 1) {
		idx = looplen - idx;
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

// Port of Ruby fetch_oob from mb-math
static inline double fetch_oob(float *wavetable, ssize_t columns, ssize_t idx, enum wrapping_mode wrap)
{
	switch(wrap) {
		case MODE_WRAP:
			return fetch_wrap(wavetable, columns, idx);

		case MODE_BOUNCE:
			return fetch_bounce(wavetable, columns, idx);

		case MODE_CLAMP:
			return fetch_clamp(wavetable, columns, idx);

		case MODE_ZERO:
			return fetch_zero(wavetable, columns, idx);

		default:
			fprintf(stderr, "BUG: invalid wrapping mode %d\n", wrap);
			return 0;
	}
}

static VALUE ruby_fetch_oob(VALUE self, VALUE narray, VALUE idx, VALUE mode)
{
	enum wrapping_mode wrap = get_wrapping_mode(SYM2ID(mode));

	narray = rb_funcall(numo_cSFloat, sym_cast, 1, narray);
	float *ptr = (float *)(nary_get_pointer_for_read(narray) + nary_get_offset(narray));

	ssize_t columns = RNARRAY_SHAPE(narray)[RNARRAY_NDIM(narray) - 1];

	if (columns == 0) {
		return Qnil;
	}

	VALUE result = DBL2NUM(fetch_oob(ptr, columns, NUM2LL(idx), wrap));

	RB_GC_GUARD(narray);

	return result;
}

// Uses the slope from y_1 to y1, the slope from y0 to y2, y0, and y1, to fit a
// cubic to the given points.  Returns the value of the cubic at x=blend.
//
// Ported from mb-math (but taking four points instead of two slopes & points)
static double cubic_interp(double y_1, double y0, double y1, double y2, double blend)
{
	double d0 = (y1 - y_1) / 2; // divide by 2 because they are 2 units apart in X
	double d1 = (y2 - y0) / 2;
	double a = 2 * (y0 - y1) + d0 + d1;
	double b = 3 * (y1 - y0) - 2 * d0 - d1;
	double c = d0;
	double d = y0;

	return a * blend*blend*blend + b * blend*blend + c * blend + d;
}

static VALUE ruby_cubic_coeffs(VALUE self, VALUE y_1r, VALUE y0r, VALUE y1r, VALUE y2r)
{
	double y_1 = NUM2DBL(y_1r);
	double y0 = NUM2DBL(y0r);
	double y1 = NUM2DBL(y1r);
	double y2 = NUM2DBL(y2r);
	double d0 = (y1 - y_1) / 2; // divide by 2 because they are 2 units apart in X
	double d1 = (y2 - y0) / 2;
	double a = 2 * (y0 - y1) + d0 + d1;
	double b = 3 * (y1 - y0) - 2 * d0 - d1;
	double c = d0;
	double d = y0;

	return rb_ary_new_from_args(4, DBL2NUM(a), DBL2NUM(b), DBL2NUM(c), DBL2NUM(d));
}

static VALUE ruby_cubic_interp(VALUE self, VALUE y_1, VALUE y0, VALUE y1, VALUE y2, VALUE blend)
{
	return DBL2NUM(cubic_interp(
				NUM2DBL(y_1),
				NUM2DBL(y0),
				NUM2DBL(y1),
				NUM2DBL(y2),
				NUM2DBL(blend)
				));
}

// Interpolated 2D lookup.
// Port of Ruby outer_linear and inner_lookup.
static double outer_linear(float *wavetable, size_t rows, size_t columns, double number, double phase, enum wrapping_mode wrap)
{
	double frow = (number >= 0 ? fmod(number, 1) : fmod(number, 1) + 1) * rows;
	ssize_t row1 = (ssize_t)floor(frow) % rows;
	ssize_t row2 = (row1 + 1) % rows;
	ssize_t offset1 = columns * row1;
	ssize_t offset2 = columns * row2;
	double rowratio = frow - row1;

	double fcol = phase * columns;
	ssize_t col1 = (ssize_t)floor(fcol);
	ssize_t col2 = col1 + 1;
	double colratio = fcol - col1;

	double val1l = fetch_oob(wavetable + offset1, columns, col1, wrap);
	double val1r = fetch_oob(wavetable + offset1, columns, col2, wrap);
	double val2l = fetch_oob(wavetable + offset2, columns, col1, wrap);
	double val2r = fetch_oob(wavetable + offset2, columns, col2, wrap);

	double valtop = val1r * colratio + val1l * (1.0 - colratio);
	double valbot = val2r * colratio + val2l * (1.0 - colratio);

	return valbot * rowratio + valtop * (1.0 - rowratio);
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

// Cubic interpolated 2D lookup.
static double outer_cubic(float *wavetable, size_t rows, size_t columns, double number, double phase, enum wrapping_mode wrap)
{
	double frow = (number >= 0 ? fmod(number, 1) : fmod(number, 1) + 1) * rows;
	ssize_t row1 = (ssize_t)floor(frow) % rows;
	ssize_t row2 = (row1 + 1) % rows;
	ssize_t offset1 = columns * row1;
	ssize_t offset2 = columns * row2;
	double rowratio = frow - row1;

	double fcol = phase * columns;
	ssize_t col1 = floor(fcol);
	double colratio = fcol - col1;

	double valtop = cubic_interp(
			fetch_oob(wavetable + offset1, columns, col1 - 1, wrap),
			fetch_oob(wavetable + offset1, columns, col1, wrap),
			fetch_oob(wavetable + offset1, columns, col1 + 1, wrap),
			fetch_oob(wavetable + offset1, columns, col1 + 2, wrap),
			colratio
			);
	double valbot = cubic_interp(
			fetch_oob(wavetable + offset2, columns, col1 - 1, wrap),
			fetch_oob(wavetable + offset2, columns, col1, wrap),
			fetch_oob(wavetable + offset2, columns, col1 + 1, wrap),
			fetch_oob(wavetable + offset2, columns, col1 + 2, wrap),
			colratio
			);

	return valbot * rowratio + valtop * (1.0 - rowratio);
}

// wavetable - a 2D Numo::SFloat (TODO: other types)
// number - a numeric from 0..1 (with wrapping)
// phase - a numeric from 0..1 (with wrapping)
// wrap - :wrap, :bounce, :clamp, or :zero
static VALUE ruby_outer_cubic(VALUE self, VALUE wavetable, VALUE number, VALUE phase, VALUE wrap)
{
	enum wrapping_mode wrapmode = get_wrapping_mode(SYM2ID(wrap));

	double rho = NUM2DBL(number);
	double phi = NUM2DBL(phase);

	wavetable = rb_funcall(numo_cSFloat, sym_cast, 1, wavetable);

	if (RNARRAY_NDIM(wavetable) != 2) {
		rb_raise(rb_eArgError, "Wavetable must be a 2D Numo::SFloat");
	}

	float *ptr = (float *)(nary_get_pointer_for_read(wavetable) + nary_get_offset(wavetable));

	VALUE ret = DBL2NUM(outer_cubic(ptr, RNARRAY_SHAPE(wavetable)[0], RNARRAY_SHAPE(wavetable)[1], rho, phi, wrapmode));
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

	rb_define_module_function(fast_wavetable_module, "fetch_oob", ruby_fetch_oob, 3);
	rb_define_module_function(fast_wavetable_module, "cubic_coeffs", ruby_cubic_coeffs, 4);
	rb_define_module_function(fast_wavetable_module, "cubic_interp", ruby_cubic_interp, 5);
	rb_define_module_function(fast_wavetable_module, "outer_linear", ruby_outer_linear, 4);
	rb_define_module_function(fast_wavetable_module, "outer_cubic", ruby_outer_cubic, 4);
	rb_define_module_function(fast_wavetable_module, "wavetable_lookup", ruby_wavetable_lookup, 5);

	sym_cast = rb_intern("cast");
	sym_cubic = rb_intern("cubic");
	sym_linear = rb_intern("linear");
	sym_wrap = rb_intern("wrap");
	sym_bounce = rb_intern("bounce");
	sym_clamp = rb_intern("clamp");
	sym_zero = rb_intern("zero");
}
