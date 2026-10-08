/*
 * A vectorizable sine for the plan layer's default precision (Plan.precision
 * :fast): a phase pass (serial, double precision, the naive oscillator's
 * exact phases) reduces each sample's phase plus phase modulation to
 * -0.5..0.5 cycles as a float, then this shape pass runs a branch-free
 * float polynomial that GCC and clang vectorize at the extensions' flags
 * (SSE2 on x86-64, NEON on aarch64): fold to a quarter cycle with
 * fabsf/copysignf, then an odd Taylor polynomial to t^11.  Within about
 * 5e-7 of libm's sine (-126 dB; research/plan-optimizations on branch
 * research-plan-optimizations, 5f5cb7b6), 6x cheaper per sample.
 *
 * Every operation is its own statement in float, and MB_VEC_NO_CONTRACT
 * keeps clang from contracting them (GCC with -std=c99 doesn't), so the
 * Ruby mirror (Plan::VecSine.shape_ruby, Numo SFloat arithmetic) gives
 * identical floats.
 */
#ifndef MB_VEC_SINE_H
#define MB_VEC_SINE_H

#include <math.h>
#include <stddef.h>

#if defined(__clang__)
#define MB_VEC_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define MB_VEC_NO_CONTRACT
#endif

// Samples per pass (the phase and shape buffers live on the stack).
#define MB_VEC_CHUNK 256

// 1.5 * 2^52: (x + MB_VEC_ROUND) - MB_VEC_ROUND rounds a double to the
// nearest integer (|x| < 2^51, the default rounding mode).
#define MB_VEC_ROUND 6755399441055744.0

// The polynomial's coefficients (odd Taylor terms of sin, -1/3! to -1/11!)
// and 2 pi, written as the exact float values (shortest decimals), so the
// Ruby mirror's Floats cast to the same floats.
#define MB_VEC_S3 -0.166666672f
#define MB_VEC_S5 0.00833333377f
#define MB_VEC_S7 -0.000198412701f
#define MB_VEC_S9 2.75573188e-06f
#define MB_VEC_S11 -2.50521079e-08f
#define MB_VEC_TWO_PI 6.28318548f

// The reduced phase of +r+ cycles: r minus its nearest integer, as a
// float in -0.5..0.5.
static inline float mb_vec_reduce(double r)
{
	MB_VEC_NO_CONTRACT
	double k = (r + MB_VEC_ROUND) - MB_VEC_ROUND;
	return (float)(r - k);
}

// o[i] = sin(2 pi x[i]) * g + off for x in -0.5..0.5 cycles, in float.
static inline void mb_vec_sine_shape(float *restrict o, const float *restrict x, size_t m, float g, float off)
{
	MB_VEC_NO_CONTRACT
	for (size_t i = 0; i < m; i++) {
		float v = x[i];
		float a = fabsf(v);
		a = 0.25f - a;
		a = fabsf(a);
		a = 0.25f - a;           // folded to 0..0.25 (sin(pi - y) = sin(y))
		float f = copysignf(a, v);
		float t = f * MB_VEC_TWO_PI;
		float t2 = t * t;
		float p = MB_VEC_S11 * t2;
		p = p + MB_VEC_S9;
		p = p * t2;
		p = p + MB_VEC_S7;
		p = p * t2;
		p = p + MB_VEC_S5;
		p = p * t2;
		p = p + MB_VEC_S3;
		p = p * t2;
		p = p * t;
		float s = t + p;
		s = s * g;
		o[i] = s + off;
	}
}

#endif
