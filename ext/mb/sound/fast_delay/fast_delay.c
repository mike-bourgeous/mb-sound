/*
 * Delay line kernels for MB::Sound::DelayLine (Filter::Delay and
 * GraphNode::MultitapDelay): reading a circular buffer at constant or
 * per-sample fractional delays with linear, cubic, or windowed-sinc
 * interpolation, and running input through a feedback loop.  The Ruby
 * versions are DelayLine#read_ruby and #feedback_ruby, and specs check that
 * both give exactly the same values.
 * (C)2026 Mike Bourgeous
 */
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>

#include "numo/narray.h"

// Casts *narray to a contiguous 1D SFloat NArray.
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

// Casts *narray to a contiguous 1D SComplex NArray.
static void ensure_scomplex(VALUE *narray)
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

// Converts a Ruby Numeric (possibly Complex) to a C complex double.
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

// A delay line is a circular SFloat or SComplex buffer.  Delays are in
// samples, counted back from each output sample's own input sample, and
// clamped to 0..capacity - 2.  Fractional delays interpolate linearly
// between the samples at floor(delay) and floor(delay) + 1, computed in
// double precision and stored in single precision.

// A per-sample control input (delay times, gains): a number, or an SFloat,
// DFloat, or SComplex NArray with one value per sample.
struct control_input {
	double complex scalar;
	const float *f;
	const double *d;
	const float complex *c;
};

// Reads a control input from *value (see struct control_input), raising an
// error if an NArray is shorter than +length+.  Other NArray types are cast
// to DFloat (stored back into *value, which the caller keeps alive).
static void read_control_input(VALUE *value, size_t length, const char *name, struct control_input *ctl)
{
	ctl->scalar = 0;
	ctl->f = NULL;
	ctl->d = NULL;
	ctl->c = NULL;

	if (!rb_obj_is_kind_of(*value, numo_cNArray)) {
		ctl->scalar = num_to_complex(*value);
		return;
	}

	if (RNARRAY_NDIM(*value) != 1 || RNARRAY_SHAPE(*value)[0] < length) {
		rb_raise(rb_eArgError, "%s must be a number or a 1D NArray at least as long as the buffer", name);
	}

	VALUE cls = CLASS_OF(*value);
	if (cls != numo_cSFloat && cls != numo_cDFloat && cls != numo_cSComplex) {
		*value = rb_funcall(numo_cDFloat, rb_intern("cast"), 1, *value);
		cls = numo_cDFloat;
	}
	if (!RTEST(nary_check_contiguous(*value))) {
		*value = nary_dup(*value);
	}

	void *ptr = nary_get_pointer_for_read(*value) + nary_get_offset(*value);
	if (cls == numo_cSFloat) {
		ctl->f = ptr;
	} else if (cls == numo_cDFloat) {
		ctl->d = ptr;
	} else {
		ctl->c = ptr;
	}
}

static inline double complex control_value(const struct control_input *ctl, size_t i)
{
	if (ctl->f) {
		return ctl->f[i];
	} else if (ctl->d) {
		return ctl->d[i];
	} else if (ctl->c) {
		return ctl->c[i];
	}
	return ctl->scalar;
}

// Returns the delay for sample +i+, clamped to 0..max.
static inline double delay_value(const struct control_input *ctl, size_t i, double max)
{
	double d = creal(control_value(ctl, i));
	if (d < 0) {
		return 0;
	}
	return d > max ? max : d;
}

static inline long wrap_index(long i, long capacity)
{
	long r = i % capacity;
	return r < 0 ? r + capacity : r;
}

// Checks that +buffer+ is a contiguous 1D SFloat or SComplex NArray long
// enough to delay, returning true if it is complex.
static _Bool check_delay_buffer(VALUE buffer, const char *name)
{
	VALUE cls = CLASS_OF(buffer);
	if ((cls != numo_cSFloat && cls != numo_cSComplex) || RNARRAY_NDIM(buffer) != 1 || !RTEST(nary_check_contiguous(buffer))) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D SFloat or SComplex NArray", name);
	}
	return cls == numo_cSComplex;
}

// Interpolation modes for fractional delays (DelayLine::INTERPOLATION).
enum delay_interpolation {
	DELAY_LINEAR = 0, // between the samples at floor(delay) and floor(delay) + 1
	DELAY_CUBIC = 1, // 4-point Catmull-Rom (Hermite) spline
	DELAY_SINC = 2, // windowed sinc, low-passed by 1/rate when reading faster than 1x
};

// The windowed-sinc kernel from DelayLine::SINC_KERNEL: table[j] is the
// kernel at j / resolution samples from its center (0 past +half+), and
// the kernel widens by up to +max_rate+ times when reading faster than 1x.
struct sinc_kernel {
	const double *table;
	long table_length;
	double half;
	double resolution;
	double max_rate;
};

// Reads a sinc kernel ([table DFloat, half, resolution, max_rate]) for the
// sinc interpolation mode (+kernel+ must stay alive while it is used).
static void read_sinc_kernel(VALUE kernel, struct sinc_kernel *k)
{
	if (!RB_TYPE_P(kernel, T_ARRAY) || RARRAY_LEN(kernel) != 4) {
		rb_raise(rb_eArgError, "Sinc interpolation needs a kernel Array of [table, half, resolution, max_rate]");
	}

	VALUE table = rb_ary_entry(kernel, 0);
	if (CLASS_OF(table) != numo_cDFloat || RNARRAY_NDIM(table) != 1 || !RTEST(nary_check_contiguous(table))) {
		rb_raise(rb_eArgError, "The sinc kernel table must be a contiguous 1D DFloat NArray");
	}

	k->table = (const double *)(nary_get_pointer_for_read(table) + nary_get_offset(table));
	k->table_length = RNARRAY_SHAPE(table)[0];
	k->half = NUM2DBL(rb_ary_entry(kernel, 1));
	k->resolution = NUM2DBL(rb_ary_entry(kernel, 2));
	k->max_rate = NUM2DBL(rb_ary_entry(kernel, 3));
}

// The number of samples older than floor(delay) that a mode reads (delays
// are clamped so these stay inside the buffer).
static double delay_margin(int mode, const struct sinc_kernel *k)
{
	switch (mode) {
		case DELAY_CUBIC:
			return 2;
		case DELAY_SINC:
			return ceil(k->half * k->max_rate) + 1;
		default:
			return 1;
	}
}

// The sinc kernel weight at +x+ samples from its center (scaled by the
// cutoff), interpolated linearly in the table.
static inline double sinc_weight(const struct sinc_kernel *k, double x)
{
	double u = x * k->resolution;
	long j = (long)u;
	if (j + 1 >= k->table_length) {
		return 0;
	}
	double f = u - j;
	return k->table[j] + (k->table[j + 1] - k->table[j]) * f;
}

// Interpolates the delay line +buf+ at +d+ samples before position +base+
// (+rate+ is the read speed for sinc).  Samples newer than +base+ are never
// read: taps at negative delays read the sample at +base+ instead.
#define DELAY_INTERP(NAME, STORE, CALC) \
static CALC NAME(const STORE *buf, long cap, long base, double d, int mode, const struct sinc_kernel *k, double rate) \
{ \
	double dmin = floor(d); \
	double t = d - dmin; \
	long di = (long)dmin; \
	\
	switch (mode) { \
		case DELAY_CUBIC: { \
			CALC ym1 = buf[wrap_index(base - (di > 0 ? di - 1 : 0), cap)]; \
			CALC y0 = buf[wrap_index(base - di, cap)]; \
			CALC y1 = buf[wrap_index(base - di - 1, cap)]; \
			CALC y2 = buf[wrap_index(base - di - 2, cap)]; \
			CALC c0 = y0; \
			CALC c1 = 0.5 * (y1 - ym1); \
			CALC c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2; \
			CALC c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1); \
			return ((c3 * t + c2) * t + c1) * t + c0; \
		} \
		\
		case DELAY_SINC: { \
			if (t == 0 && rate <= 1) { \
				/* The kernel is zero at other whole samples */ \
				return buf[wrap_index(base - di, cap)]; \
			} \
			double fc = rate > 1 ? 1.0 / (rate < k->max_rate ? rate : k->max_rate) : 1.0; \
			double support = k->half / fc; \
			long kmin = (long)ceil(d - support); \
			long kmax = (long)floor(d + support); \
			CALC sum = 0; \
			double wsum = 0; \
			for (long kk = kmin; kk <= kmax; kk++) { \
				double w = sinc_weight(k, fabs((double)kk - d) * fc); \
				sum += w * (CALC)buf[wrap_index(base - (kk > 0 ? kk : 0), cap)]; \
				wsum += w; \
			} \
			return wsum != 0 ? sum / wsum : 0; \
		} \
		\
		default: { \
			CALC a = buf[wrap_index(base - di, cap)]; \
			CALC b = buf[wrap_index(base - di - 1, cap)]; \
			return a * (1.0 - t) + b * t; \
		} \
	} \
}

DELAY_INTERP(delay_interp_real, float, double)
DELAY_INTERP(delay_interp_complex, float complex, double complex)

// Reads the interpolation mode, kernel, and previous delay (state[0], for
// the read rate) shared by the delay kernels.
static void read_interpolation(VALUE mode, VALUE kernel, VALUE state, int *m, struct sinc_kernel *k, double *prev, _Bool *have_prev)
{
	*m = NUM2INT(mode);
	if (*m < DELAY_LINEAR || *m > DELAY_SINC) {
		rb_raise(rb_eArgError, "Unknown delay interpolation mode %d", *m);
	}

	memset(k, 0, sizeof(*k));
	if (*m == DELAY_SINC) {
		read_sinc_kernel(kernel, k);
	}

	*have_prev = 0;
	*prev = 0;
	if (RTEST(state)) {
		Check_Type(state, T_ARRAY);
		VALUE p = rb_ary_entry(state, 0);
		if (RTEST(p)) {
			*prev = NUM2DBL(p);
			*have_prev = 1;
		}
	}
}

// Returns the read speed for delay +d+ after delay +*prev+, and remembers
// +d+.  A constant delay (+moving+ false) reads at 1x: changing it between
// buffers is a jump, not a speed.
static inline double delay_rate(double d, double *prev, _Bool *have_prev, _Bool moving)
{
	double rate = *have_prev && moving ? fabs(1.0 - (d - *prev)) : 1.0;
	*prev = d;
	*have_prev = 1;
	return rate;
}

/*
 * Reads RNARRAY_SHAPE(target)[0] samples from the delay line +buffer+ into
 * +target+ (the same type), for a block written at +block_start+, delayed
 * by +delay+ samples (a number or a per-sample NArray), interpolating with
 * +mode+ (DelayLine::INTERPOLATION; +kernel+ is DelayLine::SINC_KERNEL for
 * sinc).  The previous delay is read from and stored in state[0] if
 * +state+ is an Array.  Returns +target+.  MB::Sound::FastDelay.read; see DelayLine#read.
 */
static VALUE ruby_delay_read(VALUE self, VALUE buffer, VALUE target, VALUE block_start, VALUE delay, VALUE mode, VALUE kernel, VALUE state)
{
	_Bool complex_buffer = check_delay_buffer(buffer, "Buffer");
	if (CLASS_OF(target) != CLASS_OF(buffer) || RNARRAY_NDIM(target) != 1 || !RTEST(nary_check_contiguous(target))) {
		rb_raise(rb_eArgError, "Target must be a contiguous 1D NArray of the buffer's type");
	}

	int m;
	struct sinc_kernel k;
	double prev;
	_Bool have_prev;
	read_interpolation(mode, kernel, state, &m, &k, &prev, &have_prev);

	long capacity = RNARRAY_SHAPE(buffer)[0];
	double max = capacity - 1 - delay_margin(m, &k);
	if (max < 0) {
		rb_raise(rb_eArgError, "The delay buffer is too small for this interpolation mode");
	}
	size_t count = RNARRAY_SHAPE(target)[0];
	long start = NUM2LONG(block_start);

	struct control_input ctl;
	read_control_input(&delay, count, "Delay", &ctl);

	void *in = nary_get_pointer_for_read(buffer) + nary_get_offset(buffer);
	void *out = nary_get_pointer_for_write(target) + nary_get_offset(target);

	for (size_t i = 0; i < count; i++) {
		double d = delay_value(&ctl, i, max);
		double rate = delay_rate(d, &prev, &have_prev, ctl.f || ctl.d || ctl.c);
		long base = start + (long)i;

		if (complex_buffer) {
			((float complex *)out)[i] = delay_interp_complex(in, capacity, base, d, m, &k, rate);
		} else {
			((float *)out)[i] = delay_interp_real(in, capacity, base, d, m, &k, rate);
		}
	}

	if (RTEST(state) && have_prev) {
		rb_ary_store(state, 0, DBL2NUM(prev));
	}

	RB_GC_GUARD(delay);
	RB_GC_GUARD(kernel);

	return target;
}

/*
 * Runs +input+ through a feedback loop one sample at a time: writes each
 * input sample into the delay line +buffer+ at +write_offset+, reads the
 * delayed sample (+delay+, a number or a per-sample NArray, interpolated
 * as for read), adds +feedback+ (a number or a per-sample NArray)
 * times the delayed sample to the written sample, and stores the delayed
 * sample in +out+.  Returns the new write offset.  MB::Sound::FastDelay.feedback; see DelayLine#feedback.
 */
static VALUE ruby_delay_feedback(VALUE self, VALUE buffer, VALUE write_offset, VALUE input, VALUE out, VALUE delay, VALUE feedback, VALUE mode, VALUE kernel, VALUE state)
{
	_Bool complex_buffer = check_delay_buffer(buffer, "Buffer");
	if (CLASS_OF(out) != CLASS_OF(buffer) || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "Output must be a contiguous 1D NArray of the buffer's type");
	}

	int m;
	struct sinc_kernel k;
	double prev;
	_Bool have_prev;
	read_interpolation(mode, kernel, state, &m, &k, &prev, &have_prev);

	long capacity = RNARRAY_SHAPE(buffer)[0];
	double max = capacity - 1 - delay_margin(m, &k);
	if (max < 0) {
		rb_raise(rb_eArgError, "The delay buffer is too small for this interpolation mode");
	}
	size_t count = RNARRAY_SHAPE(out)[0];
	long offset = NUM2LONG(write_offset);

	if (complex_buffer) {
		ensure_scomplex(&input);
	} else {
		ensure_sfloat(&input);
	}
	if (RNARRAY_SHAPE(input)[0] < count) {
		rb_raise(rb_eArgError, "Input must be at least as long as the output");
	}

	struct control_input delays, gains;
	read_control_input(&delay, count, "Delay", &delays);
	read_control_input(&feedback, count, "Feedback", &gains);
	if (!complex_buffer && (gains.c || cimag(gains.scalar) != 0)) {
		rb_raise(rb_eArgError, "Complex feedback needs a complex buffer");
	}

	void *in = nary_get_pointer_for_read(input) + nary_get_offset(input);
	void *buf = nary_get_pointer_for_write(buffer) + nary_get_offset(buffer);
	void *outp = nary_get_pointer_for_write(out) + nary_get_offset(out);

	for (size_t i = 0; i < count; i++) {
		double d = delay_value(&delays, i, max);
		double rate = delay_rate(d, &prev, &have_prev, delays.f || delays.d || delays.c);
		long w = wrap_index(offset + (long)i, capacity);
		_Bool whole = d == floor(d) && m != DELAY_SINC;

		if (complex_buffer) {
			float complex *b = buf;
			b[w] = ((const float complex *)in)[i];
			double complex v = whole ? (double complex)b[wrap_index(w - (long)d, capacity)] : delay_interp_complex(b, capacity, w, d, m, &k, rate);
			b[w] = (double complex)b[w] + control_value(&gains, i) * v;
			((float complex *)outp)[i] = v;
		} else {
			float *b = buf;
			b[w] = ((const float *)in)[i];
			double v = whole ? (double)b[wrap_index(w - (long)d, capacity)] : delay_interp_real(b, capacity, w, d, m, &k, rate);
			b[w] = (double)b[w] + creal(control_value(&gains, i)) * v;
			((float *)outp)[i] = v;
		}
	}

	if (RTEST(state) && have_prev) {
		rb_ary_store(state, 0, DBL2NUM(prev));
	}

	RB_GC_GUARD(input);
	RB_GC_GUARD(delay);
	RB_GC_GUARD(feedback);
	RB_GC_GUARD(kernel);

	return LONG2NUM(wrap_index(offset + (long)count, capacity));
}

void Init_fast_delay(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_delay = rb_define_module_under(sound, "FastDelay");

	rb_define_module_function(fast_delay, "read", ruby_delay_read, 7);
	rb_define_module_function(fast_delay, "feedback", ruby_delay_feedback, 9);
}
