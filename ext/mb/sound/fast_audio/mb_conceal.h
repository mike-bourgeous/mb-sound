/*
 * Underrun concealment for playback (audio-safety-1, 2026-10-25): when the
 * writer misses a deadline and the ring runs dry, the device thread plays
 * grains of the last audio it played instead of silence, then crossfades
 * back once real audio arrives.  See design/notes/audio_io.md ("Underrun
 * concealment") for the design and measurements.
 *
 * - History: every real frame played goes into a ring of the last
 *   +history+ frames (and as many again, so the crossfade back can push
 *   real frames without overwriting what the grains read).
 * - Entry: the first grain starts where the last few frames before the gap
 *   best match (least squared error over +match_window+ frames, lags from
 *   +grain_min+ to +grain_min + match_search+), with the remaining step
 *   added as an offset that decays over ~2 ms.
 * - Grains: lengths drawn from grain_min..grain_max and positions drawn from
 *   the whole history (counter-based splitmix64, so the same events give the
 *   same output), each crossfaded into the next with an equal-power
 *   (sine/cosine) seam as long as the shorter of the two grains allows, so
 *   there is no fixed repetition period (a fixed grain buzzes at
 *   rate / length).  +fixed+ loops the latest grain_min frames instead, for
 *   comparisons.
 * - Level: concealed samples are clipped at the history's peak (equal-power
 *   seams of correlated grains, like two drum hits, can sum 3 dB over it).
 * - Decay: the concealed output falls 60 dB over +fade+ seconds (then
 *   silence), or over +quiet_fade+ once the writer marked the end of its
 *   audio (the gap is intended).
 * - Return: real audio fades in over +exit_frames+ while the grains fade
 *   out (equal power).  Late audio is played, not dropped: the ring and the
 *   device clock move exactly as without concealment.
 *
 * Device-thread safe: no allocation or locks after mb_conceal_init.  The
 * Ruby reference is MB::Sound::Concealment::Reference (compared in
 * spec/ext/mb/sound/fast_audio_conceal_spec.rb).
 */
#ifndef MB_CONCEAL_H
#define MB_CONCEAL_H

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MB_CONCEAL_MAX_CHANNELS 64

enum { MB_CONCEAL_SILENCE = 0, MB_CONCEAL_REPEAT = 1 };

struct mb_conceal_settings {
	int mode; // MB_CONCEAL_SILENCE or MB_CONCEAL_REPEAT
	int fixed; // loop the latest grain_min frames (no jitter; comparisons)
	double history; // seconds of history grains come from
	double grain_min, grain_max; // seconds
	double fade; // seconds to -60 dB (0 or less: no decay)
	double quiet_fade; // seconds to -60 dB after the writer's end mark
	double return_fade; // seconds of crossfade back to real audio
	double match; // seconds compared when choosing the first grain
	double search; // seconds of lags searched for the first grain
	uint64_t seed;
};

struct mb_conceal_grain {
	uint64_t src; // first history frame (absolute)
	size_t len;
	size_t i; // frames played
};

struct mb_conceal {
	int mode, fixed, ch;
	float *hist; // interleaved frames, cap frames
	size_t cap; // a power of two
	uint64_t total; // frames pushed since opening
	size_t history, grain_min, grain_max, match_window, match_search, exit_frames;
	double decay, quiet_decay, floor_gain, offset_decay, cur_decay;
	uint64_t seed, draws;

	// Concealment state
	int active; // concealment contributes (until the crossfade back ends)
	int faded; // decayed below floor_gain: zeros
	int in_exit; // crossfading back to real audio
	uint64_t t0; // history end when the gap began
	size_t avail; // history frames grains may read, ending at t0
	double gain;
	double peak; // the history's peak: concealed samples never exceed it
	double offset[MB_CONCEAL_MAX_CHANNELS];
	struct mb_conceal_grain cur, nxt;
	size_t h; // seam length from cur to nxt
	size_t h_in; // cur's fade-in length
	int in_seam;
	size_t j; // seam frames done
	double sc, ss, scd, ssd; // seam cos/sin and their step
	size_t xj; // return frames done
	double xc, xs, xcd, xsd; // return cos/sin and their step

	// Counters (device thread; copied out for stats)
	uint64_t frames; // concealed frames (including faded zeros)
	uint64_t events; // gaps concealed
};

static inline size_t mb_conceal_seconds(double seconds, double rate)
{
	double f = round(seconds * rate);
	return f < 1 ? 1 : (size_t)f;
}

// Sets up +c+ (zeroed first) for +channels+ at +rate+; allocates the history
// in repeat mode.  Returns 0, or -1 if the allocation failed.  Settings are
// checked by the caller (MB::Sound::Concealment.settings).
static inline int mb_conceal_init(struct mb_conceal *c, const struct mb_conceal_settings *s, int channels, double rate)
{
	memset(c, 0, sizeof(*c));
	c->mode = s->mode;
	c->fixed = s->fixed;
	c->ch = channels;
	c->history = mb_conceal_seconds(s->history, rate);
	c->grain_min = mb_conceal_seconds(s->grain_min, rate);
	if (c->grain_min < 2) {
		c->grain_min = 2;
	}
	c->grain_max = mb_conceal_seconds(s->grain_max, rate);
	if (c->grain_max < c->grain_min) {
		c->grain_max = c->grain_min;
	}
	c->match_window = mb_conceal_seconds(s->match, rate);
	c->match_search = mb_conceal_seconds(s->search, rate);
	c->exit_frames = mb_conceal_seconds(s->return_fade, rate);
	c->decay = s->fade > 0 ? pow(10.0, -3.0 / (s->fade * rate)) : 1.0;
	c->quiet_decay = pow(10.0, -3.0 / ((s->quiet_fade > 0 ? s->quiet_fade : 1e-3) * rate));
	c->floor_gain = 1e-3;
	c->offset_decay = exp(-1.0 / (0.002 * rate));
	c->cur_decay = c->decay;
	c->seed = s->seed;

	if (c->mode != MB_CONCEAL_REPEAT) {
		return 0;
	}

	size_t need = 2 * c->history;
	if (need < c->history + c->exit_frames + 1) {
		need = c->history + c->exit_frames + 1;
	}
	size_t cap = 16;
	while (cap < need) {
		cap <<= 1;
	}
	c->hist = calloc(cap * (size_t)channels, sizeof(float));
	if (c->hist == NULL) {
		return -1;
	}
	c->cap = cap;
	return 0;
}

static inline void mb_conceal_free(struct mb_conceal *c)
{
	free(c->hist);
	c->hist = NULL;
}

static inline float mb_conceal_at(const struct mb_conceal *c, uint64_t pos, int k)
{
	return c->hist[(size_t)(pos & (c->cap - 1)) * c->ch + k];
}

// Appends +n+ real interleaved frames to the history.
static inline void mb_conceal_push(struct mb_conceal *c, const float *in, size_t n)
{
	size_t ch = c->ch;
	if (n > c->cap) {
		in += (n - c->cap) * ch;
		c->total += n - c->cap;
		n = c->cap;
	}

	size_t start = (size_t)(c->total & (c->cap - 1));
	size_t first = c->cap - start;
	if (first > n) {
		first = n;
	}
	memcpy(c->hist + start * ch, in, first * ch * sizeof(float));
	memcpy(c->hist, in + first * ch, (n - first) * ch * sizeof(float));
	c->total += n;
}

// A counter-based draw from lo..hi (splitmix64 of the seed and draw count).
static inline size_t mb_conceal_pick(struct mb_conceal *c, size_t lo, size_t hi)
{
	c->draws++;
	uint64_t z = c->seed + c->draws * 0x9E3779B97F4A7C15ULL;
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	z ^= z >> 31;
	if (hi <= lo) {
		return lo;
	}
	return lo + (size_t)(z % (uint64_t)(hi - lo + 1));
}

// Draws the grain after cur and the seam length between them.
static inline void mb_conceal_next(struct mb_conceal *c)
{
	struct mb_conceal_grain *g = &c->nxt;
	if (c->fixed) {
		g->len = c->grain_min < c->avail ? c->grain_min : c->avail;
		g->src = c->t0 - g->len;
	} else {
		size_t max = c->grain_max < c->avail ? c->grain_max : c->avail;
		g->len = mb_conceal_pick(c, c->grain_min, max);
		g->src = c->t0 - mb_conceal_pick(c, g->len, c->avail);
	}
	g->i = 0;

	size_t room = c->cur.len - c->h_in;
	size_t half = g->len / 2;
	size_t h = room < half ? room : half;
	c->h = h < 1 ? 1 : h;
	c->in_seam = 0;
}

static inline void mb_conceal_rotate(double *cs, double *sn, double cd, double sd)
{
	double c = *cs * cd - *sn * sd;
	double s = *sn * cd + *cs * sd;
	*cs = c;
	*sn = s;
}

// Writes the next concealed frame into +out+ (ch samples).
static inline void mb_conceal_frame(struct mb_conceal *c, float *out)
{
	int ch = c->ch;
	if (c->faded) {
		memset(out, 0, ch * sizeof(float));
		return;
	}

	if (!c->in_seam && c->cur.i + c->h >= c->cur.len) {
		double d = M_PI / (2.0 * c->h);
		c->in_seam = 1;
		c->j = 0;
		c->sc = cos(0.5 * d);
		c->ss = sin(0.5 * d);
		c->scd = cos(d);
		c->ssd = sin(d);
	}

	for (int k = 0; k < ch; k++) {
		double v = mb_conceal_at(c, c->cur.src + c->cur.i, k);
		if (c->in_seam) {
			v = v * c->sc + (double)mb_conceal_at(c, c->nxt.src + c->nxt.i, k) * c->ss;
		}
		double y = c->gain * v + c->offset[k];
		if (y > c->peak) {
			y = c->peak;
		} else if (y < -c->peak) {
			y = -c->peak;
		}
		out[k] = (float)y;
		c->offset[k] *= c->offset_decay;
	}

	c->cur.i++;
	if (c->in_seam) {
		c->nxt.i++;
		c->j++;
		mb_conceal_rotate(&c->sc, &c->ss, c->scd, c->ssd);
		if (c->j >= c->h) {
			c->cur = c->nxt;
			c->h_in = c->h;
			mb_conceal_next(c);
		}
	}

	c->gain *= c->cur_decay;
	if (c->gain < c->floor_gain) {
		c->gain = 0;
		c->faded = 1;
	}
}

// Starts concealing at the end of the history.  Returns 0 (silence) if
// there isn't enough history.
static inline int mb_conceal_enter(struct mb_conceal *c)
{
	size_t avail = c->total < c->history ? (size_t)c->total : c->history;
	size_t w = c->match_window;
	if (avail < c->grain_min + w) {
		return 0;
	}

	c->t0 = c->total;
	c->avail = avail;
	int ch = c->ch;

	size_t d, len;
	if (c->fixed) {
		len = c->grain_min;
		d = len;
	} else {
		// The lag whose preceding frames best match the last ones
		size_t lo = c->grain_min;
		size_t hi = lo + c->match_search;
		if (hi > avail - w) {
			hi = avail - w;
		}
		size_t best = lo;
		double best_err = INFINITY;
		for (size_t dd = lo; dd <= hi; dd++) {
			double e = 0;
			for (size_t jj = 1; jj <= w && e < best_err; jj++) {
				for (int k = 0; k < ch; k++) {
					double a = (double)mb_conceal_at(c, c->t0 - jj, k) - (double)mb_conceal_at(c, c->t0 - dd - jj, k);
					e += a * a;
				}
			}
			if (e < best_err) {
				best_err = e;
				best = dd;
			}
		}
		d = best;
		size_t max = c->grain_max < d ? c->grain_max : d;
		len = mb_conceal_pick(c, c->grain_min, max);
	}

	c->cur.src = c->t0 - d;
	c->cur.len = len;
	c->cur.i = 0;
	c->h_in = 0;
	for (int k = 0; k < ch; k++) {
		c->offset[k] = (double)mb_conceal_at(c, c->t0 - 1, k) - (double)mb_conceal_at(c, c->cur.src - 1, k);
	}
	// Equal-power seams of correlated grains (e.g. two drum hits) can
	// sum to 3 dB over the history's peak; concealment never goes past it
	double peak = 0;
	for (uint64_t pos = c->t0 - avail; pos < c->t0; pos++) {
		for (int k = 0; k < ch; k++) {
			double a = fabs((double)mb_conceal_at(c, pos, k));
			if (a > peak) {
				peak = a;
			}
		}
	}
	c->peak = peak;
	c->gain = 1;
	c->faded = 0;
	c->active = 1;
	c->in_exit = 0;
	c->events++;
	mb_conceal_next(c);
	return 1;
}

/*
 * Conceals a device pull: +out+ holds +count+ real interleaved frames
 * followed by silence up to +frames+.  Pushes the real frames into the
 * history, crossfades them in if concealment was running, and conceals the
 * rest.  +quiet+ is true when the writer marked the end of its audio (the
 * gap is intended: no new concealment, and a running one fades quickly).
 * Returns the number of frames concealed.
 */
static inline size_t mb_conceal_process(struct mb_conceal *c, float *out, size_t frames, size_t count, int quiet)
{
	if (c->mode != MB_CONCEAL_REPEAT) {
		return 0;
	}

	size_t ch = c->ch;
	c->cur_decay = quiet ? c->quiet_decay : c->decay;

	if (count > 0) {
		mb_conceal_push(c, out, count);

		// The grains' history must not have been overwritten (only after
		// long stutters of short writes and short gaps)
		if (c->active && c->total - c->t0 > c->cap - c->history) {
			c->active = 0;
			c->in_exit = 0;
		}

		for (size_t i = 0; i < count && c->active; i++) {
			if (!c->in_exit) {
				double d = M_PI / (2.0 * c->exit_frames);
				c->in_exit = 1;
				c->xj = 0;
				c->xc = cos(0.5 * d);
				c->xs = sin(0.5 * d);
				c->xcd = cos(d);
				c->xsd = sin(d);
			}

			float x[MB_CONCEAL_MAX_CHANNELS];
			mb_conceal_frame(c, x);
			float *o = out + i * ch;
			for (size_t k = 0; k < ch; k++) {
				// (clipped like the grains, or at the real sample if louder)
				double r = o[k];
				double y = r * c->xs + (double)x[k] * c->xc;
				double lim = fabs(r) > c->peak ? fabs(r) : c->peak;
				if (y > lim) {
					y = lim;
				} else if (y < -lim) {
					y = -lim;
				}
				o[k] = (float)y;
			}

			mb_conceal_rotate(&c->xc, &c->xs, c->xcd, c->xsd);
			c->xj++;
			if (c->xj >= c->exit_frames) {
				c->active = 0;
				c->in_exit = 0;
			}
		}
	}

	if (count >= frames) {
		return 0;
	}

	if (c->active) {
		c->in_exit = 0; // ran out again while returning
	} else if (quiet || !mb_conceal_enter(c)) {
		return 0;
	}

	for (size_t i = count; i < frames; i++) {
		mb_conceal_frame(c, out + i * ch);
	}
	c->frames += frames - count;
	return frames - count;
}

#endif
