/*
 * Faster sound routines for internal use by mb-sound, typically fairly
 * straightforward ports from existing Ruby code.
 * (C)2021 Mike Bourgeous
 */
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>

#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_osc_shapes.h"
#include "mb_biquad.h"

static ID sym_array_lookup;

static ID sym_osc_sine;
static ID sym_osc_complex_sine;
static ID sym_osc_triangle;
static ID sym_osc_complex_triangle;
static ID sym_osc_square;
static ID sym_osc_complex_square;
static ID sym_osc_ramp;
static ID sym_osc_complex_ramp;
static ID sym_osc_gauss;
static ID sym_osc_parabola;

// Behaves like Ruby's % operator instead of fmod
// Wraps X to be between 0 and Y
static double wrap(double x, double y)
{
	// this could instead be fmod(x, y) + y if x is negative
	return x - y * floor(x / y);
}

// Wraps X to be between 0 and Y
static ssize_t wrapsize(ssize_t x, ssize_t y)
{
	if (x >= 0 && x < y) {
		return x;
	}

	if (x < 0) {
		return x % y + y;
	}

	return x % y;
}

static double complex biquad_complex(
		double complex b0, double complex b1, double complex b2,
		double complex a1, double complex a2,
		double complex x0, double complex x1, double complex x2,
		double complex y1, double complex y2
		)
{
	double complex out = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;

	// Prevent denormals
	double real = creal(out);
	double imag = cimag(out);
	if (double_is_tiny(real) && double_is_tiny(creal(y1)) && double_is_tiny(creal(y2))) {
		real = 0;
	}
	if (double_is_tiny(imag) && double_is_tiny(cimag(y1)) && double_is_tiny(cimag(y2))) {
		imag = 0;
	}

	return real + I * imag;
}


static double smoothstep(double x)
{
	return 3*x*x - 2*x*x*x;
}

static double smootherstep(double x)
{
	return 6*x*x*x*x*x - 15*x*x*x*x + 10*x*x*x;
}

static double adsr(
		double time,
		double attack,
		double decay,
		double sustain,
		double release,
		double peak,
		_Bool on
		)
{
	double release_start = attack + decay;
	double total = attack + decay + release;

	double value;

	if (on) {
		if (time < 0) {
			value = 0.0;
		} else if (time < attack) {
			value = smoothstep(time / attack);
		} else if (time < release_start) {
			value = 1.0 - smoothstep((time - attack) / decay) * (1.0 - sustain);
		} else {
			value = sustain;
		}
	} else {
		if (time < release_start) {
			value = sustain;
		} else if (time < total) {
			value = (1.0 - smoothstep((time - release_start) / release)) * sustain;
		} else {
			value = 0.0;
		}
	}

	return value * peak;
}

static void ensure_inplace_sfloat(VALUE *narray, _Bool *was_inplace)
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

static void ensure_inplace_sfloat_or_scomplex(VALUE *narray, _Bool *was_inplace)
{
	int dim = RNARRAY_NDIM(*narray);
	if (dim != 1) {
		rb_raise(rb_eArgError, "Only 1D NArrays may be processed (got %d dimensions)", dim);
	}

	_Bool prior_inplace = !!TEST_INPLACE(*narray);

	if (CLASS_OF(*narray) == numo_cDComplex || CLASS_OF(*narray) == numo_cSComplex) {
		*narray = rb_funcall(numo_cSComplex, rb_intern("cast"), 1, *narray);
	} else {
		*narray = rb_funcall(numo_cSFloat, rb_intern("cast"), 1, *narray);
	}

	if (!RTEST(nary_check_contiguous(*narray)) || !prior_inplace) {
		*narray = nary_dup(*narray);
		SET_INPLACE(*narray);
		prior_inplace = 0;
	}

	if (was_inplace != NULL) {
		*was_inplace = prior_inplace;
	}
}

static void ensure_sfloat(VALUE *narray)
{
	int dim = RNARRAY_NDIM(*narray);
	if (dim != 1) {
		rb_raise(rb_eArgError, "Only 1D NArrays may be processed (got %d dimensions)", dim);
	}

	*narray = rb_funcall(numo_cSFloat, rb_intern("cast"), 1, *narray);

	if (!RTEST(nary_check_contiguous(*narray))) {
		*narray = nary_dup(*narray);
	}
}

static enum wave_types find_wave_type(ID wave_type)
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

static complex double num_to_complex(VALUE z)
{
	double real, imag;

	if (!RB_TYPE_P(z, T_COMPLEX)) {
		real = NUM2DBL(z);
		imag = 0;
	} else {
		real = NUM2DBL(rb_complex_real(z));
		imag = NUM2DBL(rb_complex_imag(z));
	}

	return real + I * imag;
}

static VALUE complex_to_num(double complex z)
{
	return rb_dbl_complex_new(creal(z), cimag(z));
}

static VALUE ruby_csc_int(VALUE self, VALUE z)
{
	return complex_to_num(csc_int(num_to_complex(z)));
}

static VALUE ruby_csc_int_int(VALUE self, VALUE z)
{
	return complex_to_num(csc_int_int(num_to_complex(z)));
}

static VALUE ruby_cot_int(VALUE self, VALUE z)
{
	return complex_to_num(cot_int(num_to_complex(z)));
}

static VALUE ruby_smoothstep(VALUE self, VALUE x)
{
	return rb_float_new(smoothstep(NUM2DBL(x)));
}

static VALUE ruby_smootherstep(VALUE self, VALUE x)
{
	return rb_float_new(smootherstep(NUM2DBL(x)));
}

static VALUE ruby_fmod(VALUE self, VALUE x, VALUE y)
{
	return rb_float_new(fmod(NUM2DBL(x), NUM2DBL(y)));
}

static VALUE ruby_remainder(VALUE self, VALUE x, VALUE y)
{
	return rb_float_new(remainder(NUM2DBL(x), NUM2DBL(y)));
}

static VALUE ruby_wrap(VALUE self, VALUE x, VALUE y)
{
	return rb_float_new(wrap(NUM2DBL(x), NUM2DBL(y)));
}

static VALUE ruby_wrapsize(VALUE self, VALUE x, VALUE y)
{
	return SSIZET2NUM(wrapsize(NUM2SSIZET(x), NUM2SSIZET(y)));
}

static VALUE ruby_idiv(VALUE self, VALUE x, VALUE y)
{
	return SSIZET2NUM(NUM2SSIZET(x) / NUM2SSIZET(y));
}

static VALUE ruby_fdiv(VALUE self, VALUE x, VALUE y)
{
	return rb_float_new(NUM2DBL(x) / NUM2DBL(y));
}

static VALUE ruby_imod(VALUE self, VALUE x, VALUE y)
{
	return SSIZET2NUM(NUM2SSIZET(x) % NUM2SSIZET(y));
}

static VALUE ruby_f64to32(VALUE self, VALUE x)
{
	volatile float y = NUM2DBL(x);
	return rb_float_new(y);
}

// Splits complex into real and imaginary
static VALUE ruby_complex(VALUE self, VALUE z)
{
	double complex c = num_to_complex(z);

	return rb_ary_new_from_args(2, rb_float_new(creal(c)), rb_float_new(cimag(c)));
}

static VALUE ruby_narray_to_array(VALUE self, VALUE narray)
{
	narray = rb_funcall(numo_cDComplex, rb_intern("cast"), 1, narray);
	size_t length = RNARRAY_SHAPE(narray)[0];
	VALUE out = rb_ary_new_capa(length);

	rb_funcall(narray, rb_intern("debug_info"), 0);
	rb_warn("Size is %zu, ndim is %d, length is %zu\n", RNARRAY_SIZE(narray), RNARRAY_NDIM(narray), length);

	double complex *ptr = (double complex *)(nary_get_pointer_for_read(narray) + nary_get_offset(narray));
	for(size_t i = 0; i < length; i++) {
		rb_ary_store(out, i, complex_to_num(ptr[i]));
	}

	return out;
}

static VALUE fill_narray_with_function(VALUE narray, double (*func)(double))
{
	_Bool was_inplace;
	ensure_inplace_sfloat_or_scomplex(&narray, &was_inplace);

	_Bool complex_buffer = CLASS_OF(narray) == numo_cSComplex;

	size_t length = RNARRAY_SHAPE(narray)[0];

	float complex *complex_ptr;
	float *float_ptr;
	if (complex_buffer) {
		complex_ptr = (float complex *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));
	} else {
		float_ptr = (float *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));
	}

	for (size_t i = 0; i < length; i++) {
		double x = ((double)i + 0.5) / (double)length; // symmetric, exclusive endpoints
		double v = func(x);

		if (complex_buffer) {
			complex_ptr[i] = v;
		} else {
			float_ptr[i] = v;
		}
	}

	if (!was_inplace) {
		UNSET_INPLACE(narray);
	}

	return narray;
}

/*
 * Fills the given narray (or a new narray if the narray is not inplace) with a
 * smoothstep curve from 0 to 1 (exclusive on both ends and symmetric).
 */
static VALUE ruby_smoothstep_buf(VALUE self, VALUE narray)
{
	return fill_narray_with_function(narray, smoothstep);
}

/*
 * Fills the given narray (or a new narray if the narray is not inplace) with a
 * smootherstep curve from 0 to 1 (exclusive on both ends and symmetric).
 */
static VALUE ruby_smootherstep_buf(VALUE self, VALUE narray)
{
	return fill_narray_with_function(narray, smootherstep);
}

/*
 * Calculates the natural logarithm of every element in the NArray.  Leaves
 * SFloat, SComplex, and DComplex as their original type, converts everything
 * else to DFloat.
 */
static VALUE ruby_narray_log(VALUE self, VALUE narray)
{
	VALUE ntype = CLASS_OF(narray);
	if (ntype != numo_cSFloat && ntype != numo_cDFloat && ntype != numo_cSComplex && ntype != numo_cDComplex) {
		narray = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, narray);
		ntype = numo_cDFloat;
	}

	_Bool was_inplace = !!TEST_INPLACE(narray);
	if (!RTEST(nary_check_contiguous(narray)) || !was_inplace) {
		narray = nary_dup(narray);
		SET_INPLACE(narray);
		was_inplace = 0;
	}

	size_t length = RNARRAY_SIZE(narray);

	if (ntype == numo_cSFloat) {
		float *ptr = (float *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = logf(ptr[i]);
		}
	} else if (ntype == numo_cDFloat) {
		double *ptr = (double *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = log(ptr[i]);
		}
	} else if (ntype == numo_cSComplex) {
		float complex *ptr = (float complex *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = clogf(ptr[i]);
		}
	} else if (ntype == numo_cDComplex) {
		double complex *ptr = (double complex *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = clog(ptr[i]);
		}
	} else {
		rb_raise(rb_eException, "BUG: Unexpected type %"PRIsVALUE, ntype);
	}

	if (!was_inplace) {
		UNSET_INPLACE(narray);
	}

	return narray;
}

/*
 * Calculates the base two logarithm of every element in the NArray.  Leaves
 * SFloat, SComplex, and DComplex as their original type, converts everything
 * else to DFloat.
 */
static VALUE ruby_narray_log2(VALUE self, VALUE narray)
{
	VALUE ntype = CLASS_OF(narray);
	if (ntype != numo_cSFloat && ntype != numo_cDFloat && ntype != numo_cSComplex && ntype != numo_cDComplex) {
		narray = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, narray);
		ntype = numo_cDFloat;
	}

	_Bool was_inplace = !!TEST_INPLACE(narray);
	if (!RTEST(nary_check_contiguous(narray)) || !was_inplace) {
		narray = nary_dup(narray);
		SET_INPLACE(narray);
		was_inplace = 0;
	}

	size_t length = RNARRAY_SIZE(narray);

	// TODO: Find a way to deduplicate with natural log; C doesn't actually
	// have clog2 or clog10, so they need special handling for complex
	if (ntype == numo_cSFloat) {
		float *ptr = (float *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = log2f(ptr[i]);
		}
	} else if (ntype == numo_cDFloat) {
		double *ptr = (double *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = log2(ptr[i]);
		}
	} else if (ntype == numo_cSComplex) {
		float complex *ptr = (float complex *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = clogf(ptr[i]) / logf(2);
		}
	} else if (ntype == numo_cDComplex) {
		double complex *ptr = (double complex *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = clog(ptr[i]) / log(2);
		}
	} else {
		rb_raise(rb_eException, "BUG: Unexpected type %"PRIsVALUE, ntype);
	}

	if (!was_inplace) {
		UNSET_INPLACE(narray);
	}

	return narray;
}

/*
 * Calculates the base ten logarithm of every element in the NArray.  Leaves
 * SFloat, SComplex, and DComplex as their original type, converts everything
 * else to DFloat.
 */
static VALUE ruby_narray_log10(VALUE self, VALUE narray)
{
	VALUE ntype = CLASS_OF(narray);
	if (ntype != numo_cSFloat && ntype != numo_cDFloat && ntype != numo_cSComplex && ntype != numo_cDComplex) {
		narray = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, narray);
		ntype = numo_cDFloat;
	}

	_Bool was_inplace = !!TEST_INPLACE(narray);
	if (!RTEST(nary_check_contiguous(narray)) || !was_inplace) {
		narray = nary_dup(narray);
		SET_INPLACE(narray);
		was_inplace = 0;
	}

	size_t length = RNARRAY_SIZE(narray);

	// TODO: Find a way to deduplicate with natural log; C doesn't actually
	// have clog2 or clog10, so they need special handling for complex
	if (ntype == numo_cSFloat) {
		float *ptr = (float *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = log10f(ptr[i]);
		}
	} else if (ntype == numo_cDFloat) {
		double *ptr = (double *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = log10(ptr[i]);
		}
	} else if (ntype == numo_cSComplex) {
		float complex *ptr = (float complex *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = clogf(ptr[i]) / logf(10);
		}
	} else if (ntype == numo_cDComplex) {
		double complex *ptr = (double complex *)(nary_get_pointer_for_read_write(narray) + nary_get_offset(narray));
		for (size_t i = 0; i < length; i++) {
			ptr[i] = clog(ptr[i]) / log(10);
		}
	} else {
		rb_raise(rb_eException, "BUG: Unexpected type %"PRIsVALUE, ntype);
	}

	if (!was_inplace) {
		UNSET_INPLACE(narray);
	}

	return narray;
}


static VALUE ruby_osc(VALUE self, VALUE wave_type, VALUE phi)
{
	enum wave_types wt = find_wave_type(SYM2ID(wave_type));

	double complex result = osc_sample(wt, num_to_complex(phi));

	if (cimag(result) != 0) {
		return rb_dbl_complex_new(creal(result), cimag(result));
	} else {
		return rb_float_new(creal(result));
	}
}

// Phasor and waveform shaping (MB::Sound::Phasor and MB::Sound::Oscillator;
// the Ruby versions are Phasor#sample_ruby and Oscillator.shape_ruby).
//
// A phasor's phase is in cycles (0 <= phi < 1).  Each sample it advances by
// frequency * (advance + random * random_advance), where advance and
// random_advance are in cycles per Hz (advance is 1 / sample_rate) and
// random is uniform in 0..1, from the oscillator's own generator (see
// noise_random), so noise repeats from its seed.
//
// Within a buffer, the phase of sample i is phi + (the sum of increments
// 0...i), wrapped once, rather than wrapping after every sample: i *
// increment for a constant frequency, a running sum otherwise.  That keeps
// rounding from drifting within a buffer and matches the Ruby version
// (Phasor#phases_ruby), which does the same with Numo.

// Reads the noise generator state (an Array of one Integer, see
// Tone::State#noise) into *rng; required if +rndadv+ is nonzero.
static void read_noise_state(VALUE noise, double rndadv, uint64_t *rng)
{
	*rng = 0;
	if (NIL_P(noise)) {
		if (rndadv != 0) {
			rb_raise(rb_eArgError, "Noise (a random advance) needs a generator state");
		}
		return;
	}

	Check_Type(noise, T_ARRAY);
	if (RARRAY_LEN(noise) != 1) {
		rb_raise(rb_eArgError, "Noise state must have exactly one Integer element");
	}
	*rng = NUM2ULL(rb_ary_entry(noise, 0));
}

// Stores the noise generator state back (see read_noise_state).
static void write_noise_state(VALUE noise, uint64_t rng)
{
	if (!NIL_P(noise)) {
		rb_ary_store(noise, 0, ULL2NUM(rng));
	}
}

// Reads and checks the [phi] state array of a phasor.
static double read_phasor_state(VALUE state)
{
	Check_Type(state, T_ARRAY);

	if (RARRAY_LEN(state) != 1) {
		rb_raise(rb_eArgError, "State array must have exactly one numeric element");
	}

	return NUM2DBL(rb_ary_entry(state, 0));
}

/*
 * Fills the SFloat +buffer+ with the phase in cycles of a phasor, starting
 * from state[0] and storing the next phase back into state[0].  If
 * +increments+ is an SFloat NArray of the same length, the increment for
 * each sample is written there too.  +noise+ is the random generator state
 * (see Tone::State#noise), required when +random_advance+ is nonzero, else
 * nil.  See Phasor#sample_c.
 */
static VALUE ruby_phasor(VALUE self, VALUE buffer, VALUE frequency, VALUE advance, VALUE random_advance, VALUE state, VALUE increments, VALUE noise)
{
	double phi = read_phasor_state(state);
	double adv = NUM2DBL(advance);
	double rndadv = NUM2DBL(random_advance);
	uint64_t rng;
	read_noise_state(noise, rndadv, &rng);

	_Bool was_inplace;
	ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *out = (float *)(nary_get_pointer_for_write(buffer) + nary_get_offset(buffer));

	double freq;
	const float *freqptr;
	size_t freqstep;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqstep);

	float *incptr = NULL;
	if (RTEST(increments)) {
		if (CLASS_OF(increments) != numo_cSFloat || RNARRAY_SHAPE(increments)[0] != length || !RTEST(nary_check_contiguous(increments))) {
			rb_raise(rb_eArgError, "Increments must be a contiguous SFloat NArray as long as the buffer");
		}
		incptr = (float *)(nary_get_pointer_for_write(increments) + nary_get_offset(increments));
	}

	_Bool constant = !freqptr && rndadv == 0;
	double steps = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = freqptr[i * freqstep];
		}

		double inc = phasor_increment(freq, adv, rndadv, &rng);
		if (constant) {
			steps = inc * i;
		}

		out[i] = wrap(phi + steps, 1.0);
		if (incptr) {
			incptr[i] = inc;
		}

		if (rndadv != 0) {
			// Noise: a running wrapped phase, so the output doesn't depend on
			// where blocks start (steps of up to +-freq/2 cycles summed per
			// block rounded differently by block size)
			phi = wrap(phi + inc, 1.0);
		} else if (!constant) {
			steps += inc;
		}
	}

	if (constant) {
		steps = phasor_increment(freq, adv, 0, &rng) * length;
	}
	rb_ary_store(state, 0, rb_float_new(wrap(phi + steps, 1.0)));
	write_noise_state(noise, rng);

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(frequency);
	RB_GC_GUARD(increments);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * Fills +buffer+ (SFloat, or SComplex for complex waves) with +wave_type+
 * shaped from +phases+ (cycles), plus +phase_mod+ (radians; Numeric, NArray,
 * or nil), scaled by +gain+ and moved by +offset+.  +increments+ (cycles, or
 * nil for zero) matter only for complex square and ramp waves.  See
 * Oscillator.shape_c.
 */
static VALUE ruby_shape(VALUE self, VALUE buffer, VALUE wave_type, VALUE phases, VALUE increments, VALUE phase_mod, VALUE gain, VALUE offset)
{
	enum wave_types wt = find_wave_type(SYM2ID(wave_type));
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	_Bool was_inplace;
	ensure_inplace_sfloat_or_scomplex(&buffer, &was_inplace);
	_Bool complex_buffer = CLASS_OF(buffer) == numo_cSComplex;
	size_t length = RNARRAY_SHAPE(buffer)[0];
	void *out = nary_get_pointer_for_write(buffer) + nary_get_offset(buffer);

	if (RNARRAY_SHAPE(phases)[0] != length) {
		rb_raise(rb_eArgError, "Phase array length does not match sample buffer length");
	}
	ensure_sfloat(&phases);
	float *phaseptr = (float *)(nary_get_pointer_for_read(phases) + nary_get_offset(phases));

	double inc;
	const float *incptr;
	size_t incstep;
	mb_read_signal_input(&increments, length, "Increment", &inc, &incptr, &incstep);

	double pm;
	const float *pmptr;
	size_t pmstep;
	mb_read_signal_input(&phase_mod, length, "Phase modulation", &pm, &pmptr, &pmstep);

	for (size_t i = 0; i < length; i++) {
		if (incptr) {
			inc = incptr[i * incstep];
		}
		if (pmptr) {
			pm = pmptr[i * pmstep];
		}

		double complex v = shape_sample(wt, phaseptr[i], inc, pm) * g + off;

		if (complex_buffer) {
			((complex float *)out)[i] = v;
		} else {
			((float *)out)[i] = creal(v);
		}
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(phases);
	RB_GC_GUARD(increments);
	RB_GC_GUARD(phase_mod);
	RB_GC_GUARD(buffer);

	return buffer;
}

/*
 * A phasor and shaper in one loop (the usual oscillator path, avoiding a
 * phase buffer): fills +buffer+ with +wave_type+ at +frequency+ (Hz; Numeric
 * or NArray) plus +phase_mod+, advancing the phase in state[0] (cycles).
 * Same math as ruby_phasor followed by ruby_shape.  +noise+ is as for
 * ruby_phasor.  See Oscillator#sample_c.
 */
static VALUE ruby_oscillate(VALUE self, VALUE buffer, VALUE wave_type, VALUE frequency, VALUE phase_mod, VALUE advance, VALUE random_advance, VALUE gain, VALUE offset, VALUE state, VALUE noise)
{
	enum wave_types wt = find_wave_type(SYM2ID(wave_type));
	double phi = read_phasor_state(state);
	double adv = NUM2DBL(advance);
	double rndadv = NUM2DBL(random_advance);
	uint64_t rng;
	read_noise_state(noise, rndadv, &rng);
	double g = NUM2DBL(gain);
	double off = NUM2DBL(offset);

	_Bool was_inplace;
	ensure_inplace_sfloat_or_scomplex(&buffer, &was_inplace);
	_Bool complex_buffer = CLASS_OF(buffer) == numo_cSComplex;
	size_t length = RNARRAY_SHAPE(buffer)[0];
	void *out = nary_get_pointer_for_write(buffer) + nary_get_offset(buffer);

	double freq;
	const float *freqptr;
	size_t freqstep;
	mb_read_signal_input(&frequency, length, "Frequency", &freq, &freqptr, &freqstep);

	double pm;
	const float *pmptr;
	size_t pmstep;
	mb_read_signal_input(&phase_mod, length, "Phase modulation", &pm, &pmptr, &pmstep);

	_Bool constant = !freqptr && rndadv == 0;
	double steps = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = freqptr[i * freqstep];
		}
		if (pmptr) {
			pm = pmptr[i * pmstep];
		}

		double inc = phasor_increment(freq, adv, rndadv, &rng);
		if (constant) {
			steps = inc * i;
		}

		double complex v = shape_sample(wt, wrap(phi + steps, 1.0), inc, pm) * g + off;

		if (complex_buffer) {
			((complex float *)out)[i] = v;
		} else {
			((float *)out)[i] = creal(v);
		}

		if (rndadv != 0) {
			// Noise: a running wrapped phase, so the output doesn't depend on
			// where blocks start (steps of up to +-freq/2 cycles summed per
			// block rounded differently by block size)
			phi = wrap(phi + inc, 1.0);
		} else if (!constant) {
			steps += inc;
		}
	}

	if (constant) {
		steps = phasor_increment(freq, adv, 0, &rng) * length;
	}
	rb_ary_store(state, 0, rb_float_new(wrap(phi + steps, 1.0)));
	write_noise_state(noise, rng);

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(frequency);
	RB_GC_GUARD(phase_mod);
	RB_GC_GUARD(buffer);

	return buffer;
}

static VALUE ruby_biquad(VALUE self, VALUE b0, VALUE b1, VALUE b2, VALUE a1, VALUE a2, VALUE x0, VALUE x1, VALUE x2, VALUE y1, VALUE y2)
{
	double result = biquad_filter(
			NUM2DBL(b0), NUM2DBL(b1), NUM2DBL(b2),
			NUM2DBL(a1), NUM2DBL(a2),
			NUM2DBL(x0), NUM2DBL(x1), NUM2DBL(x2),
			NUM2DBL(y1), NUM2DBL(y2)
			);

	return rb_float_new(result);
}

static VALUE ruby_biquad_complex(VALUE self, VALUE b0, VALUE b1, VALUE b2, VALUE a1, VALUE a2, VALUE x0, VALUE x1, VALUE x2, VALUE y1, VALUE y2)
{
	double complex result = biquad_complex(
			num_to_complex(b0), num_to_complex(b1), num_to_complex(b2),
			num_to_complex(a1), num_to_complex(a2),
			num_to_complex(x0), num_to_complex(x1), num_to_complex(x2),
			num_to_complex(y1), num_to_complex(y2)
			);

	return complex_to_num(result);
}

#define BIQUAD_LOOP(buf_type, coeff_type, conv_from_rb, conv_to_rb, filter_func) do { \
	buf_type *data = (buf_type *)(nary_get_pointer_for_read_write(buf) + nary_get_offset(buf)); \
\
	coeff_type x0 = 0; \
	coeff_type x1 = conv_from_rb(rb_ary_entry(state, 1)); \
	coeff_type x2 = conv_from_rb(rb_ary_entry(state, 2)); \
	coeff_type y0 = 0; \
	coeff_type y1 = conv_from_rb(rb_ary_entry(state, 3)); \
	coeff_type y2 = conv_from_rb(rb_ary_entry(state, 4)); \
\
	coeff_type b0 = conv_from_rb(rb0); \
	coeff_type b1 = conv_from_rb(rb1); \
	coeff_type b2 = conv_from_rb(rb2); \
	coeff_type a1 = conv_from_rb(ra0); \
	coeff_type a2 = conv_from_rb(ra1); \
\
	for (size_t i = 0; i < length; i++) { \
		x0 = data[i]; \
		y0 = filter_func(b0, b1, b2, a1, a2, x0, x1, x2, y1, y2); \
		data[i] = y0; \
		y2 = y1; \
		y1 = y0; \
		x2 = x1; \
		x1 = x0; \
	} \
\
	rb_ary_store(state, 1, conv_to_rb(x1)); \
	rb_ary_store(state, 2, conv_to_rb(x2)); \
	rb_ary_store(state, 3, conv_to_rb(y1)); \
	rb_ary_store(state, 4, conv_to_rb(y2)); \
} while(0);

/*
 * Converted from lib/mb/sound/filter/biquad.rb
 *
 * buf must be a 1D Numo::DFloat or Numo::DComplex or compatible
 * state contains [buf, x1, x2, y1, y2]
 *
 * state will be mutated, and buf (state[0]) might be a different object!
 *
 * returns state
 */
static VALUE ruby_biquad_narray(VALUE self, VALUE rb0, VALUE rb1, VALUE rb2, VALUE ra0, VALUE ra1, VALUE state)
{
	VALUE buf, buf_type;

	Check_Type(state, T_ARRAY);

	buf = rb_ary_entry(state, 0);

	// References used for narray and Ruby APIs:
	// https://github.com/yoshoku/numo-pocketfft/blob/1ab489b165d4cde06b6d3a443ed9bfbc8e5c69d0/ext/numo/pocketfft/pocketfftext.c
	// https://github.com/ruby-numo/numo-narray/blob/6f5c91250c0cb948f6b811385d384c3f15af4dcd/ext/numo/narray/numo/intern.h
	// https://silverhammermba.github.io/emberb/c/
	// https://github.com/ruby/ruby/blob/master/doc/extension.rdoc

	// First try NArray's automatic conversion, to get e.g. from an array
	// of complex to DComplex
	buf_type = CLASS_OF(buf);
	if (buf_type != numo_cDComplex && buf_type != numo_cSComplex && buf_type != numo_cSFloat && buf_type != numo_cDFloat) {
		buf = rb_funcall(numo_cNArray, rb_intern("cast"), 1, buf);
		buf_type = CLASS_OF(buf);
	}

	// If that's still not a float or complex type (e.g. we had an Array of
	// Integers), force conversion to float
	buf_type = CLASS_OF(buf);
	if (buf_type != numo_cDComplex && buf_type != numo_cSComplex && buf_type != numo_cSFloat && buf_type != numo_cDFloat) {
		buf = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, buf);
		buf_type = CLASS_OF(buf);
	}

	int dim = RNARRAY_NDIM(buf);
	if (dim != 1) {
		rb_raise(rb_eArgError, "Only 1D NArrays may be processed (got %d dimensions)", dim);
	}

	_Bool was_inplace = !!TEST_INPLACE(buf);

	if (!RTEST(nary_check_contiguous(buf)) || !was_inplace) {
		buf = nary_dup(buf);
		SET_INPLACE(buf);
		was_inplace = 0;
	}

	size_t length = RNARRAY_SHAPE(buf)[0];

	if (buf_type == numo_cSFloat) {
		BIQUAD_LOOP(float, double, NUM2DBL, DBL2NUM, biquad_filter);
	} else if (buf_type == numo_cDFloat) {
		BIQUAD_LOOP(double, double, NUM2DBL, DBL2NUM, biquad_filter);
	} else if (buf_type == numo_cSComplex) {
		BIQUAD_LOOP(float complex, double complex, num_to_complex, complex_to_num, biquad_complex);
	} else if (buf_type == numo_cDComplex) {
		BIQUAD_LOOP(double complex, double complex, num_to_complex, complex_to_num, biquad_complex);
	} else {
		rb_raise(rb_eException, "BUG: Buffer was not SFloat, DFloat, SComplex, or DComplex");
	}

	if (!was_inplace) {
		UNSET_INPLACE(buf);
	}

	rb_ary_store(state, 0, buf);

	RB_GC_GUARD(buf);
	RB_GC_GUARD(state);

	return state;
}

/*
 * Generates cookbook filter biquad parameters, from lib/mb/sound/filter/cookbook.rb.
 *
 * Returns [omega, b0, b1, b2, a1, a2].
 */
static VALUE ruby_cookbook(VALUE self, VALUE type_id, VALUE f_samp, VALUE f_center, VALUE db_gain, VALUE quality, VALUE bandwidth_oct, VALUE shelf_slope)
{
	enum filter_types ftype = NUM2INT(type_id);

	if (!(RTEST(quality) || RTEST(bandwidth_oct) || RTEST(shelf_slope))) {
		rb_raise(rb_eArgError, "Missing quality/bandwidth_oct/shelf_slope");
	}

	if (!RTEST(db_gain) && (ftype == FILT_LOWSHELF || ftype == FILT_HIGHSHELF || ftype == FILT_PEAK)) {
		rb_raise(rb_eArgError, "Missing db_gain");
	}

	double g = RTEST(db_gain) ? NUM2DBL(db_gain) : NAN;
	double q = RTEST(quality) ? NUM2DBL(quality) : NAN;
	double bw = RTEST(bandwidth_oct) ? NUM2DBL(bandwidth_oct) : NAN;
	double ss = RTEST(shelf_slope) ? NUM2DBL(shelf_slope) : NAN;

	struct biquad_coeffs coeffs = cookbook(ftype, NUM2DBL(f_samp), NUM2DBL(f_center), g, q, bw, ss);

	VALUE out = rb_ary_new_capa(6);
	rb_ary_store(out, 0, rb_float_new(coeffs.omega));
	rb_ary_store(out, 1, rb_float_new(coeffs.b0));
	rb_ary_store(out, 2, rb_float_new(coeffs.b1));
	rb_ary_store(out, 3, rb_float_new(coeffs.b2));
	rb_ary_store(out, 4, rb_float_new(coeffs.a1));
	rb_ary_store(out, 5, rb_float_new(coeffs.a2));

	return out;
}

/*
 * Converted from lib/mb/sound/filter/cookbook.rb
 *
 * samples, cutoffs, and qualities should be 1D Numo::SFloat
 * state contains [x1, x2, y1, y2] and will be mutated
 * coeffs contains [omega, b0, b1, b2, a1, a2] and will be mutated
 *
 * returns samples
 */
static VALUE ruby_dynamic_biquad(VALUE self, VALUE samples, VALUE cutoffs, VALUE qualities, VALUE type_id, VALUE sample_rate, VALUE db_gain, VALUE coeffs, VALUE state)
{
	Check_Type(coeffs, T_ARRAY);
	Check_Type(state, T_ARRAY);

	_Bool was_inplace = 0;
	ensure_inplace_sfloat(&samples, &was_inplace);
	ensure_sfloat(&cutoffs);
	ensure_sfloat(&qualities);

	size_t length = RNARRAY_SHAPE(samples)[0];
	if (RNARRAY_SHAPE(cutoffs)[0] != length) {
		rb_raise(rb_eArgError, "Length of cutoff frequency array did not match length of sample array");
	}
	if (RNARRAY_SHAPE(qualities)[0] != length) {
		rb_raise(rb_eArgError, "Length of quality factor array did not match length of sample array");
	}

	const enum filter_types ftype = NUM2INT(type_id);
	const double g = RTEST(db_gain) ? NUM2DBL(db_gain) : NAN;
	const double rate = NUM2DBL(sample_rate);

	// nary_get_offset / na_get_offset returns a byte offset, so add it before the cast
	float *samp = (float *)(nary_get_pointer_for_write(samples) + nary_get_offset(samples));
	float *cut = (float *)(nary_get_pointer_for_read(cutoffs) + nary_get_offset(cutoffs));
	float *q = (float *)(nary_get_pointer_for_read(qualities) + nary_get_offset(qualities));
	struct biquad_coeffs bq = {
		.b0 = NUM2DBL(rb_ary_entry(coeffs, 0)),
		.b1 = NUM2DBL(rb_ary_entry(coeffs, 1)),
		.b2 = NUM2DBL(rb_ary_entry(coeffs, 2)),
		.a1 = NUM2DBL(rb_ary_entry(coeffs, 3)),
		.a2 = NUM2DBL(rb_ary_entry(coeffs, 4)),
	};
	double st[4] = {
		NUM2DBL(rb_ary_entry(state, 0)), NUM2DBL(rb_ary_entry(state, 1)),
		NUM2DBL(rb_ary_entry(state, 2)), NUM2DBL(rb_ary_entry(state, 3)),
	};
	mb_dynamic_biquad_run(ftype, rate, g, samp, samp, cut, q, length, &bq, st);
	double x1 = st[0], x2 = st[1], y1 = st[2], y2 = st[3];

	if (!was_inplace) {
		UNSET_INPLACE(samples);
	}

	rb_ary_store(coeffs, 0, rb_float_new(bq.omega));
	rb_ary_store(coeffs, 1, rb_float_new(bq.b0));
	rb_ary_store(coeffs, 2, rb_float_new(bq.b1));
	rb_ary_store(coeffs, 3, rb_float_new(bq.b2));
	rb_ary_store(coeffs, 4, rb_float_new(bq.a1));
	rb_ary_store(coeffs, 5, rb_float_new(bq.a2));

	rb_ary_store(state, 0, rb_float_new(x1));
	rb_ary_store(state, 1, rb_float_new(x2));
	rb_ary_store(state, 2, rb_float_new(y1));
	rb_ary_store(state, 3, rb_float_new(y2));

	RB_GC_GUARD(samples);
	RB_GC_GUARD(cutoffs);
	RB_GC_GUARD(qualities);

	return samples;
}

VALUE ruby_adsr(VALUE self, VALUE time, VALUE attack, VALUE decay, VALUE sustain, VALUE release, VALUE peak, VALUE on)
{
	return rb_float_new(adsr(
				NUM2DBL(time),
				NUM2DBL(attack),
				NUM2DBL(decay),
				NUM2DBL(sustain),
				NUM2DBL(release),
				NUM2DBL(peak),
				RTEST(on)
				));
}

// Extracted loop from ruby_adsr_narray for both float and double
#define adsr_loop do { \
	for(size_t i = 0; i < length; i++) { \
		double t = current_frame / sample_rate; \
		data[i] = adsr(t, a, d, s, r, p, o); \
		current_frame += 1; \
		\
		if (o && ar >= 0 && current_frame >= auto_release_start) { \
			/* auto-release (basically what the Ruby release function does) */ \
			o = 0; \
			current_frame = release_start; \
			p = 1.0; \
			s = (float)data[i]; \
		} \
		if (ar >= 0 && current_frame >= release_end && data[i] == 0) { \
			/* end of release */ \
			length = i + 1; \
			break; \
		} \
	} \
} while(0)

VALUE ruby_adsr_narray(VALUE self, VALUE narray, VALUE frame, VALUE rate, VALUE attack, VALUE decay, VALUE sustain, VALUE release, VALUE peak, VALUE on, VALUE auto_release, VALUE filter_ringdown)
{
	if (CLASS_OF(narray) != numo_cDFloat && CLASS_OF(narray) != numo_cSFloat) {
		narray = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, narray);
	}

	int dim = RNARRAY_NDIM(narray);
	if (dim != 1) {
		rb_raise(rb_eArgError, "Only 1D NArrays may be processed (got %d dimensions)", dim);
	}

	_Bool was_inplace = !!TEST_INPLACE(narray);

	if (!RTEST(nary_check_contiguous(narray)) || !was_inplace) {
		narray = nary_dup(narray);
		SET_INPLACE(narray);
		was_inplace = 0;
	}

	size_t length = RNARRAY_SHAPE(narray)[0];

	ssize_t current_frame = NUM2SSIZET(frame);
	double sample_rate = NUM2DBL(rate);

	// ADSR
	double a = NUM2DBL(attack);
	double d = NUM2DBL(decay);
	double s = NUM2DBL(sustain);
	double r = NUM2DBL(release);

	// Peak, on, auto-release, filter ringdown
	double p = NUM2DBL(peak);
	_Bool o = RTEST(on);
	double ar = RTEST(auto_release) ? NUM2DBL(auto_release) : -1;
	double fr = NUM2DBL(filter_ringdown);

	ssize_t auto_release_start = lrint(ar * sample_rate);
	ssize_t release_start = lrint((a + d) * sample_rate);
	ssize_t release_end = lrint((a + d + r + fr) * sample_rate);

	if (CLASS_OF(narray) == numo_cSFloat) {
		float *data = (float *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));
		adsr_loop;
	} else if (CLASS_OF(narray) == numo_cDFloat) {
		double *data = (double *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));
		adsr_loop;
	}

	RB_GC_GUARD(narray);

	VALUE narray_subset = rb_funcall(narray, sym_array_lookup, 1, rb_range_new(INT2FIX(0), SSIZET2NUM(length), 1));

	return rb_ary_new_from_args(6, narray_subset, SSIZET2NUM(current_frame), DBL2NUM(current_frame / sample_rate), o ? Qtrue : Qfalse, DBL2NUM(p), DBL2NUM(s));
}

// C conversion from MIDI note number to frequency.
static double num2freq(double number, double tune_note, double tune_freq)
{
	return mb_num2freq(number, tune_note, tune_freq);
}

/*
 * Converts a Numeric or Numo::SFloat/Numo::DFloat from MIDI note number to
 * oscillator frequency.  Modifies in-place narrays directly.
 *
 * +number+ - The fractional MIDI note number.
 * +tune_note+ - The root note number used for tuning (e.g. 69 for A4).
 * +tune_freq+ - The root frequency used for tuning (e.g. 440).
 */
VALUE ruby_number_to_freq(VALUE self, VALUE number, VALUE tune_note, VALUE tune_freq)
{
	double tnum = NUM2DBL(tune_note);
	double tfrq = NUM2DBL(tune_freq);

	if (rb_obj_is_kind_of(number, rb_cNumeric)) {
		double n = NUM2DBL(number);
		return DBL2NUM(num2freq(n, tnum, tfrq));
	}

	ensure_inplace_sfloat(&number, NULL);
	size_t length = RNARRAY_SHAPE(number)[0];
	float *float_ptr = (float *)(nary_get_pointer_for_write(number) + nary_get_offset(number));

	for (size_t i = 0; i < length; i++) {
		float_ptr[i] = num2freq(float_ptr[i], tnum, tfrq);
	}

	UNSET_INPLACE(number);

	return number;
}

// Returns a pointer to the float data of +v+, which must be a contiguous 1D
// SFloat with at least +count+ elements (+name+ and +idx+ are for errors).
static float *matrix_mix_buffer(VALUE v, size_t count, const char *name, long idx, _Bool write)
{
	if (CLASS_OF(v) != numo_cSFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "%s %ld must be a contiguous 1D SFloat", name, idx);
	}
	if (RNARRAY_SHAPE(v)[0] < count) {
		rb_raise(rb_eArgError, "%s %ld is shorter than the outputs (%zu < %zu)", name, idx, (size_t)RNARRAY_SHAPE(v)[0], count);
	}

	char *p = write ? nary_get_pointer_for_write(v) : nary_get_pointer_for_read(v);
	return (float *)(p + nary_get_offset(v));
}

/*
 * Multiplies the column of channels +inputs+ (an Array of N contiguous 1D
 * SFloat NArrays) by the M-by-N +matrix+ (a contiguous 2D DFloat NArray),
 * writing output channel i to +outputs+[i] (an Array of M contiguous 1D
 * SFloats, all the same length; the inputs may be longer).  Outputs must not
 * be inputs.  Zero coefficients are skipped and +/-1 coefficients add or
 * subtract without multiplying.  Returns +outputs+.
 *
 * MB::FastSound.matrix_mix; see ProcessingMatrix#process.
 */
static VALUE ruby_matrix_mix(VALUE self, VALUE matrix, VALUE inputs, VALUE outputs)
{
	Check_Type(inputs, T_ARRAY);
	Check_Type(outputs, T_ARRAY);

	if (CLASS_OF(matrix) != numo_cDFloat || RNARRAY_NDIM(matrix) != 2 || !RTEST(nary_check_contiguous(matrix))) {
		rb_raise(rb_eArgError, "The matrix must be a contiguous 2D DFloat");
	}

	long rows = RNARRAY_SHAPE(matrix)[0];
	long cols = RNARRAY_SHAPE(matrix)[1];
	if (RARRAY_LEN(inputs) != cols) {
		rb_raise(rb_eArgError, "Expected %ld inputs for the matrix, got %ld", cols, RARRAY_LEN(inputs));
	}
	if (RARRAY_LEN(outputs) != rows) {
		rb_raise(rb_eArgError, "Expected %ld outputs for the matrix, got %ld", rows, RARRAY_LEN(outputs));
	}
	if (rows == 0 || cols == 0) {
		return outputs;
	}

	size_t count = RNARRAY_SHAPE(rb_ary_entry(outputs, 0))[0];
	const double *m = (const double *)(nary_get_pointer_for_read(matrix) + nary_get_offset(matrix));

	const float **in = ALLOCA_N(const float *, cols);
	for (long j = 0; j < cols; j++) {
		in[j] = matrix_mix_buffer(rb_ary_entry(inputs, j), count, "Input", j, 0);
	}

	for (long i = 0; i < rows; i++) {
		VALUE outv = rb_ary_entry(outputs, i);
		if ((size_t)RNARRAY_SHAPE(outv)[0] != count) {
			rb_raise(rb_eArgError, "Output %ld has a different length than output 0", i);
		}
		float *out = matrix_mix_buffer(outv, count, "Output", i, 1);
		for (long j = 0; j < cols; j++) {
			if ((const float *)out == in[j]) {
				rb_raise(rb_eArgError, "Output %ld is also input %ld", i, j);
			}
		}

		memset(out, 0, count * sizeof(float));

		for (long j = 0; j < cols; j++) {
			double c = m[i * cols + j];
			const float *x = in[j];

			if (c == 0) {
				continue;
			} else if (c == 1) {
				for (size_t k = 0; k < count; k++) {
					out[k] += x[k];
				}
			} else if (c == -1) {
				for (size_t k = 0; k < count; k++) {
					out[k] -= x[k];
				}
			} else {
				float cf = (float)c;
				for (size_t k = 0; k < count; k++) {
					out[k] += cf * x[k];
				}
			}
		}
	}

	RB_GC_GUARD(matrix);
	RB_GC_GUARD(inputs);
	RB_GC_GUARD(outputs);

	return outputs;
}

void Init_fast_sound(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE fast_sound = rb_define_module_under(mb, "FastSound");

	sym_array_lookup = rb_intern("[]");

	sym_osc_sine = rb_intern("sine");
	sym_osc_complex_sine = rb_intern("complex_sine");
	sym_osc_triangle = rb_intern("triangle");
	sym_osc_complex_triangle = rb_intern("complex_triangle");
	sym_osc_square = rb_intern("square");
	sym_osc_complex_square = rb_intern("complex_square");
	sym_osc_ramp = rb_intern("ramp");
	sym_osc_complex_ramp = rb_intern("complex_ramp");
	sym_osc_gauss = rb_intern("gauss");
	sym_osc_parabola = rb_intern("parabola");

	// Oscillator functions
	rb_define_module_function(fast_sound, "osc", ruby_osc, 2);
	rb_define_module_function(fast_sound, "phasor", ruby_phasor, 7);
	rb_define_module_function(fast_sound, "shape", ruby_shape, 7);
	rb_define_module_function(fast_sound, "oscillate", ruby_oscillate, 10);

	// Filtering functions
	rb_define_module_function(fast_sound, "biquad", ruby_biquad, 10);
	rb_define_module_function(fast_sound, "biquad_complex", ruby_biquad_complex, 10);
	rb_define_module_function(fast_sound, "biquad_narray", ruby_biquad_narray, 6);
	rb_define_module_function(fast_sound, "dynamic_biquad", ruby_dynamic_biquad, 8);
	rb_define_module_function(fast_sound, "cookbook", ruby_cookbook, 7);

	// Mixing functions
	rb_define_module_function(fast_sound, "matrix_mix", ruby_matrix_mix, 3);

	// Envelope functions
	rb_define_module_function(fast_sound, "adsr", ruby_adsr, 7);
	rb_define_module_function(fast_sound, "adsr_narray", ruby_adsr_narray, 11);

	// Faster implementations of functions from mb-math
	rb_define_module_function(fast_sound, "cot_int", ruby_cot_int, 1);
	rb_define_module_function(fast_sound, "csc_int", ruby_csc_int, 1);
	rb_define_module_function(fast_sound, "csc_int_int", ruby_csc_int_int, 1);

	rb_define_module_function(fast_sound, "smoothstep", ruby_smoothstep, 1);
	rb_define_module_function(fast_sound, "smootherstep", ruby_smootherstep, 1);

	// Fills a given NArray with a smoothstep curve from 0 to 1
	rb_define_module_function(fast_sound, "smoothstep_buf", ruby_smoothstep_buf, 1);
	rb_define_module_function(fast_sound, "smootherstep_buf", ruby_smootherstep_buf, 1);

	// Mathematical functions that for some reason are missing from Numo::NArray
	rb_define_module_function(fast_sound, "narray_log", ruby_narray_log, 1);
	rb_define_module_function(fast_sound, "narray_log2", ruby_narray_log2, 1);
	rb_define_module_function(fast_sound, "narray_log10", ruby_narray_log10, 1);

	// Functions used when comparing C and Ruby's behavior for integer
	// division (C rounds to zero, Ruby rounds downward) and modulus (-1 %
	// 3 in Ruby is 2, in C it's -1)
	rb_define_module_function(fast_sound, "fmod", ruby_fmod, 2);
	rb_define_module_function(fast_sound, "remainder", ruby_remainder, 2);
	rb_define_module_function(fast_sound, "wrap", ruby_wrap, 2);
	rb_define_module_function(fast_sound, "wrapsize", ruby_wrapsize, 2);
	rb_define_module_function(fast_sound, "idiv", ruby_idiv, 2);
	rb_define_module_function(fast_sound, "fdiv", ruby_fdiv, 2);
	rb_define_module_function(fast_sound, "imod", ruby_imod, 2);
	rb_define_module_function(fast_sound, "f64to32", ruby_f64to32, 1);

	// Functions to test conversion to and from Ruby complex datatypes
	rb_define_module_function(fast_sound, "complex", ruby_complex, 1);
	rb_define_module_function(fast_sound, "narray_to_array", ruby_narray_to_array, 1);

	// Functions for converting between frequency and note number
	rb_define_module_function(fast_sound, "number_to_freq", ruby_number_to_freq, 3);
}
