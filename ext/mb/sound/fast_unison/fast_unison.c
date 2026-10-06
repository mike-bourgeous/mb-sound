/*
 * MB::Sound::FastUnison: the frequencies of unison copies whose detune
 * changes (MB::Sound::Unison::Detune, lib/mb/sound/unison/detune.rb).
 *
 * Every function writes a count x n SFloat frame +out+ (row i is copy i's
 * frequency in Hz) from the base frequency +freq+ (a Float, or an NArray of
 * n values read as float32) and the detune +detune+ (an NArray of n values
 * in semitones, read as float32), with K = ln(2) / 12:
 *
 * - exact(out, freq, detune, fractions): copy i at
 *   f * exp(fraction_i * (d * K)).
 * - scale(out, freq, ratios): copy i at f * ratio_i (constant ratios).
 * - interp(out, freq, detune, positions, state, control): the outermost
 *   ratio r = exp(d * K) at control points, linear in between; copy i at
 *   (1/r) f + position_i ((r - 1/r) f), positions 0 (f / r) to 1 (f r).
 *   +state+ is a DFloat [r_prev, r_cur, phase], updated in place.  With
 *   +control+ k > 0, a control point comes every k samples of the stream
 *   (phase counts the samples since the last one, across buffers), and r
 *   ramps from the previous control point's ratio (r_prev) to the new one
 *   (r_cur) over the k samples after it, so the output doesn't depend on
 *   the buffer size (with k samples of latency).  With +control+ 0 the
 *   control point is the buffer's last sample, ramped to from r_prev over
 *   the buffer (no latency; depends on the buffer size).
 *
 * The Ruby mirrors (Unison::Detune.exact_ruby, .scale_ruby, .interp_ruby)
 * give exactly the same samples (specs check them), so keep the operations
 * identical; built with -ffp-contract=off so clang doesn't fuse them.
 */

#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

#define LOG_SEMITONE (0.69314718055994530942 / 12.0)

// Returns +narray+ as a contiguous 1D SFloat NArray of +length+ values (a
// copy if it wasn't one).  +name+ is for errors.
static VALUE read_sfloat(VALUE narray, size_t length, const char *name)
{
	if (!RTEST(rb_obj_is_kind_of(narray, cNArray))) {
		rb_raise(rb_eArgError, "%s must be an NArray", name);
	}
	if (RNARRAY_NDIM(narray) != 1 || RNARRAY_SHAPE(narray)[0] != length) {
		rb_raise(rb_eArgError, "%s must be a 1D NArray of %zu values", name, length);
	}

	if (CLASS_OF(narray) != numo_cSFloat) {
		narray = rb_funcall(numo_cSFloat, rb_intern("cast"), 1, narray);
	}
	if (!RTEST(nary_check_contiguous(narray))) {
		narray = nary_dup(narray);
	}

	return narray;
}

static const float *sfloat_ptr(VALUE narray)
{
	return (const float *)(nary_get_pointer_for_read(narray) + nary_get_offset(narray));
}

// Checks the output frame and returns its data; *count and *n get its shape.
static float *out_ptr(VALUE out, size_t *count, size_t *n)
{
	if (CLASS_OF(out) != numo_cSFloat || RNARRAY_NDIM(out) != 2) {
		rb_raise(rb_eArgError, "The output must be a 2D SFloat NArray (copies x samples)");
	}
	if (!RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "The output must be contiguous");
	}
	rb_check_frozen(out);

	*count = RNARRAY_SHAPE(out)[0];
	*n = RNARRAY_SHAPE(out)[1];

	return (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
}

// Reads the base frequency: a Numeric into *scalar (returning Qnil), else an
// NArray (returned, kept alive by the caller) whose data goes in *ptr.
static VALUE read_freq(VALUE freq, size_t n, double *scalar, const float **ptr)
{
	*ptr = NULL;
	*scalar = 0;

	if (RB_FLOAT_TYPE_P(freq) || RB_INTEGER_TYPE_P(freq)) {
		*scalar = NUM2DBL(freq);
		return Qnil;
	}

	freq = read_sfloat(freq, n, "The frequency");
	*ptr = sfloat_ptr(freq);
	return freq;
}

// Copies a Ruby Array of +count+ numbers into +values+.
static void read_doubles(VALUE ary, size_t count, double *values, const char *name)
{
	Check_Type(ary, T_ARRAY);
	if ((size_t)RARRAY_LEN(ary) != count) {
		rb_raise(rb_eArgError, "%s must have one value per copy (%zu; got %ld)", name, count, RARRAY_LEN(ary));
	}
	for (size_t i = 0; i < count; i++) {
		values[i] = NUM2DBL(rb_ary_entry(ary, i));
	}
}

static VALUE ruby_exact(VALUE self, VALUE out, VALUE freq, VALUE detune, VALUE fractions)
{
	size_t count, n;
	float *o = out_ptr(out, &count, &n);

	double f_scalar;
	const float *f;
	VALUE freq_ary = read_freq(freq, n, &f_scalar, &f);

	VALUE detune_ary = read_sfloat(detune, n, "The detune");
	const float *d = sfloat_ptr(detune_ary);

	VALUE frac_buf;
	double *frac = ALLOCV_N(double, frac_buf, count);
	read_doubles(fractions, count, frac, "fractions");

	for (size_t j = 0; j < n; j++) {
		double x = (double)d[j] * LOG_SEMITONE;
		double fj = f ? (double)f[j] : f_scalar;
		for (size_t i = 0; i < count; i++) {
			o[i * n + j] = (float)(fj * exp(frac[i] * x));
		}
	}

	ALLOCV_END(frac_buf);
	RB_GC_GUARD(freq_ary);
	RB_GC_GUARD(detune_ary);

	return Qnil;
}

static VALUE ruby_scale(VALUE self, VALUE out, VALUE freq, VALUE ratios)
{
	size_t count, n;
	float *o = out_ptr(out, &count, &n);

	double f_scalar;
	const float *f;
	VALUE freq_ary = read_freq(freq, n, &f_scalar, &f);

	VALUE ratio_buf;
	double *ratio = ALLOCV_N(double, ratio_buf, count);
	read_doubles(ratios, count, ratio, "ratios");

	for (size_t i = 0; i < count; i++) {
		float *row = o + i * n;
		for (size_t j = 0; j < n; j++) {
			double fj = f ? (double)f[j] : f_scalar;
			row[j] = (float)(fj * ratio[i]);
		}
	}

	ALLOCV_END(ratio_buf);
	RB_GC_GUARD(freq_ary);

	return Qnil;
}

// Writes copy frequencies for samples a...a+len of the frame (see interp),
// with the outermost ratio moving from r0 (exclusive) to r1, reaching
// r0 + (r1 - r0) * (ph + m) / steps at the m-th sample.
static void interp_segment(float *o, size_t count, size_t n, const double *u, const float *f, double f_scalar,
		size_t a, size_t len, double r0, double r1, size_t ph, size_t steps)
{
	for (size_t m = 1; m <= len; m++) {
		size_t j = a + m - 1;
		double t = (double)(ph + m) / (double)steps;
		double r = r0 + (r1 - r0) * t;
		double ir = 1.0 / r;
		double fj = f ? (double)f[j] : f_scalar;
		double lo = ir * fj;
		double span = (r - ir) * fj;

		for (size_t i = 0; i < count; i++) {
			o[i * n + j] = (float)(lo + u[i] * span);
		}
	}
}

static VALUE ruby_interp(VALUE self, VALUE out, VALUE freq, VALUE detune, VALUE positions, VALUE state, VALUE control)
{
	size_t count, n;
	float *o = out_ptr(out, &count, &n);

	double f_scalar;
	const float *f;
	VALUE freq_ary = read_freq(freq, n, &f_scalar, &f);

	VALUE detune_ary = read_sfloat(detune, n, "The detune");
	const float *d = sfloat_ptr(detune_ary);

	long k = NUM2LONG(control);
	if (k < 0) {
		rb_raise(rb_eArgError, "The control interval must not be negative");
	}

	if (CLASS_OF(state) != numo_cDFloat || RNARRAY_NDIM(state) != 1 || RNARRAY_SHAPE(state)[0] != 3 || !RTEST(nary_check_contiguous(state))) {
		rb_raise(rb_eArgError, "The state must be a contiguous DFloat of 3 values");
	}
	rb_check_frozen(state);
	double *st = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));

	VALUE pos_buf;
	double *u = ALLOCV_N(double, pos_buf, count);
	read_doubles(positions, count, u, "positions");

	if (k == 0) {
		// One control point per buffer, at its last sample
		if (n > 0) {
			double r1 = exp((double)d[n - 1] * LOG_SEMITONE);
			interp_segment(o, count, n, u, f, f_scalar, 0, n, st[0], r1, 0, n);
			st[0] = r1;
			st[1] = r1;
		}
	} else {
		// A control point every k samples of the stream (wherever buffers
		// start), each ramped to over the k samples after it
		double r_prev = st[0];
		double r_cur = st[1];
		size_t ph = (size_t)st[2];
		if (ph >= (size_t)k) {
			rb_raise(rb_eArgError, "The state's phase must be below the control interval");
		}

		for (size_t a = 0; a < n;) {
			if (ph == 0) {
				r_prev = r_cur;
				r_cur = exp((double)d[a] * LOG_SEMITONE);
			}

			size_t len = (size_t)k - ph;
			if (len > n - a) {
				len = n - a;
			}

			interp_segment(o, count, n, u, f, f_scalar, a, len, r_prev, r_cur, ph, (size_t)k);

			a += len;
			ph += len;
			if (ph == (size_t)k) {
				ph = 0;
			}
		}

		st[0] = r_prev;
		st[1] = r_cur;
		st[2] = (double)ph;
	}

	ALLOCV_END(pos_buf);
	RB_GC_GUARD(freq_ary);
	RB_GC_GUARD(detune_ary);

	return Qnil;
}

void Init_fast_unison(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_unison = rb_define_module_under(sound, "FastUnison");

	rb_define_module_function(fast_unison, "exact", ruby_exact, 4);
	rb_define_module_function(fast_unison, "scale", ruby_scale, 3);
	rb_define_module_function(fast_unison, "interp", ruby_interp, 6);
}
