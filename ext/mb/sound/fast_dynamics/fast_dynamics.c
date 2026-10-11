/*
 * Dynamics kernels for MB::Sound::GraphNode::Dynamics (compressors,
 * expanders, gates, ducking, companders), Dynamics::Limiter (lookahead
 * brickwall), and Dynamics::Crossover (Linkwitz-Riley band splitting).
 * See design/notes/dynamics.md.
 *
 * Every kernel has an exact Ruby mirror (Dynamics.process_ruby,
 * Dynamics::Limiter.process_ruby, Dynamics::Crossover.process_ruby) doing
 * the same double operations in the same order (built with
 * -ffp-contract=off), so specs compare them for equality.  Signal inputs
 * are read as float32 values (see mb_read_signal_input).
 */
#include <math.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

// Detector levels below these read as DYN_FLOOR_DB.
#define DYN_FLOOR_DB -200.0
#define DYN_FLOOR_LIN 1e-10
#define DYN_FLOOR_SQ 1e-20

// Smoothed gains this close to their target land on it.
#define DYN_SNAP 1e-12

// Filter states smaller than this are flushed to zero.
#define DYN_FLUSH 1e-30

// Per-detector state entries for compand (mean square, smoothed gain dB,
// hold counter).
#define DYN_DET_STATE 3

// Compand settings (see ruby_compand).
enum dyn_param {
	DP_MODE, // 0 peak, 1 RMS
	DP_MIN_GAIN, // dB
	DP_MAX_GAIN, // dB
	DP_MAKEUP, // dB
	DP_HOLD_UP, // 1: hold delays rising gain (compressors), 0: falling (gates)
	DP_LINK, // 1: one detector for every channel
	DP_LOOKAHEAD, // whole samples of audio delay
	DP_MIX, // parallel mix: gain = mix * gain + (1 - mix)
	DP_COUNT
};

// Compand time inputs, in samples (see ruby_compand).
enum dyn_time {
	DT_RMS,
	DT_DOWN,
	DT_UP,
	DT_BOOST, // fall time while the gain is above 0 dB (an upward boost)
	DT_HOLD,
	DT_COUNT
};

static double *dyn_dfloat_ptr(VALUE v, long min_length, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D Numo::DFloat", name);
	}
	if ((long)RNARRAY_SHAPE(v)[0] < min_length) {
		rb_raise(rb_eArgError, "%s must have at least %ld elements", name, min_length);
	}
	if (OBJ_FROZEN(v)) {
		rb_raise(rb_eFrozenError, "%s is frozen", name);
	}
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

static const double *dyn_dfloat_read(VALUE v, long min_length, const char *name)
{
	if (CLASS_OF(v) != numo_cDFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "%s must be a contiguous 1D Numo::DFloat", name);
	}
	if ((long)RNARRAY_SHAPE(v)[0] < min_length) {
		rb_raise(rb_eArgError, "%s must have at least %ld elements", name, min_length);
	}
	return (const double *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

// Checks that +outs+ is a non-empty Array of contiguous, unfrozen SFloats
// of one length, and returns that length.
static long dyn_check_outputs(VALUE outs)
{
	Check_Type(outs, T_ARRAY);
	long nch = RARRAY_LEN(outs);
	if (nch < 1) {
		rb_raise(rb_eArgError, "At least one output is required");
	}
	long n = -1;
	for (long c = 0; c < nch; c++) {
		VALUE o = rb_ary_entry(outs, c);
		if (CLASS_OF(o) != numo_cSFloat || RNARRAY_NDIM(o) != 1 || !RTEST(nary_check_contiguous(o))) {
			rb_raise(rb_eArgError, "Output %ld must be a contiguous 1D Numo::SFloat", c);
		}
		if (OBJ_FROZEN(o)) {
			rb_raise(rb_eFrozenError, "Output %ld is frozen", c);
		}
		long len = (long)RNARRAY_SHAPE(o)[0];
		if (n < 0) {
			n = len;
		} else if (len != n) {
			rb_raise(rb_eArgError, "Outputs must have the same length");
		}
	}
	return n;
}

// The exp(-1 / t) one-pole coefficient for a time constant of +t+ samples
// (0 for instant).
static double dyn_coef(double t)
{
	return t > 0 ? exp(-1.0 / t) : 0.0;
}

// Evaluates the transfer curve (+nseg+ rows of [x0, y0, b, c, d]) at +x+:
// the last segment whose x0 <= x (the first for x below every x0).
static double dyn_curve(const double *seg, long nseg, double x)
{
	long lo = 0;
	long hi = nseg - 1;
	while (lo < hi) {
		long mid = (lo + hi + 1) / 2;
		if (seg[mid * 5] <= x) {
			lo = mid;
		} else {
			hi = mid - 1;
		}
	}
	const double *s = seg + lo * 5;
	double dx = x - s[0];
	return s[1] + dx * (s[2] + dx * (s[3] + dx * s[4]));
}

/*
 * call-seq:
 *   MB::Sound::FastDynamics.compand(outs, ins, sides, curve, params, times, state, delay) -> outs
 *
 * +outs+ is an Array of contiguous Numo::SFloats (one per channel, all the
 * sample count long).  +ins+ is an Array of the same number of signals
 * (Numeric, nil for silence, or NArrays of the sample count).  +sides+ is
 * an Array of detector signals: with linking (params[DP_LINK]) any number,
 * all feeding one detector; otherwise one per channel.  +curve+ is a
 * DFloat of segments [x0, y0, b, c, d] (sorted by x0; the transfer curve,
 * input level dB to output level dB).  +params+ is a DFloat of DP_COUNT
 * settings, +times+ an Array of DT_COUNT signals in samples.  +state+ is a
 * DFloat of DYN_DET_STATE entries per detector plus the delay position;
 * +delay+ a DFloat of channels * lookahead samples (or nil without
 * lookahead).
 */
static VALUE ruby_compand(VALUE self, VALUE outs, VALUE ins, VALUE sides, VALUE curve, VALUE params, VALUE times, VALUE state, VALUE delay)
{
	long n = dyn_check_outputs(outs);
	long nch = RARRAY_LEN(outs);

	Check_Type(ins, T_ARRAY);
	Check_Type(sides, T_ARRAY);
	Check_Type(times, T_ARRAY);
	if (RARRAY_LEN(ins) != nch) {
		rb_raise(rb_eArgError, "Expected %ld inputs (got %ld)", nch, RARRAY_LEN(ins));
	}
	if (RARRAY_LEN(times) != DT_COUNT) {
		rb_raise(rb_eArgError, "Expected %d times", DT_COUNT);
	}

	const double *par = dyn_dfloat_read(params, DP_COUNT, "Params");
	int rms = par[DP_MODE] != 0;
	double min_gain = par[DP_MIN_GAIN];
	double max_gain = par[DP_MAX_GAIN];
	double makeup = par[DP_MAKEUP];
	int hold_up = par[DP_HOLD_UP] != 0;
	int link = par[DP_LINK] != 0;
	long la = (long)par[DP_LOOKAHEAD];
	double mix = par[DP_MIX];
	if (la < 0) {
		rb_raise(rb_eArgError, "Lookahead must not be negative");
	}

	long nside = RARRAY_LEN(sides);
	if (link ? nside < 1 : nside != nch) {
		rb_raise(rb_eArgError, "Expected %s sidechain signals (got %ld)", link ? "at least one" : "one per channel", nside);
	}
	long ndet = link ? 1 : nch;

	const double *seg = dyn_dfloat_read(curve, 5, "Curve");
	long nseg = (long)RNARRAY_SIZE(curve) / 5;

	double *st = dyn_dfloat_ptr(state, ndet * DYN_DET_STATE + 1, "State");
	double *dl = NULL;
	if (la > 0) {
		dl = dyn_dfloat_ptr(delay, nch * la, "Delay");
	}

	VALUE *in_v = ALLOCA_N(VALUE, nch);
	VALUE *side_v = ALLOCA_N(VALUE, nside);
	VALUE time_v[DT_COUNT];
	struct mb_signal *in = ALLOCA_N(struct mb_signal, nch);
	struct mb_signal *side = ALLOCA_N(struct mb_signal, nside);
	struct mb_signal tim[DT_COUNT];
	float **out = ALLOCA_N(float *, nch);
	double *gain = ALLOCA_N(double, ndet);

	for (long c = 0; c < nch; c++) {
		in_v[c] = rb_ary_entry(ins, c);
		mb_signal_input(&in_v[c], n, "Input", &in[c]);
		out[c] = mb_sfloat_ptr(rb_ary_entry(outs, c));
	}
	for (long c = 0; c < nside; c++) {
		side_v[c] = rb_ary_entry(sides, c);
		mb_signal_input(&side_v[c], n, "Sidechain", &side[c]);
	}
	for (long t = 0; t < DT_COUNT; t++) {
		time_v[t] = rb_ary_entry(times, t);
		mb_signal_input(&time_v[t], n, "Time", &tim[t]);
	}

	long pos = (long)st[ndet * DYN_DET_STATE];
	if (la > 0 && (pos < 0 || pos >= la)) {
		pos = 0;
	}

	// Coefficients and gains are recomputed only when their inputs change
	// (NAN never compares equal, so the first sample computes them).
	double last_t[DT_COUNT] = { NAN, NAN, NAN, NAN, NAN };
	double coef[DT_COUNT] = { 0, 0, 0, 0, 0 };
	double last_gdb = NAN;
	double last_glin = 1.0;

	for (long i = 0; i < n; i++) {
		for (long t = 0; t < DT_HOLD; t++) {
			double v = mb_signal_at(&tim[t], i);
			if (v != last_t[t]) {
				last_t[t] = v;
				coef[t] = dyn_coef(v);
			}
		}
		double hold = mb_signal_at(&tim[DT_HOLD], i);

		for (long d = 0; d < ndet; d++) {
			double *ds = st + d * DYN_DET_STATE;

			double m = 0.0;
			long first = link ? 0 : d;
			long last = link ? nside : d + 1;
			for (long c = first; c < last; c++) {
				double v = mb_signal_at(&side[c], i);
				v = rms ? v * v : fabs(v);
				if (v > m) {
					m = v;
				}
			}

			double level;
			if (rms) {
				ds[0] = ds[0] * coef[DT_RMS] + (1.0 - coef[DT_RMS]) * m;
				level = ds[0] > DYN_FLOOR_SQ ? 10.0 * log10(ds[0]) : DYN_FLOOR_DB;
			} else {
				level = m > DYN_FLOOR_LIN ? 20.0 * log10(m) : DYN_FLOOR_DB;
			}

			double g = dyn_curve(seg, nseg, level) - level;
			if (g < min_gain) {
				g = min_gain;
			}
			if (g > max_gain) {
				g = max_gain;
			}

			// The held direction (rising for compressors, falling for
			// gates) waits for the hold counter, which restarts while
			// the gain is steady or moving the other way.
			double gs = ds[1];
			int held = hold_up ? g > gs : g < gs;
			if (held && ds[2] > 0) {
				ds[2] -= 1.0;
			} else {
				if (g < gs && gs > 0) {
					// A boost (gain above 0 dB) falls at its own speed
					gs = g + (gs - g) * coef[DT_BOOST];
				} else if (g != gs) {
					gs = g + (gs - g) * (g < gs ? coef[DT_DOWN] : coef[DT_UP]);
				}
				if (!held) {
					ds[2] = hold;
				}
			}
			if (fabs(gs - g) < DYN_SNAP) {
				gs = g;
			}
			ds[1] = gs;

			double gdb = gs + makeup;
			if (gdb != last_gdb) {
				last_gdb = gdb;
				last_glin = mix * pow(10.0, gdb / 20.0) + (1.0 - mix);
			}
			gain[d] = last_glin;
		}

		for (long c = 0; c < nch; c++) {
			double x = mb_signal_at(&in[c], i);
			if (la > 0) {
				double *slot = dl + c * la + pos;
				double y = *slot;
				*slot = x;
				x = y;
			}
			out[c][i] = (float)(x * gain[link ? 0 : c]);
		}
		if (la > 0) {
			pos = pos + 1 == la ? 0 : pos + 1;
		}
	}

	st[ndet * DYN_DET_STATE] = (double)pos;

	for (long c = 0; c < nch; c++) {
		RB_GC_GUARD(in_v[c]);
	}
	for (long c = 0; c < nside; c++) {
		RB_GC_GUARD(side_v[c]);
	}
	for (long t = 0; t < DT_COUNT; t++) {
		RB_GC_GUARD(time_v[t]);
	}
	RB_GC_GUARD(outs);
	RB_GC_GUARD(ins);
	RB_GC_GUARD(sides);
	RB_GC_GUARD(times);
	RB_GC_GUARD(curve);
	RB_GC_GUARD(params);
	RB_GC_GUARD(state);
	RB_GC_GUARD(delay);

	return outs;
}

// Limiter settings (see ruby_limit).
enum lim_param {
	LP_CEILING, // linear
	LP_RELEASE, // one-pole coefficient
	LP_LOOKAHEAD, // whole samples
	LP_TRUE_PEAK, // 1: Annex 2 inter-sample peaks too
	LP_LINK,
	LP_COUNT
};

// The true-peak interpolator's taps per phase and phases, and the delay
// of its detector (the sample between the newest windows' intervals).
#define LIM_TAPS 12
#define LIM_PHASES 4
#define LIM_TP_DELAY 6

/*
 * call-seq:
 *   MB::Sound::FastDynamics.limit(outs, ins, params, state, rings, phases) -> outs
 *
 * Lookahead brickwall limiter.  +outs+/+ins+ as for compand.  +params+ is
 * a DFloat of LP_COUNT settings.  With W = lookahead + 1 and D detectors
 * (1 linked, else one per channel), +state+ is a DFloat of D smoothed
 * gains, then one previous true-peak value per channel, then the sample
 * counter; +rings+ a DFloat of D * W required gains, D * W smoothed gains,
 * channels * lookahead delayed samples, and channels * 12 input history
 * samples (true peak).  +phases+ is the [4, 12] DFloat interpolator (BS.1770
 * Annex 2; Loudness::TruePeak::MATRICES[:annex2]).
 *
 * Per sample n: the detector level e is |x| (with true peak, the sample
 * 6 back and the interpolated peaks on both sides of it); the required
 * gain min(1, ceiling / e); its minimum over the last W samples; that
 * through an instant-attack release one-pole (s); the mean of the last W
 * values of s; and the output the audio W - 1 samples back (plus 6 with
 * true peak) times that mean, clamped to the ceiling.  Every averaged s is
 * at most the required gain of the sample going out, so the output stays
 * at or under the ceiling.
 */
static VALUE ruby_limit(VALUE self, VALUE outs, VALUE ins, VALUE params, VALUE state, VALUE rings, VALUE phases)
{
	long n = dyn_check_outputs(outs);
	long nch = RARRAY_LEN(outs);
	Check_Type(ins, T_ARRAY);
	if (RARRAY_LEN(ins) != nch) {
		rb_raise(rb_eArgError, "Expected %ld inputs (got %ld)", nch, RARRAY_LEN(ins));
	}

	const double *par = dyn_dfloat_read(params, LP_COUNT, "Params");
	double ceiling = par[LP_CEILING];
	double rc = par[LP_RELEASE];
	long la = (long)par[LP_LOOKAHEAD];
	int tp = par[LP_TRUE_PEAK] != 0;
	int link = par[LP_LINK] != 0;
	if (la < 0) {
		rb_raise(rb_eArgError, "Lookahead must not be negative");
	}
	if (!(ceiling > 0)) {
		rb_raise(rb_eArgError, "Ceiling must be positive");
	}
	long w = la + 1;
	long ndet = link ? 1 : nch;

	double *st = dyn_dfloat_ptr(state, ndet + nch + 1, "State");
	double *ring = dyn_dfloat_ptr(rings, 2 * ndet * w + nch * la + nch * LIM_TAPS, "Rings");
	const double *h = dyn_dfloat_read(phases, LIM_PHASES * LIM_TAPS, "Phases");
	if (RNARRAY_SIZE(phases) != LIM_PHASES * LIM_TAPS) {
		rb_raise(rb_eArgError, "Phases must be 4 x 12");
	}

	double *greq = ring;
	double *sm = greq + ndet * w;
	double *dl = sm + ndet * w;
	double *hist = dl + nch * la;
	double *prev_tp = st + ndet;
	double counter = st[ndet + nch];

	VALUE *in_v = ALLOCA_N(VALUE, nch);
	struct mb_signal *in = ALLOCA_N(struct mb_signal, nch);
	float **out = ALLOCA_N(float *, nch);
	double *lv = ALLOCA_N(double, nch);
	double *a = ALLOCA_N(double, nch);
	double *gain = ALLOCA_N(double, ndet);
	for (long c = 0; c < nch; c++) {
		in_v[c] = rb_ary_entry(ins, c);
		mb_signal_input(&in_v[c], n, "Input", &in[c]);
		out[c] = mb_sfloat_ptr(rb_ary_entry(outs, c));
	}

	for (long i = 0; i < n; i++) {
		long wpos = (long)fmod(counter, (double)w);
		long dpos = la > 0 ? (long)fmod(counter, (double)la) : 0;

		for (long c = 0; c < nch; c++) {
			double x = mb_signal_at(&in[c], i);
			if (tp) {
				double *hc = hist + c * LIM_TAPS;
				memmove(hc, hc + 1, sizeof(double) * (LIM_TAPS - 1));
				hc[LIM_TAPS - 1] = x;
				// hc[LIM_TAPS - 1 - k] is the sample k back
				double peak = 0.0;
				for (long p = 0; p < LIM_PHASES; p++) {
					const double *hp = h + p * LIM_TAPS;
					double y = 0.0;
					for (long k = 0; k < LIM_TAPS; k++) {
						y += hc[LIM_TAPS - 1 - k] * hp[k];
					}
					y = fabs(y);
					if (y > peak) {
						peak = y;
					}
				}
				a[c] = hc[LIM_TAPS - 1 - LIM_TP_DELAY];
				double e = fabs(a[c]);
				if (peak > e) {
					e = peak;
				}
				if (prev_tp[c] > e) {
					e = prev_tp[c];
				}
				prev_tp[c] = peak;
				lv[c] = e;
			} else {
				a[c] = x;
				lv[c] = fabs(x);
			}
		}

		for (long d = 0; d < ndet; d++) {
			double e = lv[d];
			if (link) {
				for (long c = 1; c < nch; c++) {
					if (lv[c] > e) {
						e = lv[c];
					}
				}
			}
			double g = e > ceiling ? ceiling / e : 1.0;

			double *gr = greq + d * w;
			gr[wpos] = g;
			double hmin = gr[0];
			for (long k = 1; k < w; k++) {
				if (gr[k] < hmin) {
					hmin = gr[k];
				}
			}

			double s = st[d];
			s = hmin < s ? hmin : hmin + (s - hmin) * rc;
			if (fabs(s - hmin) < DYN_SNAP) {
				s = hmin;
			}
			st[d] = s;

			double *sr = sm + d * w;
			sr[wpos] = s;
			double sum = 0.0;
			for (long k = 0; k < w; k++) {
				sum += sr[k];
			}
			gain[d] = sum / (double)w;
		}

		for (long c = 0; c < nch; c++) {
			double x = a[c];
			if (la > 0) {
				double *slot = dl + c * la + dpos;
				double y = *slot;
				*slot = x;
				x = y;
			}
			double y = x * gain[link ? 0 : c];
			if (y > ceiling) {
				y = ceiling;
			} else if (y < -ceiling) {
				y = -ceiling;
			}
			out[c][i] = (float)y;
		}

		counter += 1.0;
	}

	st[ndet + nch] = counter;

	for (long c = 0; c < nch; c++) {
		RB_GC_GUARD(in_v[c]);
	}
	RB_GC_GUARD(outs);
	RB_GC_GUARD(ins);
	RB_GC_GUARD(params);
	RB_GC_GUARD(state);
	RB_GC_GUARD(rings);
	RB_GC_GUARD(phases);

	return outs;
}

// Crossover program rows (see ruby_crossover).
#define XO_ROW 9
enum xo_kind {
	XO_SPLIT, // dst1 = lowpass, dst2 = highpass * sign
	XO_LOW, // dst1 = lowpass
	XO_HIGH, // dst1 = highpass * sign
	XO_ALLPASS, // dst1 = x - 2k bandpass (second-order allpass)
	XO_LOW_MINUS_HIGH, // dst1 = lowpass - highpass (first-order allpass at Q 0.5)
};

/*
 * call-seq:
 *   MB::Sound::FastDynamics.crossover(outs, input, program, bands, state, registers) -> outs
 *
 * Runs a band-splitting program of TPT state-variable filters (Simper's
 * linear trapezoidal SVF) one sample at a time.  +program+ is a DFloat of
 * rows [src, dst1, dst2, kind, a1, a2, a3, k, sign] (register numbers,
 * enum xo_kind, and the SVF's coefficients); register 0 holds the input.
 * +bands+ is an Array of register numbers, one per output in +outs+.
 * +state+ is a DFloat of two integrator states per row.  +registers+ is the
 * register count.
 */
static VALUE ruby_crossover(VALUE self, VALUE outs, VALUE input, VALUE program, VALUE bands, VALUE state, VALUE registers)
{
	long n = dyn_check_outputs(outs);
	long nb = RARRAY_LEN(outs);
	Check_Type(bands, T_ARRAY);
	if (RARRAY_LEN(bands) != nb) {
		rb_raise(rb_eArgError, "Expected one band register per output");
	}
	long nreg = NUM2LONG(registers);
	if (nreg < 1 || nreg > 256) {
		rb_raise(rb_eArgError, "Register count must be 1..256");
	}
	const double *prog = dyn_dfloat_read(program, 0, "Program");
	long nrow = (long)RNARRAY_SIZE(program) / XO_ROW;
	double *st = dyn_dfloat_ptr(state, nrow * 2, "State");

	long band_reg[256];
	if (nb > 256) {
		rb_raise(rb_eArgError, "Too many bands");
	}
	for (long b = 0; b < nb; b++) {
		band_reg[b] = NUM2LONG(rb_ary_entry(bands, b));
		if (band_reg[b] < 0 || band_reg[b] >= nreg) {
			rb_raise(rb_eArgError, "Band register out of range");
		}
	}
	for (long r = 0; r < nrow; r++) {
		const double *row = prog + r * XO_ROW;
		for (int j = 0; j < 3; j++) {
			if (row[j] < 0 || row[j] >= nreg) {
				rb_raise(rb_eArgError, "Program register out of range");
			}
		}
		if (row[3] < XO_SPLIT || row[3] > XO_LOW_MINUS_HIGH) {
			rb_raise(rb_eArgError, "Unknown crossover op kind");
		}
	}

	struct mb_signal x;
	mb_signal_input(&input, n, "Input", &x);
	float **out = ALLOCA_N(float *, nb);
	for (long b = 0; b < nb; b++) {
		out[b] = mb_sfloat_ptr(rb_ary_entry(outs, b));
	}

	double reg[256];
	memset(reg, 0, sizeof(reg));

	for (long i = 0; i < n; i++) {
		reg[0] = mb_signal_at(&x, i);
		for (long r = 0; r < nrow; r++) {
			const double *row = prog + r * XO_ROW;
			double *s = st + r * 2;
			double a1 = row[4], a2 = row[5], a3 = row[6], k = row[7], sign = row[8];
			double v0 = reg[(long)row[0]];
			double v3 = v0 - s[1];
			double v1 = a1 * s[0] + a2 * v3;
			double v2 = s[1] + a2 * s[0] + a3 * v3;
			s[0] = 2.0 * v1 - s[0];
			s[1] = 2.0 * v2 - s[1];
			if (fabs(s[0]) < DYN_FLUSH) {
				s[0] = 0.0;
			}
			if (fabs(s[1]) < DYN_FLUSH) {
				s[1] = 0.0;
			}
			double lp = v2;
			double hp = v0 - k * v1 - v2;
			switch ((int)row[3]) {
			case XO_SPLIT:
				reg[(long)row[1]] = lp;
				reg[(long)row[2]] = hp * sign;
				break;
			case XO_LOW:
				reg[(long)row[1]] = lp;
				break;
			case XO_HIGH:
				reg[(long)row[1]] = hp * sign;
				break;
			case XO_ALLPASS:
				reg[(long)row[1]] = v0 - 2.0 * k * v1;
				break;
			default:
				reg[(long)row[1]] = lp - hp;
				break;
			}
		}
		for (long b = 0; b < nb; b++) {
			out[b][i] = (float)reg[band_reg[b]];
		}
	}

	RB_GC_GUARD(input);
	RB_GC_GUARD(outs);
	RB_GC_GUARD(program);
	RB_GC_GUARD(bands);
	RB_GC_GUARD(state);

	return outs;
}

void Init_fast_dynamics(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_dynamics = rb_define_module_under(sound, "FastDynamics");

	rb_define_module_function(fast_dynamics, "compand", ruby_compand, 8);
	rb_define_module_function(fast_dynamics, "limit", ruby_limit, 6);
	rb_define_module_function(fast_dynamics, "crossover", ruby_crossover, 6);
}
