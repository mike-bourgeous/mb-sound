/*
 * The antialiased waveshapers of FastClip.shape (soft clip, hard clip,
 * absolute value, quantize; see fast_clip.c's top comment), shared by
 * fast_clip.c and the plan executor (fast_plan.c) so both run the same
 * code.  Moved here from fast_clip.c (2026-10-08, plan layer).
 */
#ifndef MB_CLIP_SHAPE_H
#define MB_CLIP_SHAPE_H

#include <math.h>

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

// Sets up +cp+ for +mode+ with parameters +p1+ and +p2+ (see
// FastClip.shape), returning NULL, or an error message for bad parameters.
static inline const char *mb_clip_setup(struct clip_params *cp, enum clip_mode mode, double p1, double p2)
{
	cp->mode = mode;
	cp->p1 = p1;
	cp->p2 = p2;
	cp->a = cp->b = cp->c = cp->k = 0;

	switch (mode) {
		case CLIP_SOFT: {
			double t = fabs(p1), l = fabs(p2);
			if (l < t) {
				return "Limit must be greater than or equal to threshold";
			}
			cp->p1 = t;
			cp->a = -(l - t) * (l - t);
			cp->b = l;
			cp->c = l - 2.0 * t;
			cp->k = 0.5 * t * t - cp->b * t - (cp->a != 0 ? cp->a * log(t + cp->c) : 0);
			return NULL;
		}

		case CLIP_HARD:
			return p2 < p1 ? "Clip max must be greater than or equal to min" : NULL;

		case CLIP_ABS:
			return NULL;

		case CLIP_QUANTIZE:
			return !(p1 > 0) || !isfinite(p1) ? "Quantize step must be positive and finite" : NULL;
	}

	return "Unknown shaper";
}

// The shaper loop: +length+ samples of +in+ into +out+ (which may be +in+),
// with ADAA if +aa+, updating the state (last input, allpass last input
// and output, primed) as FastClip.shape does.
static inline void mb_clip_run(const struct clip_params *cp, const float *in, float *out, size_t length, _Bool aa,
		double *x1p, double *ap_x1p, double *ap_y1p, _Bool *primedp)
{
	double x1 = *x1p, ap_x1 = *ap_x1p, ap_y1 = *ap_y1p;
	_Bool primed = *primedp;

	for (size_t i = 0; i < length; i++) {
		double x = in[i];

		if (!aa) {
			out[i] = clip_f(cp, x);
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
			g = clip_f(cp, m) - m;
		} else {
			g = (clip_g_integral(cp, x) - clip_g_integral(cp, x1)) / d;
		}

		double dry = CLIP_ALLPASS * x + ap_x1 - CLIP_ALLPASS * ap_y1;
		ap_x1 = x;
		ap_y1 = dry;
		x1 = x;

		out[i] = dry + g;
	}

	*x1p = x1;
	*ap_x1p = ap_x1;
	*ap_y1p = ap_y1;
	*primedp = primed;
}

#endif
