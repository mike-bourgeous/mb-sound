/*
 * Delay line interpolation shared by fast_delay.c (DelayLine's kernels,
 * FastDelay.read and .feedback) and fast_loop.c (delays inside feedback
 * loops), so both read delay lines with the same math.  Ruby mirror:
 * DelayLine#interpolate.  Moved here from fast_delay.c (2026-10-09,
 * feedback loops).
 */
#ifndef MB_DELAY_INTERP_H
#define MB_DELAY_INTERP_H

#include <math.h>
#include <complex.h>

static inline long wrap_index(long i, long capacity)
{
	long r = i % capacity;
	return r < 0 ? r + capacity : r;
}

// Interpolation modes for fractional delays (DelayLine::INTERPOLATION).
enum delay_interpolation {
	DELAY_LINEAR = 0, // between the samples at floor(delay) and floor(delay) + 1
	DELAY_CUBIC = 1, // 4-point Catmull-Rom (Hermite) spline
	DELAY_SINC = 2, // windowed sinc, low-passed by 1/rate when reading faster than 1x
};

// The windowed-sinc kernel from DelayLine::SINC_KERNEL: table[j] is the
// kernel at j / resolution samples from its center (0 past +half+), and
// the kernel widens by up to +max_rate+ times when reading faster than 1x.
struct sinc_kernel {
	const double *table;
	long table_length;
	double half;
	double resolution;
	double max_rate;
};

// The number of samples older than floor(delay) that a mode reads (delays
// are clamped so these stay inside the buffer).
static inline double delay_margin(int mode, const struct sinc_kernel *k)
{
	switch (mode) {
		case DELAY_CUBIC:
			return 2;
		case DELAY_SINC:
			return ceil(k->half * k->max_rate) + 1;
		default:
			return 1;
	}
}

// The sinc kernel weight at +x+ samples from its center (scaled by the
// cutoff), interpolated linearly in the table.
static inline double sinc_weight(const struct sinc_kernel *k, double x)
{
	double u = x * k->resolution;
	long j = (long)u;
	if (j + 1 >= k->table_length) {
		return 0;
	}
	double f = u - j;
	return k->table[j] + (k->table[j + 1] - k->table[j]) * f;
}

// Interpolates the delay line +buf+ at +d+ samples before position +base+
// (+rate+ is the read speed for sinc).  Samples newer than +base+ are never
// read: taps at negative delays read the sample at +base+ instead.
#define DELAY_INTERP(NAME, STORE, CALC) \
static CALC NAME(const STORE *buf, long cap, long base, double d, int mode, const struct sinc_kernel *k, double rate) \
{ \
	double dmin = floor(d); \
	double t = d - dmin; \
	long di = (long)dmin; \
	\
	switch (mode) { \
		case DELAY_CUBIC: { \
			CALC ym1 = buf[wrap_index(base - (di > 0 ? di - 1 : 0), cap)]; \
			CALC y0 = buf[wrap_index(base - di, cap)]; \
			CALC y1 = buf[wrap_index(base - di - 1, cap)]; \
			CALC y2 = buf[wrap_index(base - di - 2, cap)]; \
			CALC c0 = y0; \
			CALC c1 = 0.5 * (y1 - ym1); \
			CALC c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2; \
			CALC c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1); \
			return ((c3 * t + c2) * t + c1) * t + c0; \
		} \
		\
		case DELAY_SINC: { \
			if (t == 0 && rate <= 1) { \
				/* The kernel is zero at other whole samples */ \
				return buf[wrap_index(base - di, cap)]; \
			} \
			double fc = rate > 1 ? 1.0 / (rate < k->max_rate ? rate : k->max_rate) : 1.0; \
			double support = k->half / fc; \
			long kmin = (long)ceil(d - support); \
			long kmax = (long)floor(d + support); \
			CALC sum = 0; \
			double wsum = 0; \
			for (long kk = kmin; kk <= kmax; kk++) { \
				double w = sinc_weight(k, fabs((double)kk - d) * fc); \
				sum += w * (CALC)buf[wrap_index(base - (kk > 0 ? kk : 0), cap)]; \
				wsum += w; \
			} \
			return wsum != 0 ? sum / wsum : 0; \
		} \
		\
		default: { \
			CALC a = buf[wrap_index(base - di, cap)]; \
			CALC b = buf[wrap_index(base - di - 1, cap)]; \
			return a * (1.0 - t) + b * t; \
		} \
	} \
}

#endif
