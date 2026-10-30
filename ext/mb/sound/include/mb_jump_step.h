/*
 * Band-limited phase jump steps of Tone (Tone::State's queued jump
 * residual), kept in a preallocated DFloat buffer with a count of pending
 * samples, so key-synced resets allocate nothing (omnibus18, 2026-10-30;
 * before, every reset made a residual DFloat and padded, summed, and
 * sliced copies with Numo).  Used by fast_synth (FastSynth.jump_queue and
 * jump_add, for Tone's own kernels) and fast_plan (planned tones).
 *
 * The arithmetic is exactly Numo's in the Ruby reference
 * (Tone::State#queue_jump_ruby and #add_jump_ruby; compared bit for bit
 * in spec/lib/mb/sound/tone/state_spec.rb): every multiply and add is its
 * own statement (no fused multiply-adds under clang's default
 * -ffp-contract=on, which only fuses within an expression), and Numo's sum
 * is a plain loop of y = x + y from the first element.
 */
#ifndef MB_JUMP_STEP_H
#define MB_JUMP_STEP_H

#include <stddef.h>
#include <string.h>

// The longest step table (BandLimit::SYNC_TAPS is 32).
#define MB_JUMP_MAX_TAPS 256

/*
 * Queues a step that changes the value by +dv+ and the slope per sample by
 * +ds+ into +buf+ (+left+ samples pending; capacity at least +n+), from the
 * +n+-tap minBLEP/minBLAMP tables +blep+ and +blamp+ and the +na+-tap area
 * correction +area+, with +c+ the ideal step's area (Tone.jump_residual),
 * scaled by +k+ if +scale+.  As in Ruby, the result is the new step plus
 * the pending samples padded with zeros (or cut) to +n+ samples.  Returns
 * the new pending count (+n+).
 */
static inline size_t mb_jump_queue(double *buf, size_t left, const double *blep, const double *blamp, size_t n,
		const double *area, size_t na, double dv, double ds, _Bool scale, double k, double c)
{
	double step[MB_JUMP_MAX_TAPS];

	double sum = 0.0;
	for (size_t i = 0; i < n; i++) {
		double a = blep[i] * dv;
		double b = blamp[i] * ds;
		step[i] = a + b;
		sum = step[i] + sum;
	}

	double corr = c - sum;
	for (size_t i = 0; i < na; i++) {
		double t = area[i] * corr;
		step[i] = step[i] + t;
	}

	if (scale) {
		for (size_t i = 0; i < n; i++) {
			step[i] = step[i] * k;
		}
	}

	if (left > 0) {
		for (size_t i = 0; i < n; i++) {
			buf[i] = step[i] + (i < left ? buf[i] : 0.0);
		}
	} else {
		memcpy(buf, step, n * sizeof(double));
	}

	return n;
}

// Adds the first pending samples of +buf+ (+left+ of them) times +g+ to the
// float samples +seg+ (+length+ of them), rounding once from double, as
// Numo's `seg[0...m] += buf[0...m] * g` does.  Returns the count added.
static inline size_t mb_jump_add_float(float *seg, size_t length, const double *buf, size_t left, double g)
{
	size_t m = length < left ? length : left;
	for (size_t i = 0; i < m; i++) {
		double s = buf[i] * g;
		double v = (double)seg[i] + s;
		seg[i] = (float)v;
	}
	return m;
}

// The same for double samples.
static inline size_t mb_jump_add_double(double *seg, size_t length, const double *buf, size_t left, double g)
{
	size_t m = length < left ? length : left;
	for (size_t i = 0; i < m; i++) {
		double s = buf[i] * g;
		seg[i] = seg[i] + s;
	}
	return m;
}

// Drops the first +m+ of +left+ pending samples of +buf+ (moving the rest
// to the front, zeroing what they leave).  Returns the new pending count.
static inline size_t mb_jump_shift(double *buf, size_t left, size_t m)
{
	if (m >= left) {
		if (left > 0) {
			memset(buf, 0, left * sizeof(double));
		}
		return 0;
	}

	memmove(buf, buf + m, (left - m) * sizeof(double));
	memset(buf + (left - m), 0, m * sizeof(double));
	return left - m;
}

#endif
