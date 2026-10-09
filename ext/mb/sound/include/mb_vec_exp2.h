/*
 * A vectorizable 2^x for the plan layer's default precision (Plan.precision
 * :fast): note frequencies (Op::NoteFreq, tune_freq * 2^((n - note) / 12))
 * and powers of a patch-constant base (Op::Pow with a Constant base,
 * a^b = 2^(b log2 a)), replacing libm's pow per sample.  Branch-free (GCC
 * and clang vectorize the loops at the extensions' flags): x is clamped to
 * +/-MB_EXP2_LIMIT (beyond it every float result is already 0 or
 * infinite), rounded to k + f with the magic-number trick (|f| <= 0.5), 2^f
 * by a degree-11 Taylor polynomial of e^(f ln 2) (relative error under
 * 2e-16), and 2^k built in the exponent bits.  The results, cast to float,
 * matched libm's on every value tested (research-fused-ops 3b8c8b7f: notes
 * 0..127 with bend steps, 10^x for x in -3..3; 383k values); the plan
 * layer still counts them as within a tolerance (Op::NoteFreq#tolerance).
 *
 * Every operation is its own statement in double (no contraction; see
 * mb_vec_sine.h), so the Ruby mirror (Plan::VecExp2) gives identical values:
 * 2^k as a power of two (exact) times the polynomial.
 */
#ifndef MB_VEC_EXP2_H
#define MB_VEC_EXP2_H

#include <stdint.h>
#include <string.h>
#include <math.h>
#include <stddef.h>

#include "mb_vec_sine.h"

// |x| limit: 2^200 overflows float, 2^-200 is below float's smallest
// subnormal, so every float result matches libm's 0 or infinity there.
#define MB_EXP2_LIMIT 200.0

// ln 2 and the Taylor coefficients 1/n! (n = 11 down to 2)
#define MB_EXP2_LN2 0.6931471805599453
#define MB_EXP2_C11 (1.0 / 39916800.0)
#define MB_EXP2_C10 (1.0 / 3628800.0)
#define MB_EXP2_C9 (1.0 / 362880.0)
#define MB_EXP2_C8 (1.0 / 40320.0)
#define MB_EXP2_C7 (1.0 / 5040.0)
#define MB_EXP2_C6 (1.0 / 720.0)
#define MB_EXP2_C5 (1.0 / 120.0)
#define MB_EXP2_C4 (1.0 / 24.0)
#define MB_EXP2_C3 (1.0 / 6.0)

// 2^x for one double (vectorized when inlined into a loop).
static inline double mb_vec_exp2(double x)
{
	MB_VEC_NO_CONTRACT
	x = x < -MB_EXP2_LIMIT ? -MB_EXP2_LIMIT : x;
	x = x > MB_EXP2_LIMIT ? MB_EXP2_LIMIT : x;
	double m = x + MB_VEC_ROUND;
	double kf = m - MB_VEC_ROUND;
	double f = x - kf;
	f = f * MB_EXP2_LN2;
	double p = MB_EXP2_C11 * f;
	p = p + MB_EXP2_C10;
	p = p * f;
	p = p + MB_EXP2_C9;
	p = p * f;
	p = p + MB_EXP2_C8;
	p = p * f;
	p = p + MB_EXP2_C7;
	p = p * f;
	p = p + MB_EXP2_C6;
	p = p * f;
	p = p + MB_EXP2_C5;
	p = p * f;
	p = p + MB_EXP2_C4;
	p = p * f;
	p = p + MB_EXP2_C3;
	p = p * f;
	p = p + 0.5;
	p = p * f;
	p = p + 1.0;
	p = p * f;
	p = p + 1.0;

	// m's low mantissa bits hold k (two's complement offset from 1.5 * 2^52)
	uint64_t mb, sb;
	double s;
	memcpy(&mb, &m, sizeof(mb));
	sb = (mb - UINT64_C(0x4338000000000000) + 1023) << 52;
	memcpy(&s, &sb, sizeof(s));
	return p * s;
}

// d[i] = (float)(tfrq * 2^((a[i] - tnum) / 12)) (Op::NoteFreq).
static inline void mb_vec_note_freq(float *restrict d, const float *restrict a, size_t n, double tnum, double tfrq)
{
	MB_VEC_NO_CONTRACT
	for (size_t i = 0; i < n; i++) {
		double x = (double)a[i] - tnum;
		x = x / 12.0;
		double e = mb_vec_exp2(x);
		d[i] = (float)(tfrq * e);
	}
}

// d[i] = (float)a[i]^b[i] (Op::Pow): 2^(b log2 a) where a is positive and
// finite and b finite (log2 recomputed only when a changes, as a patch
// constant base rarely does; Plan::Program lowers to this only for a
// Constant base), libm's pow elsewhere (the cases where 2^(b log2 a)
// differs from pow: a <= 0, a infinite, a = 1 with b infinite, NaNs).
static inline void mb_vec_pow(float *restrict d, const float *restrict a, const float *restrict b, size_t n)
{
	MB_VEC_NO_CONTRACT
	double x[MB_VEC_CHUNK];
	double la = 0.0;
	float last = NAN;
	for (size_t start = 0; start < n; start += MB_VEC_CHUNK) {
		size_t m = n - start < MB_VEC_CHUNK ? n - start : MB_VEC_CHUNK;
		const float *A = a + start, *B = b + start;
		float *D = d + start;
		size_t bad = 0;

		for (size_t i = 0; i < m; i++) {
			float av = A[i];
			double bv = B[i];
			if (!(av > 0.0f && av < INFINITY && isfinite(bv))) {
				x[i] = 0.0;
				bad++;
				continue;
			}
			if (av != last) {
				last = av;
				la = log2((double)av);
			}
			x[i] = bv * la;
		}

		for (size_t i = 0; i < m; i++) {
			D[i] = (float)mb_vec_exp2(x[i]);
		}

		if (bad) {
			for (size_t i = 0; i < m; i++) {
				float av = A[i];
				if (!(av > 0.0f && av < INFINITY && isfinite((double)B[i]))) {
					D[i] = pow(av, B[i]);
				}
			}
		}
	}
}

#endif
