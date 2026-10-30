/*
 * MB::Sound::Notes::Smoother's filter (FastControl.smooth; see
 * fast_control.c for the algorithm), shared with the plan layer executor
 * (fast_plan) so a planned controller smooths exactly as the node does.
 * The Ruby mirrors are Notes::Smoother.smooth_ruby, .adaptive_ruby, and
 * .curve_ruby.  fast_control is built with -ffp-contract=off and fast_plan
 * isn't, so the curve kernel (the only one with products) starts with
 * MB_SMOOTH_NO_CONTRACT (clang; GCC's -std=c99 doesn't contract).
 */
#ifndef MB_SMOOTH_H
#define MB_SMOOTH_H

#include <math.h>
#include <stddef.h>
#include <string.h>

#if defined(__clang__)
#define MB_SMOOTH_NO_CONTRACT _Pragma("clang fp contract(off)")
#else
#define MB_SMOOTH_NO_CONTRACT
#endif

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


// Adaptive smoothing (Notes::Smoother with a Range length; Ruby mirror
// Notes::Smoother.adaptive_ruby): each input step glides linearly from the
// current output to the new value over the samples since the previous
// step, clamped to [lo, hi].  State st (8 doubles): output, last input,
// ramp start, samples since the last step, ramp length, ramp position, lo,
// hi.
static inline void mb_adaptive_run(const float *xp, float *op, long from, long to, double *st)
{
	double y = st[0];
	double last = st[1];
	double start = st[2];
	double since = st[3];
	double t = st[4];
	double pos = st[5];
	double lo = st[6];
	double hi = st[7];

	for (long i = from; i < to; i++) {
		double v = xp[i];
		if (since < hi) {
			since += 1.0;
		}
		if (v != last) {
			t = since < lo ? lo : since;
			start = y;
			last = v;
			pos = 0.0;
			since = 0.0;
		}

		if (pos < t) {
			pos += 1.0;
			y = pos >= t ? v : start + (v - start) * (pos / t);
		} else {
			y = v;
		}
		op[i] = (float)y;
	}

	st[0] = y;
	st[1] = last;
	st[2] = start;
	st[3] = since;
	st[4] = t;
	st[5] = pos;
}

// Curve smoothing (Notes::Smoother with a curve; Ruby mirror
// Notes::Smoother.curve_ruby): a linear filter whose step response is the
// curve over n samples, computed as the sum of the steps still moving.
// Each input change starts a step (age 0) toward the new value, adding
// (target - previous target) * table[age] to the value of the finished
// steps; a step finishes after n samples (table[n - 1] is the curve's end,
// 1), when its target becomes the base.  New steps start at most every
// +gap+ samples (a change waits until then), so at most ceil(n / gap) steps
// move at once.  State st (9 doubles): base, last input, newest target,
// samples since the newest step (capped at gap), gap, n, count, head (the
// oldest step's slot), slot capacity.  Slots: [age, target] pairs.  Table:
// n values, table[k] the curve at (k + 1) / n.  Returns 0, or -1 (nothing
// done) if the state doesn't fit the slots or table.
static inline int mb_curve_smooth_run(const float *xp, float *op, long from, long to, double *st, double *slots, size_t nslots, const double *table, size_t ntable)
{
	MB_SMOOTH_NO_CONTRACT
	double base = st[0];
	double last = st[1];
	double newest = st[2];
	double since = st[3];
	double gap = st[4];
	size_t n = (size_t)st[5];
	size_t count = (size_t)st[6];
	size_t head = (size_t)st[7];
	size_t cap = (size_t)st[8];
	if (n < 1 || n > ntable || cap < 1 || cap * 2 > nslots || count > cap || head >= cap) {
		return -1;
	}

	for (long i = from; i < to; i++) {
		double v = xp[i];
		last = v;

		// Finished steps become the base
		while (count > 0 && slots[2 * head] >= (double)n) {
			base = slots[2 * head + 1];
			head = head + 1 == cap ? 0 : head + 1;
			count--;
		}

		if (v != newest && since >= gap) {
			if (count == cap) {
				// Full (only if gap is too short): finish the oldest now
				base = slots[2 * head + 1];
				head = head + 1 == cap ? 0 : head + 1;
				count--;
			}
			size_t j = head + count;
			if (j >= cap) j -= cap;
			slots[2 * j] = 0.0;
			slots[2 * j + 1] = v;
			count++;
			newest = v;
			since = 0.0;
		}

		double y = base;
		double prev = base;
		size_t j = head;
		for (size_t k = 0; k < count; k++) {
			double age = slots[2 * j];
			double target = slots[2 * j + 1];
			y += (target - prev) * table[(size_t)age];
			prev = target;
			slots[2 * j] = age + 1.0;
			j = j + 1 == cap ? 0 : j + 1;
		}

		if (since < gap) {
			since += 1.0;
		}
		op[i] = (float)y;
	}

	st[0] = base;
	st[1] = last;
	st[2] = newest;
	st[3] = since;
	st[6] = (double)count;
	st[7] = (double)head;

	return 0;
}

// Slew limiting (Filter::LinearFollower#process; Ruby mirror
// LinearFollower#process_ruby): the output follows each input value (its
// absolute value if +absolute+) but moves at most +rise+ up and +fall+ down
// per sample (pass INFINITY for no limit), from the state *s (the last
// output).  +x+ and +out+ are float or double arrays (+is_double+) and may
// be the same.
static inline void mb_slew_run(const void *x, void *out, size_t n, int is_double, double *s, double rise, double fall, int absolute)
{
	double y = *s;
	for (size_t i = 0; i < n; i++) {
		double v = is_double ? ((const double *)x)[i] : (double)((const float *)x)[i];
		if (absolute) v = fabs(v);
		double hi = y + rise;
		double lo = y - fall;
		if (v > hi) {
			y = hi;
		} else if (v < lo) {
			y = lo;
		} else {
			y = v;
		}
		if (is_double) {
			((double *)out)[i] = y;
		} else {
			((float *)out)[i] = (float)y;
		}
	}
	*s = y;
}

// One segment of Notes::Smoother's kernels by state length +sl+ (7 the
// B-spline FIR, 8 adaptive, 9 curve; see Notes::Smoother.segment).  The
// rings are the fixed kernel's moving averages, or the curve kernel's
// slots and table (unused by the adaptive kernel).  Returns 0, or -1 for a
// bad state.
static inline int mb_smoother_segment(size_t sl, const float *xp, float *op, long from, long to, double *st, double *r1, size_t n1, double *r2, size_t n2)
{
	switch (sl) {
		case 7: return mb_smooth_run(xp, op, from, to, st, r1, n1, r2, n2);
		case 8: mb_adaptive_run(xp, op, from, to, st); return 0;
		case 9: return mb_curve_smooth_run(xp, op, from, to, st, r1, n1, r2, n2);
		default: return -1;
	}
}

// Notes::Smoother.jump: the output jumps to +v+ (the input at a jump) and
// holds it with nothing moving.
static inline void mb_smoother_jump(size_t sl, double *st, double v, size_t n1, size_t n2)
{
	if (sl == 8) {
		st[0] = st[1] = st[2] = v;
		st[3] = 0.0;
		st[5] = st[4];
	} else if (sl == 9) {
		st[0] = st[1] = st[2] = v;
		st[3] = st[4];
		st[6] = 0.0;
		st[7] = 0.0;
	} else {
		st[1] = v;
		st[6] = (double)(n1 + n2 - 2);
	}
}

// Smooths xp[0...n] into op with a jump at every nonzero sample of +rp+
// (GraphNode#smooth's reset:; rp NULL for none).  Returns 0 or -1.
static inline int mb_smoother_reset_run(size_t sl, const float *xp, float *op, const float *rp, long n, double *st, double *r1, size_t n1, double *r2, size_t n2)
{
	long start = 0;
	if (rp) {
		for (long j = 0; j < n; j++) {
			if (rp[j] == 0) continue;
			if (j > start && mb_smoother_segment(sl, xp, op, start, j, st, r1, n1, r2, n2) != 0) return -1;
			mb_smoother_jump(sl, st, xp[j], n1, n2);
			start = j;
		}
	}
	if (start < n && mb_smoother_segment(sl, xp, op, start, n, st, r1, n1, r2, n2) != 0) return -1;
	return 0;
}

#endif
