/*
 * Wavetable tones as plan ops (fast_plan.c's run_tone with the wavetable
 * kernel; see Plan::Op::Tone): FastWavetable.oscillate's loop through
 * mb_wavetable.h, so a planned wavetable tone runs the same operations as
 * its node.  fast_wavetable is built with -ffp-contract=off; this file
 * turns clang's contraction off by pragma (GCC's -std=c99 doesn't
 * contract), like plan_filters.c.
 */
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#endif

#include <math.h>
#include <stdint.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_wavetable.h"

#include "plan_filters.h"

void mb_plan_wavetable_segment(VALUE tinfo, float *out, size_t length, const struct mb_signal *f, const struct mb_signal *p,
		const struct mb_signal *w, _Bool warped, const struct mb_signal *scan, double adv, double rndadv, double g, double off,
		_Bool remove_dc, VALUE phase_state, VALUE tstate, VALUE noise)
{
	Check_Type(tinfo, T_ARRAY);
	if (RARRAY_LEN(tinfo) < 3) {
		rb_raise(rb_eArgError, "A planned wavetable needs [spec, interpolation, sinc kernel]");
	}

	struct wt_table t;
	wt_read_table(rb_ary_entry(tinfo, 0), &t);
	if (t.mode != 0 || t.cs != 1) {
		rb_raise(rb_eArgError, "Planned wavetable tones need real cycle-mode tables");
	}
	struct wt_sinc ks = { 0 };
	int mode = wt_read_interp(rb_ary_entry(tinfo, 1), rb_ary_entry(tinfo, 2), &t, &ks);

	struct mb_wt_osc_state st;
	st.phi = wt_read_state(phase_state, 1, "Phase state");
	mb_grid_phase_read(phase_state, &st.grid);
	wt_read_state(tstate, 5, "Wavetable state");
	st.primed = NUM2INT(rb_ary_entry(tstate, 2)) != 0;
	st.prev_pm = NUM2DBL(rb_ary_entry(tstate, 1));
	st.prev_e = NUM2DBL(rb_ary_entry(tstate, 3));
	st.prev_inc = NUM2DBL(rb_ary_entry(tstate, 4));
	st.rng = 0;
	if (rndadv != 0) {
		Check_Type(noise, T_ARRAY);
		if (RARRAY_LEN(noise) != 1) {
			rb_raise(rb_eArgError, "Noise state must have exactly one Integer element");
		}
		st.rng = NUM2ULL(rb_ary_entry(noise, 0));
	}

	mb_wt_oscillate(&t, mode, &ks, out, length, f, p, w, warped, scan, adv, rndadv, g, off, remove_dc, &st);

	if (rndadv != 0) {
		rb_ary_store(noise, 0, ULL2NUM(st.rng));
	}
	rb_ary_store(phase_state, 0, rb_float_new(st.phi));
	if (!isnan(st.grid.inc)) {
		mb_grid_phase_write(phase_state, &st.grid);
	}
	if (length > 0) {
		rb_ary_store(tstate, 1, rb_float_new(st.prev_pm));
		rb_ary_store(tstate, 2, INT2NUM(1));
		rb_ary_store(tstate, 3, rb_float_new(st.prev_e));
		rb_ary_store(tstate, 4, rb_float_new(st.prev_inc));
	}

	RB_GC_GUARD(tinfo);
}
