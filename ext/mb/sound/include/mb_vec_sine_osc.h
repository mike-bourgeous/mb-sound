/*
 * The fast naive real sine oscillator (MB::Sound.precision :fast, the
 * default): the naive kernel's phase pass (serial, double precision, the
 * same phases and phase state as FastSound.oscillate; see mb_phase.h), each
 * phase plus phase modulation (cycles) reduced to -0.5..0.5 cycles as a
 * float, then mb_vec_sine.h's float polynomial, which the compiler
 * vectorizes.  Shared by fast_sound.c (FastSound.oscillate, the unfused
 * Tone) and fast_plan.c (fused Tone ops), so planned and unplanned sines are
 * the same samples by construction (fast-sine-1, maintainer decision
 * 2026-10-25).  The Ruby mirror is Plan::VecSine.shape_ruby on
 * Tone#phases_ruby's phases.
 */
#ifndef MB_VEC_SINE_OSC_H
#define MB_VEC_SINE_OSC_H

#include <math.h>
#include <stddef.h>
#include <ruby.h>

#include "mb_ext_helpers.h"
#include "mb_phase.h"
#include "mb_vec_sine.h"

// Fills out[0...length] with sin(2 pi (phase + pm)) * g + off (in float)
// at frequency +freq+ (or freqptr[i * freqstep] when freqptr isn't NULL)
// times +adv+, plus phase modulation +pm+ (or pmptr[i * pmstep]), reading
// and writing the [phi] or [phi, base, k, inc] +phase_state+ Array.
static inline void mb_vec_sine_oscillate(float *out, size_t length,
		double freq, const float *freqptr, size_t freqstep,
		double pm, const float *pmptr, size_t pmstep,
		double adv, double g, double off, VALUE phase_state)
{
	double phi = NUM2DBL(rb_ary_entry(phase_state, 0));
	float gf = (float)g, of = (float)off;
	float x[MB_VEC_CHUNK];

	_Bool constant = !freqptr;
	if (!constant) {
		phi = mb_wrap_phase(phi); // a running phase (see mb_phase.h)
	}

	// A constant frequency counts from its grid (see mb_phase.h)
	struct mb_grid_phase grid = { NAN, NAN, NAN };
	if (constant) {
		mb_grid_phase_read(phase_state, &grid);
		mb_grid_phase_start(&grid, phi, freq * adv);
	}
	for (size_t start = 0; start < length; start += MB_VEC_CHUNK) {
		size_t m = length - start < MB_VEC_CHUNK ? length - start : MB_VEC_CHUNK;
		for (size_t k = 0; k < m; k++) {
			size_t i = start + k;
			if (freqptr) {
				freq = freqptr[i * freqstep];
			}
			if (pmptr) {
				pm = pmptr[i * pmstep];
			}

			double ph;
			if (constant) {
				ph = mb_wrap(grid.base + grid.inc * grid.k, 1.0);
				mb_grid_phase_next(&grid);
			} else {
				ph = phi;
				phi = mb_wrap_phase(phi + freq * adv);
			}
			double r = ph + pm;
			x[k] = mb_vec_reduce(r);
		}
		mb_vec_sine_shape(out + start, x, m, gf, of);
	}

	if (constant) {
		rb_ary_store(phase_state, 0, rb_float_new(mb_grid_phase_now(&grid)));
		mb_grid_phase_write(phase_state, &grid);
	} else {
		rb_ary_store(phase_state, 0, rb_float_new(mb_wrap(phi, 1.0)));
	}
}

#endif
