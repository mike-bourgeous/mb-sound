/*
 * The derivative and integral kernels of MB::Sound::FastControl.derivative
 * and .integral (GraphNode::Derivative and GraphNode::Integral), shared with
 * the plan layer executor (fast_plan's OP_DERIVATIVE and OP_INTEGRAL) so a
 * planned node runs exactly the same arithmetic.  The Ruby mirrors are
 * GraphNode::Derivative.process_ruby and GraphNode::Integral.process_ruby,
 * which specs compare for equality: keep the operations identical.
 *
 * fast_control is built with -ffp-contract=off and fast_plan isn't, so the
 * kernels turn contraction off for clang by pragma; GCC with -std=c99 (both
 * extensions) doesn't contract.
 */
#ifndef MB_CALCULUS_H
#define MB_CALCULUS_H

#include <math.h>
#include <stddef.h>

#if defined(__clang__)
#define MB_CALCULUS_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define MB_CALCULUS_NO_CONTRACT
#endif

// Values in a derivative's state: the previous input, the one before it,
// and 1 once the first sample has been seen (before it both read as the
// first sample, so a signal starting away from zero gives no jump).
#define MB_DERIVATIVE_STATE_LENGTH 3

// Values in a derivative's settings: 1 for a central difference, 0 for a
// backward difference; the scale (the sample rate per second, 1 per sample,
// halved for a central difference).
#define MB_DERIVATIVE_SETTINGS_LENGTH 2

// Values in an integral's state: the running sum; the reset trigger's last
// sample.
#define MB_INTEGRAL_STATE_LENGTH 2

// Values in an integral's settings: the scale (1 / the sample rate per
// second, 1 per sample); the leak factor per sample (1 for no leak); 1 to
// clamp to lo..hi, else 0; lo; hi.
#define MB_INTEGRAL_SETTINGS_LENGTH 5

// A leaking sum smaller than this is flushed to zero, so silence never runs
// into subnormal numbers (never without a leak: a true sum stays exact).
#define MB_INTEGRAL_FLUSH 1e-30

/*
 * The slope of x into d (n samples): x[i] - x[i - 1] (backward), or
 * (x[i] - x[i - 2]) / 2 (central: the slope at the sample before, one sample
 * late), times the scale, in double precision, rounded to float.  +st+
 * holds the previous inputs (see MB_DERIVATIVE_STATE_LENGTH).
 */
static inline void mb_derivative(float *d, const float *x, double *st, int central, double scale, size_t n)
{
	MB_CALCULUS_NO_CONTRACT
	double x1 = st[0], x2 = st[1];
	int primed = st[2] != 0;
	for (size_t i = 0; i < n; i++) {
		double xn = x[i];
		if (!primed) {
			x1 = xn;
			x2 = xn;
			primed = 1;
		}
		double back = central ? x2 : x1;
		d[i] = (float)((xn - back) * scale);
		x2 = x1;
		x1 = xn;
	}
	st[0] = x1;
	st[1] = x2;
	st[2] = primed ? 1.0 : 0.0;
}

/*
 * The running sum of x into d (n samples): y = y * leak + x[i] * scale in
 * double precision, rounded to float; the sum restarts at zero on each
 * rising edge of +reset+ (a sample > 0 after one <= 0; NULL for no resets)
 * before that sample is added, and is clamped to lo..hi after each step if
 * +clamp+.  +st+ holds the sum and the trigger's last sample (see
 * MB_INTEGRAL_STATE_LENGTH).
 */
static inline void mb_integral(float *d, const float *x, const float *reset, double *st, double scale, double leak, int clamp, double lo, double hi, size_t n)
{
	MB_CALCULUS_NO_CONTRACT
	double y = st[0];
	double prev = st[1];
	int leaking = leak != 1.0;
	for (size_t i = 0; i < n; i++) {
		if (reset) {
			double t = reset[i];
			if (t > 0 && !(prev > 0)) {
				y = 0.0;
			}
			prev = t;
		}
		double scaled = (double)x[i] * scale;
		y = y * leak;
		y = y + scaled;
		if (clamp) {
			if (y < lo) {
				y = lo;
			} else if (y > hi) {
				y = hi;
			}
		}
		if (leaking && fabs(y) < MB_INTEGRAL_FLUSH) {
			y = 0.0;
		}
		d[i] = (float)y;
	}
	st[0] = y;
	st[1] = prev;
}

#endif
