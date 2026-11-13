/*
 * The filter bank kernel (GraphNode::FilterBank, filterbank-1, 2026-11-13;
 * design/notes/filter_bank.md): N SVF sections (mb_svf.h's design and step)
 * in parallel, mixed into C output channels, or in series.  Shared by
 * fast_filter (FastFilter.filter_bank) and fast_plan (OP_FILTER_BANK, see
 * plan_filter_bank.c), so a planned bank runs the same operations as its
 * node.  Exact Ruby mirror: MB::Sound::GraphNode::FilterBank.process_ruby.
 * Built with -ffp-contract=off in both extensions.
 *
 * The bank's settings are a DFloat (+cfg+, the node's @config):
 *
 *   header (MB_FB_HEADER values):
 *     [0] layout version (MB_FB_VERSION)
 *     [1] bands N, [2] channels C
 *     [3] topology: 0 parallel (summed), 1 serial (chained, mono)
 *     [4] normalize: 0 none, 1 pink power (bandpass types), 2 the morph
 *         tables' width law (Formant: -ln(width scale) / 2 added to ln g)
 *     [5] pan law of node pans (0 :equal_power, 1 :linear, 2 :minus_4_5db)
 *     [6] signals expected (the length of the signal list)
 *     [7] morph snapshots S (0: the bands' own settings)
 *     [8, 9] morph position slot and constant, [10, 11] shift (semitones),
 *     [12, 13] width scale (the morph front end's settings)
 *     [14, 15] unused (0)
 *
 *   then each band (MB_FB_BAND + C values):
 *     [0] SVF type id (mb_svf.h; + SVF_MATCHED for matched designs)
 *     [1, 2] frequency F slot and constant, [3, 4] ratio R slot and
 *     constant, [5] harmonic offset h: the band's frequency is
 *     F (1 + R h) Hz
 *     [6] width mode: 0 Q, 1 octaves (Cookbook's digital bandwidth:
 *     Q = 0.5 / sinh(bw w0 ln 2 / (2 sin w0)) at w0 = 2 pi f / rate, f
 *     clamped to 1e-10..0.49 rate), 2 Hz (Q = f / bw)
 *     [7, 8] width slot and constant, [9, 10] linear gain slot and
 *     constant, [11, 12] pan slot and constant (a slot >= 0: a node pan,
 *     two channels only, gains from the pan law on every change; else the
 *     gain vector below)
 *     [13 .. 13 + C - 1] the band's gain into each channel
 *
 *   then, with S > 0, the morph tables: 3 S N values, the natural logs of
 *   each snapshot's band frequencies (Hz), qualities, and linear gains
 *   (snapshot-major within each of the three blocks).  Morph banks take
 *   their frequencies, qualities, and gains from the tables (the bands'
 *   own frequency, width, and gain fields are unused): when the morph
 *   position, shift, or width scale changes, each band's log values
 *   interpolate between the two snapshots around the position (0..1
 *   across the snapshots, clamped), the shift adds shift ln(2) / 12 to the
 *   frequency, the width scale (at least MB_FB_MIN_WIDTH) subtracts its log
 *   from the quality, and normalize 2 adds -ln(scale) / 2 to the gain; the
 *   band's coefficients use exp of each (GraphNode::Formant's old kernel,
 *   moved here: the same operations).
 *
 * A slot is an index into the signal list (+sig+: one signal input per
 * distinct node, sampled once per block), or -1 for the constant beside
 * it.  Coefficients are recomputed only on samples where a signal read by
 * a design setting (frequency, ratio, width, gain, or a morph setting)
 * changes (every band then recomputes its settings; a band whose
 * frequency, Q, and gain are unchanged keeps its coefficients).  Node pans
 * are recomputed only on samples where a pan signal changes, once per
 * distinct pan signal (bands sharing a pan node share its gains;
 * filterbank-pan-1), so moving pans cost a pan law per moving pan node
 * and leave the bands' designs alone.
 *
 * Parallel banks sum each band's output times its channel gains in double
 * (band order), then multiply by the normalization scale (normalize 1:
 * sqrt(MB_FB_NORM_REF / sum of g^2 P(Q)), P(Q) = 2 atan(sqrt(4 Q^2 - 1)) /
 * sqrt(4 Q^2 - 1) the power an analog bandpass of peak gain 1 passes from
 * pink noise; the atanh form below Q 0.5, 2 at 0.5; a skirt bandpass's
 * peak gain is g Q), and write float32.  Serial banks feed each band's
 * output, rounded to float32, to the next (as a chain of FastFilter.svf
 * calls on one buffer did).
 *
 * The state (+st+, the node's @state) is 2 integrator states per band and
 * the samples since the last flush grid point (MB_FLUSH_GRID).
 */
#ifndef MB_FILTER_BANK_H
#define MB_FILTER_BANK_H

#include <math.h>

#include "mb_ext_helpers.h"
#include "mb_svf.h"

#define MB_FB_VERSION 1
#define MB_FB_HEADER 16
#define MB_FB_BAND 13
#define MB_FB_MAX_BANDS 512
#define MB_FB_MAX_CHANNELS 16
#define MB_FB_MAX_SIGNALS 2048
#define MB_FB_MAX_SNAPSHOTS 256
// The highest cutoff as a fraction of the rate (FP_MAX_CUTOFF_RATIO,
// Filter::SVF::MAX_CUTOFF_RATIO)
#define MB_FB_MAX_CUTOFF_RATIO 0.49
// The narrowest morph width scale (Formant::MIN_WIDTH)
#define MB_FB_MIN_WIDTH 0.01
// ln(10000 / 100): pink noise's power over 100 Hz-10 kHz, per unit of
// power per natural log of frequency (FilterBank::NORMALIZE_REFERENCE)
#define MB_FB_NORM_REF 4.605170185988092

enum { MB_FB_WIDTH_Q = 0, MB_FB_WIDTH_OCTAVES = 1, MB_FB_WIDTH_HZ = 2 };

// The number of config values for +nbands+ bands of +nch+ channels and
// +nsnap+ morph snapshots.
static inline size_t mb_fbank_config_length(long nbands, long nch, long nsnap)
{
	return MB_FB_HEADER + (size_t)nbands * (MB_FB_BAND + (size_t)nch) + 3 * (size_t)nsnap * (size_t)nbands;
}

// Raises unless +cfg+ (+len+ values) is a bank config for +nsig+ signals,
// +nouts+ outputs, and a state of +stlen+ values (see the description).
static inline void mb_fbank_check(const double *cfg, size_t len, long nsig, long nouts, size_t stlen)
{
	if (len < MB_FB_HEADER || cfg[0] != MB_FB_VERSION) {
		rb_raise(rb_eArgError, "Not a filter bank config (version %d)", MB_FB_VERSION);
	}
	double nb = cfg[1], nc = cfg[2], ns = cfg[7];
	if (!(nb >= 1 && nb <= MB_FB_MAX_BANDS && nb == floor(nb))) rb_raise(rb_eArgError, "A filter bank has 1 to %d bands", MB_FB_MAX_BANDS);
	if (!(nc >= 1 && nc <= MB_FB_MAX_CHANNELS && nc == floor(nc))) rb_raise(rb_eArgError, "A filter bank has 1 to %d channels", MB_FB_MAX_CHANNELS);
	if (!(ns >= 0 && ns <= MB_FB_MAX_SNAPSHOTS && ns == floor(ns))) rb_raise(rb_eArgError, "A filter bank has 0 to %d morph snapshots", MB_FB_MAX_SNAPSHOTS);
	long nbands = (long)nb, nch = (long)nc, nsnap = (long)ns;
	if (len != mb_fbank_config_length(nbands, nch, nsnap)) rb_raise(rb_eArgError, "The filter bank config has the wrong length");
	if (cfg[3] != 0 && cfg[3] != 1) rb_raise(rb_eArgError, "Bad filter bank topology");
	if (cfg[3] == 1 && (nch != 1 || nsnap != 0 || cfg[4] != 0)) rb_raise(rb_eArgError, "Serial filter banks are mono, without morph tables or normalization");
	if (cfg[4] != 0 && cfg[4] != 1 && cfg[4] != 2) rb_raise(rb_eArgError, "Bad filter bank normalization");
	if (cfg[4] == 2 && nsnap == 0) rb_raise(rb_eArgError, "Width-law normalization needs morph tables");
	if (cfg[5] != 0 && cfg[5] != 1 && cfg[5] != 2) rb_raise(rb_eArgError, "Bad filter bank pan law");
	if (cfg[6] != (double)nsig || nsig < 0 || nsig > MB_FB_MAX_SIGNALS) rb_raise(rb_eArgError, "The filter bank expects %ld signals (got %ld)", (long)cfg[6], nsig);
	if (nouts != nch) rb_raise(rb_eArgError, "The filter bank has %ld channels (got %ld outputs)", nch, nouts);
	if (stlen != 2 * (size_t)nbands + 1) rb_raise(rb_eArgError, "The filter bank state must have %ld values", 2 * nbands + 1);

	for (int k = 8; k <= 12; k += 2) {
		double s = cfg[k];
		if (!(s >= -1 && s < nsig && s == floor(s))) rb_raise(rb_eArgError, "Bad filter bank signal slot");
	}
	for (long b = 0; b < nbands; b++) {
		const double *bd = cfg + MB_FB_HEADER + b * (MB_FB_BAND + nch);
		double t = bd[0];
		if (!(t == floor(t) && mb_svf_type_valid((int)t))) rb_raise(rb_eArgError, "Bad filter bank band type");
		if (cfg[4] == 1 && (((int)t & ~SVF_MATCHED) != SVF_BANDPASS && ((int)t & ~SVF_MATCHED) != SVF_BANDPASS_SKIRT)) {
			rb_raise(rb_eArgError, "Normalized filter banks take bandpass bands");
		}
		if (bd[6] != MB_FB_WIDTH_Q && bd[6] != MB_FB_WIDTH_OCTAVES && bd[6] != MB_FB_WIDTH_HZ) rb_raise(rb_eArgError, "Bad filter bank width mode");
		for (int k = 1; k <= 11; k += 2) {
			if (k == 5) continue;
			double s = bd[k];
			if (!(s >= -1 && s < nsig && s == floor(s))) rb_raise(rb_eArgError, "Bad filter bank signal slot");
		}
		if (bd[11] >= 0 && nch != 2) rb_raise(rb_eArgError, "Node pans need two channels");
	}
}

// The pan law gains of position +p+ (ChannelMixer::PanLaws.gains: p clamped
// to -1..1, NaN as 0).
static inline void mb_fbank_pan(int law, double p, double *g)
{
	if (!(p >= -1.0)) {
		p = p != p ? 0.0 : -1.0;
	} else if (p > 1.0) {
		p = 1.0;
	}
	switch (law) {
		case 1:
			g[0] = (1 - p) * 0.5;
			g[1] = (p + 1) * 0.5;
			break;
		case 2:
			g[0] = pow((1 - p) * 0.5, 0.75);
			g[1] = pow((p + 1) * 0.5, 0.75);
			break;
		default: {
			double angle = (p + 1) * (M_PI / 4);
			g[0] = cos(angle);
			g[1] = sin(angle);
			break;
		}
	}
}

// The power an analog bandpass of peak gain 1 at quality +q+ passes from
// pink noise (per unit of input power per natural log of frequency).
static inline double mb_fbank_pink_power(double q)
{
	double d = 4.0 * q * q - 1.0;
	if (d > 0.0) {
		double r = sqrt(d);
		return 2.0 * atan(r) / r;
	} else if (d < 0.0) {
		double r = sqrt(-d);
		return 2.0 * atanh(r) / r;
	}
	return 2.0;
}

// Updates +s+ for +type+ at +fc+, +q+, +G+ (as mb_svf_coefficients),
// returning 1 if they changed.
static inline int mb_fbank_update(struct mb_svf *s, int type, double fc, double q, double G, double pi_over_rate, double fc_max)
{
	if (fc == s->last_fc && q == s->last_q && G == s->last_g) {
		return 0;
	}
	mb_svf_coefficients(s, type, fc, q, G, pi_over_rate, fc_max);
	return 1;
}

// The value of slot +slot+ (a signal's sample +i+ read into +vals+) or the
// constant +c+.
static inline double mb_fbank_value(const double *vals, double slot, double c)
{
	return slot >= 0 ? vals[(long)slot] : c;
}

// Runs +n+ samples of input +x+ through the bank (see the description):
// +cfg+ the checked config (mb_fbank_check), +sig+ the +nsig+ signals,
// +outs+ one float32 buffer per channel, +st+ the state, +rate+ the sample
// rate.
static inline void mb_fbank_run(const double *cfg, const struct mb_signal *x, const struct mb_signal *sig, long nsig,
		float **outs, double *st, double rate, size_t n)
{
	const long nbands = (long)cfg[1];
	const long nch = (long)cfg[2];
	const int serial = cfg[3] == 1;
	const int normalize = (int)cfg[4];
	const int law = (int)cfg[5];
	const long nsnap = (long)cfg[7];
	const long stride = MB_FB_BAND + nch;
	const double *bands = cfg + MB_FB_HEADER;
	const double *tables = bands + nbands * stride;

	const double pi_over_rate = M_PI / rate;
	const double fc_max = rate * MB_FB_MAX_CUTOFF_RATIO;
	const double semitone_log = log(2.0) / 12.0;

	struct mb_svf svf[nbands];
	double power[nbands];
	double pan_gain[nbands][2];
	double last_pan[nbands];
	long pan_owner[nbands]; // (the first band reading the same pan signal; -1 for none)
	const double *mix[nbands];
	double vals[nsig > 0 ? nsig : 1];
	unsigned char design[nsig > 0 ? nsig : 1]; // (1 for signals a design setting reads)
	double acc[nch];

	// vals holds each pan signal's first band while the owners are found
	for (long s = 0; s < nsig; s++) {
		vals[s] = -1.0;
		design[s] = 0;
	}
	if (nsnap > 0) {
		for (int k = 8; k <= 12; k += 2) {
			if (cfg[k] >= 0) {
				design[(long)cfg[k]] = 1;
			}
		}
	}
	for (long b = 0; b < nbands; b++) {
		const double *bd = bands + b * stride;
		mb_svf_init(&svf[b]);
		power[b] = 0.0;
		last_pan[b] = NAN;
		pan_gain[b][0] = pan_gain[b][1] = 0.0;
		if (nsnap == 0) {
			for (int k = 1; k <= 9; k += 2) {
				if (k != 5 && bd[k] >= 0) {
					design[(long)bd[k]] = 1;
				}
			}
		}
		pan_owner[b] = -1;
		if (bd[11] >= 0) {
			long s = (long)bd[11];
			if (vals[s] < 0) {
				vals[s] = (double)b;
			}
			pan_owner[b] = (long)vals[s];
		}
		mix[b] = pan_owner[b] >= 0 ? pan_gain[pan_owner[b]] : bd + MB_FB_BAND;
	}
	for (long s = 0; s < nsig; s++) {
		vals[s] = NAN;
	}

	long fk = 0;
	{
		double c = st[2 * nbands];
		if (c >= 0 && c < MB_FLUSH_GRID) {
			fk = (long)c;
		}
	}

	double scale = 1.0;
	for (size_t i = 0; i < n; i++) {
		int changed = i == 0; // (a design signal changed)
		int panned = i == 0; // (a signal changed: pans to check)
		for (long s = 0; s < nsig; s++) {
			double v = mb_signal_at(&sig[s], i);
			// (NaN != NaN, so a NaN signal recomputes every sample)
			if (v != vals[s]) {
				vals[s] = v;
				changed |= design[s];
				panned = 1;
			}
		}

		if (changed) {
			int moved = 0;

			if (nsnap > 0) {
				double m = mb_fbank_value(vals, cfg[8], cfg[9]);
				double sh = mb_fbank_value(vals, cfg[10], cfg[11]);
				double w = mb_fbank_value(vals, cfg[12], cfg[13]);

				long lo = 0, hi = 0;
				double frac = 0.0;
				if (nsnap > 1) {
					double mc = m;
					if (!(mc >= 0.0)) {
						mc = 0.0;
					} else if (mc > 1.0) {
						mc = 1.0;
					}
					double pos = mc * (double)(nsnap - 1);
					lo = (long)floor(pos);
					if (lo > nsnap - 2) {
						lo = nsnap - 2;
					}
					hi = lo + 1;
					frac = pos - (double)lo;
				}

				double shift_log = sh * semitone_log;
				double wc = w;
				if (!(wc >= MB_FB_MIN_WIDTH)) {
					wc = MB_FB_MIN_WIDTH;
				}
				double width_log = log(wc);
				double level_log = normalize == 2 ? width_log * -0.5 : 0.0;
				size_t block = (size_t)nsnap * (size_t)nbands;

				for (long b = 0; b < nbands; b++) {
					size_t a = (size_t)lo * nbands + b;
					size_t c = (size_t)hi * nbands + b;
					double lf = tables[a] + (tables[c] - tables[a]) * frac + shift_log;
					double lq = tables[block + a] + (tables[block + c] - tables[block + a]) * frac - width_log;
					double lg = tables[2 * block + a] + (tables[2 * block + c] - tables[2 * block + a]) * frac + level_log;
					moved |= mb_fbank_update(&svf[b], (int)bands[b * stride], exp(lf), exp(lq), exp(lg), pi_over_rate, fc_max);
				}
			} else {
				for (long b = 0; b < nbands; b++) {
					const double *bd = bands + b * stride;
					int type = (int)bd[0];
					double F = mb_fbank_value(vals, bd[1], bd[2]);
					double R = mb_fbank_value(vals, bd[3], bd[4]);
					double f = F * (1.0 + R * bd[5]);
					double W = mb_fbank_value(vals, bd[7], bd[8]);
					double G = mb_fbank_value(vals, bd[9], bd[10]);
					double q;
					if (bd[6] == MB_FB_WIDTH_OCTAVES) {
						double fq = f;
						if (fq < 1e-10 || !isfinite(fq)) {
							fq = 1e-10;
						} else if (fq > fc_max) {
							fq = fc_max;
						}
						double w0 = 2.0 * M_PI * fq / rate;
						q = 0.5 / sinh(W * w0 * log(2.0) / (2.0 * sin(w0)));
					} else if (bd[6] == MB_FB_WIDTH_HZ) {
						q = f / W;
					} else {
						q = W;
					}

					if (mb_fbank_update(&svf[b], type, f, q, G, pi_over_rate, fc_max) && normalize == 1) {
						double qc = q >= SVF_MIN_QUALITY ? q : SVF_MIN_QUALITY;
						double gc = G >= SVF_MIN_GAIN ? G : SVF_MIN_GAIN;
						double pk = (type & ~SVF_MATCHED) == SVF_BANDPASS_SKIRT ? gc * qc : gc;
						power[b] = pk * pk * mb_fbank_pink_power(qc);
						moved = 1;
					}
				}
			}

			if (normalize == 1 && moved) {
				double sum = 0.0;
				for (long b = 0; b < nbands; b++) {
					sum += power[b];
				}
				scale = sum > 0.0 ? sqrt(MB_FB_NORM_REF / sum) : 1.0;
			}
		}

		if (panned) {
			for (long b = 0; b < nbands; b++) {
				if (pan_owner[b] == b) {
					double p = vals[(long)bands[b * stride + 11]];
					if (p != last_pan[b]) {
						last_pan[b] = p;
						mb_fbank_pan(law, p, pan_gain[b]);
					}
				}
			}
		}

		double xi = mb_signal_at(x, i);
		if (serial) {
			double v = xi;
			for (long b = 0; b < nbands; b++) {
				v = (float)mb_svf_step(&svf[b], v, &st[2 * b], &st[2 * b + 1]);
			}
			outs[0][i] = (float)v;
		} else {
			for (long c = 0; c < nch; c++) {
				acc[c] = 0.0;
			}
			for (long b = 0; b < nbands; b++) {
				double y = mb_svf_step(&svf[b], xi, &st[2 * b], &st[2 * b + 1]);
				const double *g = mix[b];
				for (long c = 0; c < nch; c++) {
					acc[c] += g[c] * y;
				}
			}
			if (normalize == 1) {
				for (long c = 0; c < nch; c++) {
					outs[c][i] = (float)(acc[c] * scale);
				}
			} else {
				for (long c = 0; c < nch; c++) {
					outs[c][i] = (float)acc[c];
				}
			}
		}

		if (++fk >= MB_FLUSH_GRID) {
			fk = 0;
			for (long k = 0; k < 2 * nbands; k++) {
				mb_flush_value(&st[k]);
			}
		}
	}

	st[2 * nbands] = (double)fk;
}

#endif
