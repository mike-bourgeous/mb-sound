/*
 * MB::Sound::FastClip: waveshapers (soft clip, hard clip, absolute value,
 * quantize) with antiderivative antialiasing (ADAA).
 *
 * A nonlinearity f creates harmonics above Nyquist that fold back down.
 * First-order ADAA replaces f(x[n]) with the average of f between the last
 * two inputs, (F(x[n]) - F(x[n-1])) / (x[n] - x[n-1]) where F is the
 * antiderivative of f: a one-sample boxcar applied before sampling, which
 * suppresses the aliases (most of all those below the fundamental) at about
 * the cost of the plain shaper, with half a sample of delay.
 *
 * Plain ADAA also averages the unclipped signal (-6 dB at 16 kHz), so each
 * shaper is split into x + g(x), where g = f - x is zero wherever the shaper
 * is linear: ADAA is applied to g only (antiderivative G = F - x^2/2), and x
 * goes through a first-order Thiran allpass with half a sample of delay, so
 * the dry signal stays flat in level and lines up with the ADAA path.
 *
 * Without antialiasing (+antialias+ false) the plain shaper is applied.  The
 * Ruby mirror is MB::Sound::Shaper (lib/mb/sound/shaper.rb); specs check that
 * both give the same samples.
 */

#include <stdlib.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

// Inputs closer than this use the shaper at their midpoint instead of the
// divided difference.
#define CLIP_TINY 1e-6

// Coefficient of the half-sample Thiran allpass: (1 - D) / (1 + D), D = 0.5.
#define CLIP_ALLPASS (1.0 / 3.0)

enum clip_mode {
	CLIP_SOFT,
	CLIP_HARD,
	CLIP_ABS,
	CLIP_QUANTIZE,
};

static ID sym_softclip, sym_clip, sym_abs, sym_quantize;

struct clip_params {
	enum clip_mode mode;
	double p1, p2;        // softclip: threshold, limit; clip: min, max; quantize: step
	double a, b, c, k;    // softclip curve and antiderivative constant
};

// The shaper.
static inline double clip_f(const struct clip_params *cp, double x)
{
	switch (cp->mode) {
		case CLIP_SOFT: {
			double ax = fabs(x);
			if (ax <= cp->p1) {
				return x;
			}
			double v = cp->a / (ax + cp->c) + cp->b;
			return x < 0 ? -v : v;
		}

		case CLIP_HARD:
			return x < cp->p1 ? cp->p1 : (x > cp->p2 ? cp->p2 : x);

		case CLIP_ABS:
			return fabs(x);

		case CLIP_QUANTIZE:
			return cp->p1 * floor(x / cp->p1 + 0.5);
	}

	return x;
}

// The antiderivative of g = f - x (G = F - x^2 / 2), written to keep
// precision where g is small.
static inline double clip_g_integral(const struct clip_params *cp, double x)
{
	switch (cp->mode) {
		case CLIP_SOFT: {
			double ax = fabs(x);
			if (ax <= cp->p1) {
				return 0;
			}
			double f = cp->b * ax + cp->k - 0.5 * x * x;
			if (cp->a != 0) {
				f += cp->a * log(ax + cp->c);
			}
			return f;
		}

		case CLIP_HARD:
			if (x > cp->p2) {
				double d = x - cp->p2;
				return -0.5 * d * d;
			} else if (x < cp->p1) {
				double d = x - cp->p1;
				return -0.5 * d * d;
			}
			return 0;

		case CLIP_ABS:
			return x < 0 ? -x * x : 0;

		case CLIP_QUANTIZE: {
			double d = x - cp->p1 * floor(x / cp->p1 + 0.5);
			return -0.5 * d * d;
		}
	}

	return 0;
}

/*
 * Applies a shaper to +buffer+ (SFloat, modified in place if marked
 * inplace):
 *   shape(buffer, mode, p1, p2, antialias, state)
 * +mode+ is :softclip (p1 threshold, p2 limit), :clip (p1 min, p2 max;
 * infinite for none), :abs, or :quantize (p1 step).  +state+ is [last
 * input, allpass last input, allpass last output, primed (0 or 1)].
 */
static VALUE ruby_shape(VALUE self, VALUE buffer, VALUE mode, VALUE p1v, VALUE p2v, VALUE antialias, VALUE state)
{
	struct clip_params cp = { .p1 = NUM2DBL(p1v), .p2 = NUM2DBL(p2v) };

	ID id = SYM2ID(mode);
	if (id == sym_softclip) {
		cp.mode = CLIP_SOFT;
		double t = fabs(cp.p1), l = fabs(cp.p2);
		if (l < t) {
			rb_raise(rb_eArgError, "Limit must be greater than or equal to threshold");
		}
		cp.p1 = t;
		cp.a = -(l - t) * (l - t);
		cp.b = l;
		cp.c = l - 2.0 * t;
		cp.k = 0.5 * t * t - cp.b * t - (cp.a != 0 ? cp.a * log(t + cp.c) : 0);
	} else if (id == sym_clip) {
		cp.mode = CLIP_HARD;
		if (cp.p2 < cp.p1) {
			rb_raise(rb_eArgError, "Clip max must be greater than or equal to min");
		}
	} else if (id == sym_abs) {
		cp.mode = CLIP_ABS;
	} else if (id == sym_quantize) {
		cp.mode = CLIP_QUANTIZE;
		if (!(cp.p1 > 0) || !isfinite(cp.p1)) {
			rb_raise(rb_eArgError, "Quantize step must be positive and finite");
		}
	} else {
		rb_raise(rb_eArgError, "Unknown shaper %"PRIsVALUE, mode);
	}

	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) {
		rb_raise(rb_eArgError, "Shaper state must have four elements");
	}
	double x1 = NUM2DBL(rb_ary_entry(state, 0));
	double ap_x1 = NUM2DBL(rb_ary_entry(state, 1));
	double ap_y1 = NUM2DBL(rb_ary_entry(state, 2));
	_Bool primed = NUM2INT(rb_ary_entry(state, 3)) != 0;
	_Bool aa = RTEST(antialias);

	_Bool was_inplace;
	mb_ensure_inplace_sfloat(&buffer, &was_inplace);
	size_t length = RNARRAY_SHAPE(buffer)[0];
	float *data = mb_sfloat_ptr(buffer);

	for (size_t i = 0; i < length; i++) {
		double x = data[i];

		if (!aa) {
			data[i] = clip_f(&cp, x);
			continue;
		}

		if (!primed) {
			x1 = x;
			ap_x1 = x;
			ap_y1 = x;
			primed = 1;
		}

		double d = x - x1;
		double g;
		if (fabs(d) < CLIP_TINY) {
			double m = 0.5 * (x + x1);
			g = clip_f(&cp, m) - m;
		} else {
			g = (clip_g_integral(&cp, x) - clip_g_integral(&cp, x1)) / d;
		}

		double dry = CLIP_ALLPASS * x + ap_x1 - CLIP_ALLPASS * ap_y1;
		ap_x1 = x;
		ap_y1 = dry;
		x1 = x;

		data[i] = dry + g;
	}

	if (aa && length > 0) {
		rb_ary_store(state, 0, rb_float_new(x1));
		rb_ary_store(state, 1, rb_float_new(ap_x1));
		rb_ary_store(state, 2, rb_float_new(ap_y1));
		rb_ary_store(state, 3, INT2NUM(1));
	}

	if (!was_inplace) {
		UNSET_INPLACE(buffer);
	}

	RB_GC_GUARD(buffer);

	return buffer;
}

void Init_fast_clip(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_clip = rb_define_module_under(sound, "FastClip");

	sym_softclip = rb_intern("softclip");
	sym_clip = rb_intern("clip");
	sym_abs = rb_intern("abs");
	sym_quantize = rb_intern("quantize");

	rb_define_module_function(fast_clip, "shape", ruby_shape, 6);
}
