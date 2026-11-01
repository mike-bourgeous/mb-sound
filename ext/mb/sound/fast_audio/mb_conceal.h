/*
 * Underrun concealment for playback (audio-safety-1, 2026-10-25; reworked
 * in audio-safety-2, 2026-11-01): when the writer misses a deadline and the
 * ring runs dry, the device thread plays grains of the last audio it played
 * instead of silence, then lands back on the real audio once it arrives.
 * See design/notes/audio_io.md ("Underrun concealment") for the design and
 * measurements.
 *
 * - History: every real frame played goes into a ring of the last
 *   +history+ frames.
 * - Entry: the first grain starts where the last few frames before the gap
 *   best match (least squared error over +match_window+ frames, lags from
 *   +grain_min+ to +grain_min + match_search+), with the remaining step
 *   added as an offset that decays over ~2 ms, and a break in the slope
 *   that a smooth signal doesn't have (more than twice its RMS second
 *   difference) bent away over ~0.25 ms, so pads don't get a corner.
 * - Grains: lengths drawn from grain_min..grain_max and positions drawn from
 *   the whole history (counter-based splitmix64, so the same events give the
 *   same output), each crossfaded into the next with a sine/cosine seam as
 *   long as the shorter of the two grains allows, so there is no fixed
 *   repetition period (a fixed grain buzzes at rate / length).  +fixed+
 *   loops the latest grain_min frames instead, for comparisons.
 * - Alignment: each drawn position moves by up to +align+ to where the next
 *   grain best matches the current one in the middle of their seam (least
 *   squares, as in WSOLA), so tones and pads cross in phase instead of
 *   beating, swelling into the peak clip, or chirping.
 * - Seam gains follow the two grains' correlation rho (0..1):
 *   (a x + b y) / sqrt(1 + 2 rho a b), equal power for uncorrelated grains,
 *   equal gain (no swell) for identical ones.
 * - Level: each grain is scaled down to at most +level+ over the RMS of the
 *   last grain_min frames before the gap (so kicks in the history don't fill
 *   a quiet gap with kicks), and concealed samples over the history's peak
 *   (uncorrelated grains summing in a seam) are limited softly (tanh) to
 *   at most 1 dB over it, and never past full scale.
 * - Decay: the concealed output holds its level for +hold+ seconds, then
 *   falls 60 dB over +fade+ seconds (then silence), or falls over
 *   +quiet_fade+ (no hold) once the writer marked the end of its audio (the
 *   gap is intended).
 * - Landing (the return): late audio is played, not dropped, so the real
 *   audio after a gap starts where it stopped, at the history's end t0.
 *   When it arrives, the grains cross (aligned, over +land_frames+) into a
 *   last grain that ends exactly at t0, with the level ramping back to
 *   full, and the real audio continues that grain sample for sample.  The
 *   real frames wait in the ring meanwhile (mb_conceal_take), 5-17 ms with
 *   the defaults.  Crossfading straight into the late audio, as before,
 *   met it at an unrelated phase (a gap of g frames shifts a tone's phase
 *   by g cycles' worth), and a return cut short by the ring running dry
 *   again stepped by the real audio's level: the maintainer's pops and
 *   chirps.
 *
 * Callers take frames from the ring with mb_conceal_take, then call
 * mb_conceal_process.  Device-thread safe: no allocation or locks after
 * mb_conceal_init.  The Ruby reference is MB::Sound::Concealment::Reference
 * (compared in spec/ext/mb/sound/fast_audio_conceal_spec.rb).
 */
#ifndef MB_CONCEAL_H
#define MB_CONCEAL_H

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MB_CONCEAL_MAX_CHANNELS 64

// The most concealed samples go over the history's peak (+1 dB; see
// mb_conceal_limit)
#define MB_CONCEAL_CEILING 1.1220184543019633

enum { MB_CONCEAL_SILENCE = 0, MB_CONCEAL_REPEAT = 1 };

// Landing states: concealing; the last grain is nxt (its seam pending or
// running); the last grain is playing; a seam is running, after which cur
// crosses into the last grain (fin).
enum { MB_CONCEAL_LAND_NONE = 0, MB_CONCEAL_LAND_NEXT = 1, MB_CONCEAL_LAND_LAST = 2, MB_CONCEAL_LAND_AFTER = 3 };

struct mb_conceal_settings {
	int mode; // MB_CONCEAL_SILENCE or MB_CONCEAL_REPEAT
	int fixed; // loop the latest grain_min frames (no jitter; comparisons)
	double history; // seconds of history grains come from
	double grain_min, grain_max; // seconds
	double hold; // seconds at full level before the decay starts
	double fade; // seconds to -60 dB after the hold (0 or less: no decay)
	double quiet_fade; // seconds to -60 dB after the writer's end mark
	double return_fade; // seconds of the seam into the last grain
	double match; // seconds compared when choosing the first grain
	double search; // seconds of lags searched for the first grain
	double align; // seconds each grain may move to match the one before (0: off)
	double level; // dB a grain may be over the level before the gap
	int level_cap; // level applies (else grains play as recorded)
	uint64_t seed;
};

struct mb_conceal_grain {
	uint64_t src; // first history frame (absolute)
	size_t len;
	size_t i; // frames played
	double g; // level (see mb_conceal_gain)
};

struct mb_conceal {
	int mode, fixed, ch;
	float *hist; // interleaved frames, cap frames
	size_t cap; // a power of two
	uint64_t total; // frames pushed since opening
	size_t history, grain_min, grain_max, match_window, match_search, land_frames;
	size_t hold_frames; // frames at full level before the decay
	size_t align_search, align_window; // seam alignment: lags each way, frames compared
	double level_ratio; // most a grain's RMS may be over ref_rms (0: no cap)
	double ref_rms; // RMS of the last grain_min frames before the gap
	double decay, quiet_decay, floor_gain, offset_decay, bend_decay, cur_decay;
	uint64_t seed, draws;

	// Concealment state
	int active; // concealing (until the last grain of the landing ends)
	int faded; // decayed below floor_gain: zeros
	int landing; // MB_CONCEAL_LAND_*
	size_t land_left; // frames until the last grain ends at t0
	uint64_t t0; // history end when the gap began
	size_t avail; // history frames grains may read, ending at t0
	double gain;
	size_t held; // frames held at full level so far (up to hold_frames)
	int quiet; // the writer marked the end of its audio: no hold
	double peak; // the history's peak: concealed samples never exceed it
	double offset[MB_CONCEAL_MAX_CHANNELS];
	double bend[MB_CONCEAL_MAX_CHANNELS], bend_u[MB_CONCEAL_MAX_CHANNELS]; // slope correction: (n + 1) d q^n
	struct mb_conceal_grain cur, nxt;
	struct mb_conceal_grain fin; // the landing's last grain (MB_CONCEAL_LAND_AFTER)
	double fin_rho; // its seam's rho
	size_t h; // seam length from cur to nxt
	size_t h_in; // cur's fade-in length
	int in_seam;
	size_t j; // seam frames done
	double sc, ss, scd, ssd; // seam cos/sin and their step
	double rho; // correlation of the seam's two grains (0..1)

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
	c->land_frames = mb_conceal_seconds(s->return_fade, rate);
	if (c->land_frames > c->grain_min) {
		c->land_frames = c->grain_min; // (so the history holds the last grain)
	}
	c->align_search = s->align > 0 ? (size_t)round(s->align * rate) : 0;
	c->align_window = mb_conceal_seconds(0.001, rate);
	c->level_ratio = s->level_cap ? pow(10.0, s->level / 20.0) : 0;
	c->hold_frames = s->hold > 0 ? (size_t)round(s->hold * rate) : 0;
	c->decay = s->fade > 0 ? pow(10.0, -3.0 / (s->fade * rate)) : 1.0;
	c->quiet_decay = pow(10.0, -3.0 / ((s->quiet_fade > 0 ? s->quiet_fade : 1e-3) * rate));
	c->floor_gain = 1e-3;
	c->offset_decay = exp(-1.0 / (0.002 * rate));
	c->bend_decay = exp(-1.0 / (0.00025 * rate));
	c->cur_decay = c->decay;
	c->seed = s->seed;

	if (c->mode != MB_CONCEAL_REPEAT) {
		return 0;
	}

	size_t cap = 16;
	while (cap < 2 * c->history) {
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

// The level of grain +g+: 1, or less if its RMS (every few frames) is over
// level_ratio times the level before the gap (ref_rms).
static inline double mb_conceal_gain(const struct mb_conceal *c, const struct mb_conceal_grain *g)
{
	if (c->level_ratio <= 0) {
		return 1.0;
	}
	size_t step = (g->len + 255) / 256;
	double sum = 0;
	size_t n = 0;
	for (size_t j = 0; j < g->len; j += step) {
		for (int k = 0; k < c->ch; k++) {
			double a = mb_conceal_at(c, g->src + j, k);
			sum += a * a;
		}
		n++;
	}
	double rms = sqrt(sum / (double)(n * c->ch));
	double cap = c->ref_rms * c->level_ratio;
	return rms > cap ? cap / rms : 1.0;
}

// The squared error of +w+ history frames at +a+ and at +b+, stopping once
// it reaches +limit+.
static inline double mb_conceal_err(const struct mb_conceal *c, uint64_t a, uint64_t b, size_t w, double limit)
{
	double e = 0;
	for (size_t jj = 0; jj < w && e < limit; jj++) {
		for (int k = 0; k < c->ch; k++) {
			double d = (double)mb_conceal_at(c, a + jj, k) - (double)mb_conceal_at(c, b + jj, k);
			e += d * d;
		}
	}
	return e;
}

// The start in from..to (history frames) where +w+ frames at +off+ best
// match the +w+ history frames at +at_cur+ (least squared error): every
// other start, then the neighbors of the best (the first best wins ties).
static inline uint64_t mb_conceal_best(const struct mb_conceal *c, uint64_t at_cur, uint64_t from, uint64_t to, size_t off, size_t w)
{
	uint64_t best = from;
	double best_err = INFINITY;
	for (uint64_t src = from; src <= to; src += 2) {
		double e = mb_conceal_err(c, at_cur, src + off, w, best_err);
		if (e < best_err) {
			best_err = e;
			best = src;
		}
	}
	uint64_t coarse = best;
	for (int side = -1; side <= 1; side += 2) {
		if ((side < 0 && coarse == from) || (side > 0 && coarse == to)) {
			continue;
		}
		uint64_t src = side < 0 ? coarse - 1 : coarse + 1;
		double e = mb_conceal_err(c, at_cur, src + off, w, best_err);
		if (e < best_err) {
			best_err = e;
			best = src;
		}
	}
	return best;
}

// Moves nxt's start by up to align_search frames to where it best matches
// cur in the middle of their seam, staying inside the history.
static inline void mb_conceal_align(struct mb_conceal *c)
{
	struct mb_conceal_grain *g = &c->nxt;
	size_t w = c->align_window < c->h ? c->align_window : c->h;
	size_t off = (c->h - w) / 2;
	uint64_t at_cur = c->cur.src + (c->cur.len - c->h) + off;
	uint64_t lo = c->t0 - c->avail;
	uint64_t hi = c->t0 - g->len;
	uint64_t s = c->align_search;
	uint64_t from = g->src > lo + s ? g->src - s : lo;
	uint64_t to = g->src + s < hi ? g->src + s : hi;
	g->src = mb_conceal_best(c, at_cur, from, to, off, w);
}

// The correlation (clamped to 0..1) of +h+ history frames at +a0+ and at
// +b0+, every few frames.
static inline double mb_conceal_rho(const struct mb_conceal *c, uint64_t a0, uint64_t b0, size_t h)
{
	size_t step = (h + 255) / 256;
	double sxy = 0, sxx = 0, syy = 0;
	for (size_t j = 0; j < h; j += step) {
		for (int k = 0; k < c->ch; k++) {
			double a = mb_conceal_at(c, a0 + j, k);
			double b = mb_conceal_at(c, b0 + j, k);
			sxy += a * b;
			sxx += a * a;
			syy += b * b;
		}
	}
	if (!(sxx > 0 && syy > 0)) {
		return 0;
	}
	double r = sxy / sqrt(sxx * syy);
	return r < 0 ? 0 : r > 1 ? 1 : r;
}

// The correlation of cur and nxt over their seam.
static inline double mb_conceal_seam_rho(const struct mb_conceal *c)
{
	return mb_conceal_rho(c, c->cur.src + (c->cur.len - c->h), c->nxt.src, c->h);
}

// Sets the seam length from cur into nxt (+half+ of nxt at most).
static inline void mb_conceal_seam(struct mb_conceal *c, size_t half)
{
	size_t room = c->cur.len - c->h_in;
	size_t h = room < half ? room : half;
	c->h = h < 1 ? 1 : h;
	c->in_seam = 0;
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
	mb_conceal_seam(c, g->len / 2);

	if (c->fixed) {
		g->g = 1.0;
		c->rho = 0;
		return;
	}
	if (c->align_search > 0) {
		mb_conceal_align(c);
	}
	c->rho = mb_conceal_seam_rho(c);
	g->g = mb_conceal_gain(c, g);
}

// +y+ unchanged up to +peak+, then limited softly (tanh) to
// MB_CONCEAL_CEILING times it, but never past full scale that the history
// didn't reach (hard at +peak+ if it did).
static inline double mb_conceal_limit(double y, double peak)
{
	double a = fabs(y);
	if (a <= peak) {
		return y;
	}
	double top = peak * MB_CONCEAL_CEILING;
	if (top > 1.0) {
		top = peak > 1.0 ? peak : 1.0;
	}
	double room = top - peak;
	if (!(room > 0)) {
		return y < 0 ? -peak : peak;
	}
	double l = peak + room * tanh((a - peak) / room);
	return y < 0 ? -l : l;
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

	if (c->landing) {
		// The level, the last grain's level, and the offset reach exactly
		// 1, 1, and 0 on the last frame, so it is the history's frame
		// before t0, which the real audio continues
		struct mb_conceal_grain *f = c->landing == MB_CONCEAL_LAND_LAST ? &c->cur : c->landing == MB_CONCEAL_LAND_NEXT ? &c->nxt : &c->fin;
		if (c->land_left <= 1) {
			c->gain = 1;
			f->g = 1;
			for (int k = 0; k < ch; k++) {
				c->offset[k] = 0;
				c->bend[k] = 0;
				c->bend_u[k] = 0;
			}
		} else {
			double n = (double)c->land_left;
			c->gain += (1 - c->gain) / n;
			f->g += (1 - f->g) / n;
			for (int k = 0; k < ch; k++) {
				c->offset[k] -= c->offset[k] / n;
				c->bend[k] -= c->bend[k] / n;
				c->bend_u[k] -= c->bend_u[k] / n;
			}
		}
	}

	if (!c->in_seam && c->landing != MB_CONCEAL_LAND_LAST && c->cur.i + c->h >= c->cur.len) {
		double d = M_PI / (2.0 * c->h);
		c->in_seam = 1;
		c->j = 0;
		c->sc = cos(0.5 * d);
		c->ss = sin(0.5 * d);
		c->scd = cos(d);
		c->ssd = sin(d);
	}

	// (a x + b y) / sqrt(1 + 2 rho a b): equal power for uncorrelated
	// grains, equal gain for identical ones
	double sg = c->in_seam ? 1.0 / sqrt(1.0 + 2.0 * c->rho * c->sc * c->ss) : 1.0;
	for (int k = 0; k < ch; k++) {
		double v = (double)mb_conceal_at(c, c->cur.src + c->cur.i, k) * c->cur.g;
		if (c->in_seam) {
			v = (v * c->sc + (double)mb_conceal_at(c, c->nxt.src + c->nxt.i, k) * c->nxt.g * c->ss) * sg;
		}
		out[k] = (float)mb_conceal_limit(c->gain * v + c->offset[k] + c->bend[k], c->peak);
		c->offset[k] *= c->offset_decay;
		c->bend[k] = (c->bend[k] + c->bend_u[k]) * c->bend_decay;
		c->bend_u[k] *= c->bend_decay;
	}

	c->cur.i++;
	if (c->in_seam) {
		c->nxt.i++;
		c->j++;
		mb_conceal_rotate(&c->sc, &c->ss, c->scd, c->ssd);
		if (c->j >= c->h) {
			c->cur = c->nxt;
			c->h_in = c->h;
			c->in_seam = 0;
			if (c->landing == MB_CONCEAL_LAND_NEXT) {
				c->landing = MB_CONCEAL_LAND_LAST;
			} else if (c->landing == MB_CONCEAL_LAND_AFTER) {
				// (planned by mb_conceal_land: cur's next land_frames
				// cross into fin)
				c->cur.len = c->cur.i + c->land_frames;
				c->nxt = c->fin;
				c->h = c->land_frames;
				c->rho = c->fin_rho;
				c->landing = MB_CONCEAL_LAND_NEXT;
			} else {
				mb_conceal_next(c);
			}
		}
	}

	if (c->landing) {
		c->land_left--;
		if (c->land_left == 0) {
			c->active = 0;
			c->landing = MB_CONCEAL_LAND_NONE;
		}
		return;
	}

	if (c->held < c->hold_frames && !c->quiet) {
		c->held++;
	} else {
		c->gain *= c->cur_decay;
	}
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

	// The level before the gap, for the grains' level cap
	double sum = 0;
	for (uint64_t pos = c->t0 - c->grain_min; pos < c->t0; pos++) {
		for (int k = 0; k < ch; k++) {
			double a = mb_conceal_at(c, pos, k);
			sum += a * a;
		}
	}
	c->ref_rms = sqrt(sum / (double)(c->grain_min * ch));
	c->cur.g = c->fixed ? 1.0 : mb_conceal_gain(c, &c->cur);

	// The step and the slope break into the first grain: the step decays
	// over 2 ms; a slope break bigger than the signal's own (twice the RMS
	// second difference of the match window) bends away over 0.25 ms
	for (int k = 0; k < ch; k++) {
		double x1 = mb_conceal_at(c, c->t0 - 1, k);
		double x2 = mb_conceal_at(c, c->t0 - 2, k);
		double h0 = mb_conceal_at(c, c->cur.src, k);
		double h1 = mb_conceal_at(c, c->cur.src - 1, k);
		c->offset[k] = x1 - h1 * c->cur.g;
		double ds = (x1 - x2) - (h0 - h1) * c->cur.g;
		double sq = 0;
		for (size_t jj = 1; jj <= w; jj++) {
			double d = (double)mb_conceal_at(c, c->t0 - jj, k) - 2.0 * (double)mb_conceal_at(c, c->t0 - jj - 1, k) + (double)mb_conceal_at(c, c->t0 - jj - 2, k);
			sq += d * d;
		}
		double excess = fabs(ds) - 2.0 * sqrt(sq / (double)w);
		double b = excess > 0 ? (ds < 0 ? -excess : excess) : 0;
		c->bend[k] = b;
		c->bend_u[k] = b;
	}
	// Equal-power seams of uncorrelated grains can sum over the history's
	// peak; concealment goes at most 1 dB past it (mb_conceal_limit)
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
	c->held = 0;
	c->faded = 0;
	c->active = 1;
	c->landing = MB_CONCEAL_LAND_NONE;
	c->events++;
	mb_conceal_next(c);
	return 1;
}

// The landing's last grain, ending at t0, for a seam of land_frames
// starting at history frame +pos+: up to twice align_search frames longer
// than the seam (plus one, so its last frame is the history's own), where it
// best matches the grain mid-seam.  Sets *rho to the seam's correlation.
static inline struct mb_conceal_grain mb_conceal_last_grain(const struct mb_conceal *c, uint64_t pos, double *rho)
{
	size_t hs = c->land_frames;
	struct mb_conceal_grain g;
	uint64_t to = c->t0 - hs - 1;
	uint64_t lo = c->t0 - c->avail;
	uint64_t span = 2 * (uint64_t)c->align_search;
	uint64_t from = to > lo + span ? to - span : lo;
	size_t w = c->align_window < hs ? c->align_window : hs;
	size_t off = (hs - w) / 2;
	g.src = c->align_search > 0 && !c->fixed ? mb_conceal_best(c, pos + off, from, to, off, w) : to;
	g.len = (size_t)(c->t0 - g.src);
	g.i = 0;
	g.g = 1.0;
	*rho = c->fixed ? 0 : mb_conceal_rho(c, pos, g.src, hs);
	return g;
}

// Plans the landing (real audio is queued): the grains cross, over
// land_frames, into a last grain ending at t0 (mb_conceal_last_grain), from
// cur's next frame, or after a running seam from where nxt will be then.  A
// grain that reaches t0 before a whole seam becomes the last grain itself.
// (land_frames is at most grain_min, so the history holds the last grain.)
static inline void mb_conceal_land(struct mb_conceal *c)
{
	size_t hs = c->land_frames;
	if (c->faded) {
		// (from silence: the level ramp is the fade-in; a faded
		// concealment stopped wherever it was, maybe mid-seam)
		c->faded = 0;
		c->gain = 0;
		c->in_seam = 0;
	}

	if (c->in_seam) {
		uint64_t pos = c->nxt.src + c->h; // nxt as cur after the seam
		if (pos + hs >= c->t0) {
			c->nxt.len = (size_t)(c->t0 - c->nxt.src);
			c->landing = MB_CONCEAL_LAND_NEXT;
			c->land_left = c->nxt.len - c->nxt.i;
			return;
		}
		c->fin = mb_conceal_last_grain(c, pos, &c->fin_rho);
		c->landing = MB_CONCEAL_LAND_AFTER;
		c->land_left = (c->h - c->j) + c->fin.len;
		return;
	}

	uint64_t pos = c->cur.src + c->cur.i;
	if (pos + hs >= c->t0) {
		c->cur.len = (size_t)(c->t0 - c->cur.src);
		c->landing = MB_CONCEAL_LAND_LAST;
		c->land_left = c->cur.len - c->cur.i;
		return;
	}

	c->cur.len = c->cur.i + hs;
	c->nxt = mb_conceal_last_grain(c, pos, &c->rho);
	c->h = hs;
	c->landing = MB_CONCEAL_LAND_NEXT;
	c->land_left = c->nxt.len;
}

/*
 * How many of the +available+ queued frames a pull of +frames+ takes: all
 * it can, except while concealing.  Then the first pull with real audio
 * queued plans the landing (mb_conceal_land), and the frames wait until the
 * pull in which the last grain ends, which takes what fits after it.
 */
static inline size_t mb_conceal_take(struct mb_conceal *c, size_t available, size_t frames)
{
	if (c->mode != MB_CONCEAL_REPEAT || !c->active) {
		return available < frames ? available : frames;
	}
	if (!c->landing) {
		if (available == 0) {
			return 0;
		}
		mb_conceal_land(c);
	}
	if (c->land_left >= frames) {
		return 0;
	}
	size_t room = frames - c->land_left;
	return available < room ? available : room;
}

/*
 * Conceals a device pull: +out+ holds the +count+ real interleaved frames
 * mb_conceal_take took, followed by silence up to +frames+.  Plays the
 * rest of a landing first (moving the real frames after it), pushes the
 * real frames into the history, and conceals the rest of the pull if the
 * ring ran dry.  +quiet+ is true when the writer marked the end of its
 * audio (the gap is intended: no new concealment, and a running one fades
 * quickly).  Returns the number of frames concealed.
 */
static inline size_t mb_conceal_process(struct mb_conceal *c, float *out, size_t frames, size_t count, int quiet)
{
	if (c->mode != MB_CONCEAL_REPEAT) {
		return 0;
	}

	size_t ch = c->ch;
	c->cur_decay = quiet ? c->quiet_decay : c->decay;
	c->quiet = quiet ? 1 : 0;

	if (c->active && !c->landing && count > 0) {
		// (only for a caller that didn't use mb_conceal_take)
		c->active = 0;
	}

	size_t done = 0;
	if (c->active && c->landing) {
		size_t r = c->land_left < frames ? c->land_left : frames;
		if (count > 0) {
			memmove(out + r * ch, out, count * ch * sizeof(float));
		}
		for (; done < r; done++) {
			mb_conceal_frame(c, out + done * ch);
		}
	}
	size_t concealed = done;

	if (count > 0) {
		mb_conceal_push(c, out + done * ch, count);
		done += count;
	}

	if (done < frames && (c->active || (!quiet && mb_conceal_enter(c)))) {
		for (size_t i = done; i < frames; i++) {
			mb_conceal_frame(c, out + i * ch);
		}
		concealed += frames - done;
	}
	c->frames += concealed;
	return concealed;
}

#endif
