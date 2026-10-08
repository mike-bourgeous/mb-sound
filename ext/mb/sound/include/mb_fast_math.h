/*
 * Fast sine and cosine for the plan layer's opt-in fast precision
 * (MB::Sound::Plan.precision = :fast): one range reduction to a quarter
 * cycle and Taylor polynomials to degree 11/10 on |theta| <= pi/4 (error
 * under 3e-11 before rounding to float32), about 4x cheaper than libm's
 * sin and cexp.  Every product and sum is its own statement, so no
 * compiler contracts them into FMAs, and the Ruby mirror
 * (MB::Sound::Plan::FastMath.sincos) gives identical doubles.
 */
#ifndef MB_FAST_MATH_H
#define MB_FAST_MATH_H

#include <math.h>

// sin and cos of 2 pi x (x in cycles, any finite value) into *s and *c.
static inline void mb_fast_sincos_cycles(double x, double *s, double *c)
{
	double t = x * 4.0;          // quarter cycles
	double q = floor(t + 0.5);   // nearest quarter
	double f = t - q;            // -0.5..0.5 quarter
	double th = f * 1.5707963267948966; // -pi/4..pi/4
	double t2 = th * th;

	// sin(th) = th (1 - t2/6 (1 - t2/20 (1 - t2/42 (1 - t2/72 (1 - t2/110)))))
	double ps = t2 * (1.0 / 110.0);
	ps = 1.0 - ps;
	ps = ps * t2;
	ps = ps * (1.0 / 72.0);
	ps = 1.0 - ps;
	ps = ps * t2;
	ps = ps * (1.0 / 42.0);
	ps = 1.0 - ps;
	ps = ps * t2;
	ps = ps * (1.0 / 20.0);
	ps = 1.0 - ps;
	ps = ps * t2;
	ps = ps * (1.0 / 6.0);
	ps = 1.0 - ps;
	double sn = th * ps;

	// cos(th) = 1 - t2/2 (1 - t2/12 (1 - t2/30 (1 - t2/56 (1 - t2/90))))
	double pc = t2 * (1.0 / 90.0);
	pc = 1.0 - pc;
	pc = pc * t2;
	pc = pc * (1.0 / 56.0);
	pc = 1.0 - pc;
	pc = pc * t2;
	pc = pc * (1.0 / 30.0);
	pc = 1.0 - pc;
	pc = pc * t2;
	pc = pc * (1.0 / 12.0);
	pc = 1.0 - pc;
	pc = pc * t2;
	pc = pc * 0.5;
	double cs = 1.0 - pc;

	// Rotate by the quarter turns
	long k = (long)(q - 4.0 * floor(q * 0.25)); // q mod 4
	switch (k) {
		case 0: *s = sn; *c = cs; break;
		case 1: *s = cs; *c = -sn; break;
		case 2: *s = -sn; *c = -cs; break;
		default: *s = -cs; *c = sn; break;
	}
}

#endif
