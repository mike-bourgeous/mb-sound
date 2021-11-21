#include <math.h>
#include <complex.h>

#include <ruby.h>

static VALUE sym_osc_sine;
static VALUE sym_osc_complex_sine;
static VALUE sym_osc_triangle;
static VALUE sym_osc_complex_triangle;
static VALUE sym_osc_square;
static VALUE sym_osc_complex_square;
static VALUE sym_osc_ramp;
static VALUE sym_osc_complex_ramp;
static VALUE sym_osc_gauss;
static VALUE sym_osc_parabola;

enum wave_types {
	OSC_SINE,
	OSC_COMPLEX_SINE,
	OSC_TRIANGLE,
	OSC_COMPLEX_TRIANGLE,
	OSC_SQUARE,
	OSC_COMPLEX_SQUARE,
	OSC_RAMP,
	OSC_COMPLEX_RAMP,
	OSC_GAUSS,
	OSC_PARABOLA,
};

static float complex csc_int(float complex z)
{
	return -2.0f * conjf(catanhf(cexpf(I * z))) + M_PI_2 * I;
}

static float complex csc_int_int(float complex z)
{

}

static float complex synth_sample(enum wave_types wave_type, float phi)
{
	switch(wave_type) {
		case OSC_SINE:
			return sinf(phi);

		case OSC_COMPLEX_SINE:
			return cexpf(I * (phi - M_PI / 2));

		case OSC_TRIANGLE:
			if (phi < M_PI_2) {
				// Rise from 0..1 in 0..pi/2
				return phi * M_2_PI;
			} else if (phi < (M_PI + M_PI_2)) {
				// Fall from 1..-1 in pi/2..3pi/2
				return 2.0f - phi * M_2_PI;
			} else {
				// Rise from -1.0 in 3pi/2..2pi
				return phi * M_2_PI - 4.0f;
			}

		case OSC_COMPLEX_TRIANGLE:
			// see lib/mb/sound/oscillator.rb
			return csc_int_int(phi + M_PI_2) * I / 2.46740110027234;

		case OSC_SQUARE:
			// TODO: Normalize for RMS instead of peak?
			if (phi < M_PI) {
				return 1.0;
			} else {
				return -1.0;
			}

		case OSC_COMPLEX_SQUARE:
			return 2.0f * conjf(csc_int(phi)) * I / M_PI + 1.0f;

		case OSC_RAMP:
		case OSC_COMPLEX_RAMP:
		case OSC_GAUSS:
		case OSC_PARABOLA:

	}
}

static enum wave_types find_wave_type(VALUE wave_type)
{
	if (wave_type == sym_osc_sine) {
		return OSC_SINE;
	}
	if (wave_type == sym_osc_complex_sine) {
		return OSC_COMPLEX_SINE;
	}
	if (wave_type == sym_osc_triangle) {
		return OSC_TRIANGLE;
	}
	if (wave_type == sym_osc_complex_triangle) {
		return OSC_COMPLEX_TRIANGLE;
	}
	if (wave_type == sym_osc_square) {
		return OSC_SQUARE;
	}
	if (wave_type == sym_osc_complex_square) {
		return OSC_COMPLEX_SQUARE;
	}
	if (wave_type == sym_osc_ramp) {
		return OSC_RAMP;
	}
	if (wave_type == sym_osc_complex_ramp) {
		return OSC_COMPLEX_RAMP;
	}
	if (wave_type == sym_osc_gauss) {
		return OSC_GAUSS;
	}
	if (wave_type == sym_osc_parabola) {
		return OSC_PARABOLA;
	}

	rb_raise(rb_eRuntimeError, "Invalid wave type given: %"PRIsVALUE, wave_type);
}

VALUE sample

void Init_fast_sound(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE fast_sound = rb_define_module_under(mb, "FastSound");

	rb_define_module_function(fast_sound, 
}
