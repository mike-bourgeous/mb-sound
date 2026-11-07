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
 * adaptive(x, out, from, to, state), curve(x, out, from, to, state,
 * slots, table), and damped(x, out, from, to, state): Notes::Smoother's
 * adaptive, curve, and damped kernels (see mb_smooth.h).  slew(data, s, max_rise, max_fall, absolute):
 * Filter::LinearFollower's slew limiter (delay-time smoothing, clip_rate).
 * inertia(x, out, first, lag, rate, substeps, state): GraphNode::Inertia's
 * acceleration-limited follower (the DirectX Distortion's "slew").
 *
 * The Ruby mirrors (Notes::Smoother.smooth_ruby and the others) give exactly the same
 * samples (specs check it), so keep the operations identical; built with
 * -ffp-contract=off like the other kernels (there are no products to fuse
 * here, but the flag keeps that true if the code changes).
 */

#include <math.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_smooth.h"

#define STATE_LENGTH 7
#define ADAPTIVE_STATE_LENGTH 8
#define CURVE_STATE_LENGTH 9
#define DAMPED_STATE_LENGTH 6

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

// damped(x, out, from, to, state): Notes::Smoother's damped kernel
// (mb_damped_run in mb_smooth.h; mirror Notes::Smoother.damped_ruby).
static VALUE ruby_damped(VALUE self, VALUE x, VALUE out, VALUE from_v, VALUE to_v, VALUE state)
{
	size_t length = check_array(x, numo_cSFloat, 0, "The input");
	if (check_array(out, numo_cSFloat, 0, "The output") != length) {
		rb_raise(rb_eArgError, "The output must have as many values as the input");
	}
	if (check_array(state, numo_cDFloat, DAMPED_STATE_LENGTH, "The state") != DAMPED_STATE_LENGTH) {
		rb_raise(rb_eArgError, "The damped state must have %d values", DAMPED_STATE_LENGTH);
	}
	rb_check_frozen(out);
	rb_check_frozen(state);

	long from = NUM2LONG(from_v);
	long to = NUM2LONG(to_v);
	if (from < 0 || to < from || (size_t)to > length) {
		rb_raise(rb_eRangeError, "Range %ld...%ld is outside the %zu-sample buffer", from, to, length);
	}

	const float *xp = (const float *)(nary_get_pointer_for_read(x) + nary_get_offset(x));
	mb_damped_run(xp, mb_sfloat_ptr(out), from, to, dfloat_ptr(state));

	return out;
}

// curve(x, out, from, to, state, slots, table): Notes::Smoother's curve
// kernel (mb_curve_smooth_run in mb_smooth.h; mirror
// Notes::Smoother.curve_ruby).
static VALUE ruby_curve(VALUE self, VALUE x, VALUE out, VALUE from_v, VALUE to_v, VALUE state, VALUE slots, VALUE table)
{
	size_t length = check_array(x, numo_cSFloat, 0, "The input");
	if (check_array(out, numo_cSFloat, 0, "The output") != length) {
		rb_raise(rb_eArgError, "The output must have as many values as the input");
	}
	if (check_array(state, numo_cDFloat, CURVE_STATE_LENGTH, "The state") != CURVE_STATE_LENGTH) {
		rb_raise(rb_eArgError, "The curve state must have %d values", CURVE_STATE_LENGTH);
	}
	size_t nslots = check_array(slots, numo_cDFloat, 2, "The slots");
	size_t ntable = check_array(table, numo_cDFloat, 1, "The table");
	rb_check_frozen(out);
	rb_check_frozen(state);
	rb_check_frozen(slots);

	long from = NUM2LONG(from_v);
	long to = NUM2LONG(to_v);
	if (from < 0 || to < from || (size_t)to > length) {
		rb_raise(rb_eRangeError, "Range %ld...%ld is outside the %zu-sample buffer", from, to, length);
	}

	const float *xp = (const float *)(nary_get_pointer_for_read(x) + nary_get_offset(x));
	const double *tp = (const double *)(nary_get_pointer_for_read(table) + nary_get_offset(table));
	if (mb_curve_smooth_run(xp, mb_sfloat_ptr(out), from, to, dfloat_ptr(state), dfloat_ptr(slots), nslots, tp, ntable) != 0) {
		rb_raise(rb_eArgError, "The curve state doesn't fit %zu slot values and a %zu-value table", nslots, ntable);
	}

	return out;
}

// slew(data, s, max_rise, max_fall, absolute): Filter::LinearFollower's
// slew limiter over +data+ (a contiguous SFloat or DFloat, changed in
// place) from the last output +s+, with per-sample limits (nil: none);
// returns the new last output (see mb_slew_run).
static VALUE ruby_slew(VALUE self, VALUE data, VALUE s_v, VALUE rise_v, VALUE fall_v, VALUE absolute)
{
	VALUE klass = CLASS_OF(data);
	if ((klass != numo_cSFloat && klass != numo_cDFloat) || RNARRAY_NDIM(data) != 1 || !RTEST(nary_check_contiguous(data))) {
		rb_raise(rb_eArgError, "Slew data must be a contiguous 1D SFloat or DFloat");
	}
	rb_check_frozen(data);
	size_t n = RNARRAY_SHAPE(data)[0];
	double s = NUM2DBL(s_v);
	double rise = NIL_P(rise_v) ? INFINITY : NUM2DBL(rise_v);
	double fall = NIL_P(fall_v) ? INFINITY : NUM2DBL(fall_v);
	void *p = nary_get_pointer_for_write(data) + nary_get_offset(data);
	mb_slew_run(p, p, n, klass == numo_cDFloat, &s, rise, fall, RTEST(absolute));
	RB_GC_GUARD(data);
	return DBL2NUM(s);
}

/*
 * inertia(x, out, first, lag, rate, substeps, state): GraphNode::Inertia,
 * a deadbeat second-order follower whose change of velocity per substep is
 * clamped to +-rate (full-scale units), run +substeps+ times per sample:
 *   d = clamp((u - y) - v, -rate, rate); v += d; y += v
 * for substep inputs u from a (the first substep's input) to x[i] (the
 * last), linearly between them (k / (substeps - 1)); out[i] = y after the
 * last.  a is +first+[i] (an SFloat at least as long as x, or nil for x
 * itself) with +lag+ 0, or the previous sample of it with +lag+ 1 (from
 * +state+ at the buffer's start).  Unclamped, y lands on u in one substep,
 * so slow and quiet signals pass exactly; fast loud ones overshoot into
 * limit cycles.  +rate+ is a signal input (a Numeric or an NArray read as
 * float32), taken as 0 below 0 (or NaN).  +state+ is a DFloat [y, v,
 * previous first-substep source], updated in place.  Double precision
 * (the limit cycles are chaotic: float32 parts from it audibly in nulls).
 * Mirror: GraphNode::Inertia.process_ruby, the same operations.
 */
static VALUE ruby_inertia(VALUE self, VALUE x, VALUE out, VALUE first, VALUE lag_v, VALUE rate, VALUE substeps_v, VALUE state)
{
	size_t length = check_array(x, numo_cSFloat, 0, "The input");
	if (check_array(out, numo_cSFloat, 0, "The output") != length) {
		rb_raise(rb_eArgError, "The output must have as many values as the input");
	}
	const float *fp = NULL;
	if (!NIL_P(first)) {
		check_array(first, numo_cSFloat, length, "The first-substep input");
		fp = (const float *)(nary_get_pointer_for_read(first) + nary_get_offset(first));
	}
	check_array(state, numo_cDFloat, 3, "The state");
	rb_check_frozen(out);
	rb_check_frozen(state);
	long substeps = NUM2LONG(substeps_v);
	if (substeps < 1 || substeps > 1024) {
		rb_raise(rb_eArgError, "Substeps must be 1 to 1024 (got %ld)", substeps);
	}
	int lag = NUM2INT(lag_v);
	if (lag != 0 && lag != 1) {
		rb_raise(rb_eArgError, "The lag must be 0 or 1 (got %d)", lag);
	}
	struct mb_signal r;
	mb_signal_input(&rate, length, "The rate", &r);

	double *st = dfloat_ptr(state);
	double y = st[0], v = st[1], prev = st[2];
	const float *xp = (const float *)(nary_get_pointer_for_read(x) + nary_get_offset(x));
	float *op = mb_sfloat_ptr(out);
	double last = (double)(substeps - 1);

	for (size_t i = 0; i < length; i++) {
		double xn = xp[i];
		double src = fp ? (double)fp[i] : xn;
		double a = lag ? prev : src;
		prev = src;
		double aa = mb_signal_at(&r, i);
		if (!(aa > 0)) {
			aa = 0;
		}
		for (long k = 0; k < substeps; k++) {
			double u = k == substeps - 1 ? xn : (k == 0 ? a : a + (xn - a) * (double)k / last);
			double d = (u - y) - v;
			if (d > aa) {
				d = aa;
			} else if (d < -aa) {
				d = -aa;
			}
			v += d;
			y += v;
		}
		op[i] = (float)y;
	}

	st[0] = y;
	st[1] = v;
	st[2] = prev;

	RB_GC_GUARD(x);
	RB_GC_GUARD(out);
	RB_GC_GUARD(first);
	RB_GC_GUARD(rate);
	RB_GC_GUARD(state);

	return out;
}

// reset_run(x, out, state, ring1, ring2, reset): Notes::Smoother over all
// of x into out (SFloat) with the kernel the state's length picks, jumping
// to the input at every nonzero sample of +reset+ (an SFloat at least as
// long, or nil): Filter::Smooth#dynamic_process (GraphNode#smooth with
// reset:), as the plan op runs it (mb_smoother_reset_run; mirror
// Notes::Smoother.run with the reset's nonzero offsets as jumps).
static VALUE ruby_reset_run(VALUE self, VALUE x, VALUE out, VALUE state, VALUE ring1, VALUE ring2, VALUE reset)
{
	size_t length = check_array(x, numo_cSFloat, 0, "The input");
	if (check_array(out, numo_cSFloat, 0, "The output") != length) {
		rb_raise(rb_eArgError, "The output must have as many values as the input");
	}
	size_t sl = check_array(state, numo_cDFloat, DAMPED_STATE_LENGTH, "The state");
	if (sl != STATE_LENGTH && sl != ADAPTIVE_STATE_LENGTH && sl != CURVE_STATE_LENGTH && sl != DAMPED_STATE_LENGTH) {
		rb_raise(rb_eArgError, "The state must have 6, 7, 8, or 9 values (got %zu)", sl);
	}
	size_t n1 = check_array(ring1, numo_cDFloat, 1, "Ring 1");
	size_t n2 = check_array(ring2, numo_cDFloat, 1, "Ring 2");
	const float *rp = NULL;
	if (!NIL_P(reset)) {
		if (check_array(reset, numo_cSFloat, length, "The reset") < length) {
			rb_raise(rb_eArgError, "The reset must be at least as long as the input");
		}
		rp = (const float *)(nary_get_pointer_for_read(reset) + nary_get_offset(reset));
	}
	rb_check_frozen(out);
	rb_check_frozen(state);
	rb_check_frozen(ring1);
	rb_check_frozen(ring2);

	const float *xp = (const float *)(nary_get_pointer_for_read(x) + nary_get_offset(x));
	if (mb_smoother_reset_run(sl, xp, mb_sfloat_ptr(out), rp, (long)length, dfloat_ptr(state), dfloat_ptr(ring1), n1, dfloat_ptr(ring2), n2) != 0) {
		rb_raise(rb_eArgError, "The smoother state doesn't fit its rings");
	}

	RB_GC_GUARD(reset);
	return out;
}

void Init_fast_control(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_control = rb_define_module_under(sound, "FastControl");

	rb_define_module_function(fast_control, "smooth", ruby_smooth, 7);
	rb_define_module_function(fast_control, "adaptive", ruby_adaptive, 5);
	rb_define_module_function(fast_control, "curve", ruby_curve, 7);
	rb_define_module_function(fast_control, "damped", ruby_damped, 5);
	rb_define_module_function(fast_control, "slew", ruby_slew, 5);
	rb_define_module_function(fast_control, "reset_run", ruby_reset_run, 6);
	rb_define_module_function(fast_control, "inertia", ruby_inertia, 7);
}
