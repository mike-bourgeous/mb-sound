/*
 * MB::Sound::Notes::Smoother's filter (FastControl.smooth; see
 * fast_control.c for the algorithm), shared with the plan layer executor
 * (fast_plan) so a planned controller smooths exactly as the node does.
 * The Ruby mirror is Notes::Smoother.smooth_ruby.  No products, so
 * contraction can't change it.
 */
#ifndef MB_SMOOTH_H
#define MB_SMOOTH_H

#include <stddef.h>
#include <string.h>

// Smooths xp[from...to] into op[from...to] with the state st (7 doubles:
// ref, last, sum1, sum2, p1, p2, since) and rings r1 (n1) and r2 (n2).
// Returns 0, or -1 (nothing done) if the ring positions are out of range.
static inline int mb_smooth_run(const float *xp, float *op, long from, long to, double *st, double *r1, size_t n1, double *r2, size_t n2)
{
	double ref = st[0];
	double last = st[1];
	double s1 = st[2];
	double s2 = st[3];
	size_t p1 = (size_t)st[4];
	size_t p2 = (size_t)st[5];
	double since = st[6];
	double settle = (double)(n1 + n2 - 2);
	double d1 = (double)n1;
	double d2 = (double)n2;
	if (p1 >= n1 || p2 >= n2) {
		return -1;
	}

	for (long i = from; i < to; i++) {
		double v = xp[i];

		if (v != last) {
			if (since >= settle) {
				// Restart from the held value
				ref = last;
				memset(r1, 0, n1 * sizeof(double));
				memset(r2, 0, n2 * sizeof(double));
				s1 = 0.0;
				s2 = 0.0;
			}
			since = 0.0;
			last = v;
		} else if (since < settle) {
			since += 1.0;
		}

		if (since >= settle) {
			op[i] = (float)v;
		} else {
			double d = v - ref;
			s1 += d - r1[p1];
			r1[p1] = d;
			p1++;
			if (p1 == n1) {
				p1 = 0;
			}

			double s = s1 / d1;
			s2 += s - r2[p2];
			r2[p2] = s;
			p2++;
			if (p2 == n2) {
				p2 = 0;
			}

			op[i] = (float)(ref + s2 / d2);
		}
	}

	st[0] = ref;
	st[1] = last;
	st[2] = s1;
	st[3] = s2;
	st[4] = (double)p1;
	st[5] = (double)p2;
	st[6] = since;


	return 0;
}

#endif
