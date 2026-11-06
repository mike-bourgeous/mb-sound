/*
 * MB::Sound::FastConvolve::Engine: zero-latency partitioned convolution for
 * GraphNode::Convolver (#convolve).
 *
 * The impulse's first D samples (the head) run in the time domain, one dot
 * product of D taps per sample and path, so the output has no latency
 * (Gardner 1995; Lake DSP's patent, US 5,502,747, has expired).  The rest is
 * cut into levels of overlap-save FFT convolution, each with its own block
 * size Q and a frequency-domain delay line of input spectra (non-uniform
 * partitioning; the default plan, Convolution.plan, is a 128-tap head, then
 * partitions of 128 to 1024, of 1024 to 16384, and of 8192 to the end).
 * Level partition j covers the impulse from (k0 + j) * Q for Q samples and
 * multiplies the input spectrum (k0 + j) blocks back.
 *
 * Uniform levels (k0 = 1): every Q input samples (a block), the last 2Q
 * inputs are transformed (an FFT of N = 2Q points, by Pocketfft in Ruby
 * between calls), stored in the ring, and multiplied; the inverse's last Q
 * samples are the level's output for the next block.  Every partition but
 * the first reads an older spectrum, so #process sums those across the
 * block's samples by the block position, leaving the first partition and
 * the two transforms for the boundary (#fft_input, #spectrum, #finish).
 *
 * The spread level (k0 = 2, the last level of the default plan, a block
 * later than its size requires): its output for block m + 1 needs spectra
 * up to block m - 1 only, so all of its work for one block (the forward FFT
 * of the previous segment, every partition, the inverse FFT) runs during
 * block m as a list of small tasks (#task), done by the block position:
 * each transform is r (8) sub-FFTs of N / r points of the decimated sequence
 * (Pocketfft in Ruby, one per #task call that returns 1) combined by
 * log2(r) radix-2 passes in chunks, so no buffer carries a whole 2Q-point
 * transform.  Its boundary swaps two output tails.
 *
 * Every task runs at a fixed point of the node's own time and computes the
 * same values wherever it runs, so the output is the same at any buffer
 * size, bit for bit.
 *
 * From Ruby (Convolution.run):
 *     room = engine.process(outs, ins, offset, n)   # n <= engine.room
 *     if room == 0                                  # (every D samples)
 *       engine.boundary_levels (a bit mask): each   # fft_input(l, w), spectrum(l, fft(w), w), finish(l, fft(w))
 *     end
 *     while engine.task(sub) == 1                   # the spread level's due work (after every call)
 *       engine.task_result(fft(sub))
 *     end
 *
 * Channels: up to two inputs and two outputs, any number of impulse
 * channels; each path [input, output, impulse] adds input * impulse to the
 * output.  Two real channels share each complex FFT (x0 + i x1 in; out of
 * one transform of the conjugated, Hermitian-extended A0 + i A1).
 *
 * Double precision throughout; inputs are read as float32 and outputs
 * written as float32.  The Ruby mirror (MB::Sound::Convolution::RubyEngine)
 * sums in other orders, so they agree within a tolerance.
 */

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

#define CONV_MAX_CHANNELS 2
#define CONV_MAX_LEVELS 8

// Spread-level task kinds.
enum conv_task_kind {
	TASK_SUB_F = 0, // a forward sub-FFT (Ruby): gather sequence a of the input segment
	TASK_COMBINE_F, // a radix-2 pass (stage a) over butterflies b...c of the forward transform
	TASK_UNPACK,    // the forward transform into the ring
	TASK_MAC,       // partition a of every path into the sums
	TASK_PACK,      // the sums into the packed output spectrum
	TASK_SUB_I,     // an inverse sub-FFT (Ruby)
	TASK_COMBINE_I, // a radix-2 pass of the inverse transform
	TASK_STORE,     // the inverse transform into the next block's tails
};

struct conv_task {
	int kind;
	long a, b, c;
	long weight;
};

struct conv_level {
	long Q, N, B; // block size, FFT size (2Q), bins (Q + 1)
	long k0;      // the first partition's distance in blocks (1 uniform, 2 spread)
	long K;       // partitions
	long R;       // ring slots (K)
	int spread;

	double *hr, *hi;   // nir * K * B: partition spectra (scaled by 1 / N)
	double *seg;       // nin * N: the last block and the current one
	double *xr, *xi;   // nin * R * B: input spectra
	double *ar, *ai;   // nout * B: sums for the next block
	double *tail;      // nout * Q: this block's output
	long pos;          // samples of this block done
	long block;        // blocks completed
	long done;         // uniform: partitions 1... summed for the next block

	// spread levels
	double *tail_next; // nout * Q: the next block's output
	double *pending;   // nin * N: the previous segment, transformed during this block
	double *fa, *fb;   // 2 * N each: transform buffers (complex interleaved)
	double *wtab;      // 2 * (N / 2): exp(-2 pi i j / N)
	long r, M;         // sub-FFTs and their size
	long stages;       // log2(r)
	struct conv_task *tasks;
	long ntasks, tp, total_weight, weight_done;
	int sub_waiting;   // a sub-FFT's input is out, its result not back yet
};

struct conv_engine {
	int ready;
	long D;     // head taps
	long nin, nout, nir, npaths;
	long length;
	long *path_in, *path_out, *path_ir;
	double *head; // nir * D, reversed
	double *hist; // nin * 2D: the head's input history
	long hpos;
	long nlevels;
	struct conv_level lv[CONV_MAX_LEVELS];
	long zero_run;
	long quiet_after;
};

static void level_free(struct conv_level *l)
{
	free(l->hr);
	free(l->hi);
	free(l->seg);
	free(l->xr);
	free(l->xi);
	free(l->ar);
	free(l->ai);
	free(l->tail);
	free(l->tail_next);
	free(l->pending);
	free(l->fa);
	free(l->fb);
	free(l->wtab);
	free(l->tasks);
}

static void conv_free(void *p)
{
	struct conv_engine *e = p;
	if (e == NULL) {
		return;
	}
	free(e->path_in);
	free(e->path_out);
	free(e->path_ir);
	free(e->head);
	free(e->hist);
	for (long i = 0; i < CONV_MAX_LEVELS; i++) {
		level_free(&e->lv[i]);
	}
	free(e);
}

static size_t conv_memsize(const void *p)
{
	const struct conv_engine *e = p;
	if (e == NULL) {
		return 0;
	}
	size_t total = sizeof(*e);
	if (e->ready) {
		total += 3 * e->npaths * sizeof(long) + (e->nir * e->D + e->nin * 2 * e->D) * sizeof(double);
		for (long i = 0; i < e->nlevels; i++) {
			const struct conv_level *l = &e->lv[i];
			total += (2 * e->nir * l->K * l->B + e->nin * l->N + 2 * e->nin * l->R * l->B + 2 * e->nout * l->B + e->nout * l->Q) * sizeof(double);
			if (l->spread) {
				total += (e->nout * l->Q + e->nin * l->N + 4 * l->N + l->N) * sizeof(double) + l->ntasks * sizeof(struct conv_task);
			}
		}
	}
	return total;
}

static const rb_data_type_t conv_type = {
	.wrap_struct_name = "MB::Sound::FastConvolve::Engine",
	.function = {
		.dmark = NULL,
		.dfree = conv_free,
		.dsize = conv_memsize,
	},
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE conv_alloc(VALUE klass)
{
	struct conv_engine *e = calloc(1, sizeof(struct conv_engine));
	if (e == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate a convolution engine");
	}
	return TypedData_Wrap_Struct(klass, &conv_type, e);
}

static struct conv_engine *conv_get(VALUE self)
{
	struct conv_engine *e;
	TypedData_Get_Struct(self, struct conv_engine, &conv_type, e);
	if (!e->ready) {
		rb_raise(rb_eRuntimeError, "Convolution engine not initialized");
	}
	return e;
}

static void *conv_calloc(size_t count, size_t size)
{
	void *p = calloc(count > 0 ? count : 1, size);
	if (p == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate convolution buffers");
	}
	return p;
}

// Checks that +v+ is a contiguous NArray of class +cls+ with +count+
// elements; returns its data.
static const void *conv_array(VALUE v, VALUE cls, size_t count, const char *name)
{
	if (CLASS_OF(v) != cls || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "%s must be a contiguous %s", name, cls == numo_cDComplex ? "DComplex" : "DFloat");
	}
	narray_t *na;
	GetNArray(v, na);
	if (NA_SIZE(na) != count) {
		rb_raise(rb_eArgError, "%s must have %zu values (got %zu)", name, count, (size_t)NA_SIZE(na));
	}
	return nary_get_pointer_for_read(v) + nary_get_offset(v);
}

// A writable contiguous DComplex of +count+ values.
static double *conv_complex_out(VALUE v, size_t count, const char *name)
{
	conv_array(v, numo_cDComplex, count, name);
	rb_check_frozen(v);
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

// The spread level's tasks for one block, in order (see the file comment).
static void level_tasks(struct conv_level *l, long npaths)
{
	long half = l->N / 2;
	long chunk = 2048;
	long per_pass = (half + chunk - 1) / chunk;
	long n = 2 * (l->r + l->stages * per_pass) + 1 + l->K + 1 + 1;
	l->tasks = conv_calloc(n, sizeof(struct conv_task));
	long t = 0;
	long sub_w = 4 * l->M; // (a sub-FFT costs about four butterflies per point)
	for (int phase = 0; phase < 2; phase++) {
		for (long i = 0; i < l->r; i++) {
			l->tasks[t++] = (struct conv_task){ phase ? TASK_SUB_I : TASK_SUB_F, i, 0, 0, sub_w };
		}
		for (long s = 0; s < l->stages; s++) {
			for (long b = 0; b < half; b += chunk) {
				long c = b + chunk < half ? b + chunk : half;
				l->tasks[t++] = (struct conv_task){ phase ? TASK_COMBINE_I : TASK_COMBINE_F, s, b, c, c - b };
			}
		}
		if (phase == 0) {
			l->tasks[t++] = (struct conv_task){ TASK_UNPACK, 0, 0, 0, l->B };
			for (long j = 0; j < l->K; j++) {
				l->tasks[t++] = (struct conv_task){ TASK_MAC, j, 0, 0, l->B * npaths };
			}
			l->tasks[t++] = (struct conv_task){ TASK_PACK, 0, 0, 0, l->N / 2 };
		} else {
			l->tasks[t++] = (struct conv_task){ TASK_STORE, 0, 0, 0, l->Q / 2 };
		}
	}
	l->ntasks = t;
	l->total_weight = 0;
	for (long i = 0; i < t; i++) {
		l->total_weight += l->tasks[i].weight;
	}
}

/*
 * Engine.new(head_taps, inputs, outputs, paths, head, levels, length)
 *
 * +paths+: [input, output, impulse] triples.  +head+: a DFloat of impulses
 * * head_taps values (each impulse's first head_taps samples, reversed).
 * +levels+: an Array of [block, k0, spectra] (spectra a DComplex of impulses
 * * partitions * (block + 1) values: the 2 * block-point FFTs of each
 * partition zero-padded after it, scaled by 1 / (2 * block)); k0 1 for a
 * uniform level, 2 for the spread level (the last, block a power of two of
 * at least 512).  +length+: the impulse's length in samples.
 */
static VALUE conv_initialize(VALUE self, VALUE head_taps, VALUE inputs, VALUE outputs, VALUE paths, VALUE head, VALUE levels, VALUE length)
{
	struct conv_engine *e;
	TypedData_Get_Struct(self, struct conv_engine, &conv_type, e);
	if (e->ready) {
		rb_raise(rb_eRuntimeError, "Convolution engine already initialized");
	}

	long D = NUM2LONG(head_taps);
	if (D < 1 || D > (1L << 20)) {
		rb_raise(rb_eArgError, "The head must be 1 to 2**20 taps");
	}
	long nin = NUM2LONG(inputs);
	long nout = NUM2LONG(outputs);
	if (nin < 1 || nin > CONV_MAX_CHANNELS || nout < 1 || nout > CONV_MAX_CHANNELS) {
		rb_raise(rb_eArgError, "A convolution engine takes 1 or 2 inputs and outputs");
	}
	Check_Type(paths, T_ARRAY);
	long npaths = RARRAY_LEN(paths);
	if (npaths < 1 || npaths > 64) {
		rb_raise(rb_eArgError, "A convolution engine takes 1 to 64 paths");
	}
	if (CLASS_OF(head) != numo_cDFloat) {
		rb_raise(rb_eArgError, "The head must be a DFloat");
	}
	narray_t *hna;
	GetNArray(head, hna);
	if (NA_SIZE(hna) == 0 || NA_SIZE(hna) % D != 0) {
		rb_raise(rb_eArgError, "The head must hold head_taps values per impulse");
	}
	long nir = NA_SIZE(hna) / D;
	Check_Type(levels, T_ARRAY);
	long nlevels = RARRAY_LEN(levels);
	if (nlevels > CONV_MAX_LEVELS) {
		rb_raise(rb_eArgError, "At most %d levels", CONV_MAX_LEVELS);
	}
	long len = NUM2LONG(length);
	if (len < 0) {
		rb_raise(rb_eArgError, "The length must not be negative");
	}

	e->path_in = conv_calloc(npaths, sizeof(long));
	e->path_out = conv_calloc(npaths, sizeof(long));
	e->path_ir = conv_calloc(npaths, sizeof(long));
	for (long p = 0; p < npaths; p++) {
		VALUE t = rb_ary_entry(paths, p);
		Check_Type(t, T_ARRAY);
		if (RARRAY_LEN(t) != 3) {
			rb_raise(rb_eArgError, "Each path is [input, output, impulse]");
		}
		e->path_in[p] = NUM2LONG(rb_ary_entry(t, 0));
		e->path_out[p] = NUM2LONG(rb_ary_entry(t, 1));
		e->path_ir[p] = NUM2LONG(rb_ary_entry(t, 2));
		if (e->path_in[p] < 0 || e->path_in[p] >= nin || e->path_out[p] < 0 || e->path_out[p] >= nout || e->path_ir[p] < 0 || e->path_ir[p] >= nir) {
			rb_raise(rb_eArgError, "Path %ld [%ld, %ld, %ld] is out of range", p, e->path_in[p], e->path_out[p], e->path_ir[p]);
		}
	}

	e->D = D;
	e->nin = nin;
	e->nout = nout;
	e->nir = nir;
	e->npaths = npaths;
	e->length = len;

	const double *hp = conv_array(head, numo_cDFloat, nir * D, "The head");
	e->head = conv_calloc(nir * D, sizeof(double));
	memcpy(e->head, hp, nir * D * sizeof(double));
	e->hist = conv_calloc(nin * 2 * D, sizeof(double));

	long qmax = D;
	for (long i = 0; i < nlevels; i++) {
		VALUE spec = rb_ary_entry(levels, i);
		Check_Type(spec, T_ARRAY);
		if (RARRAY_LEN(spec) != 3) {
			rb_raise(rb_eArgError, "Each level is [block, k0, spectra]");
		}
		struct conv_level *l = &e->lv[i];
		long Q = NUM2LONG(rb_ary_entry(spec, 0));
		long k0 = NUM2LONG(rb_ary_entry(spec, 1));
		VALUE sp = rb_ary_entry(spec, 2);
		if (Q < 1 || Q > (1L << 20) || Q % D != 0) {
			rb_raise(rb_eArgError, "Level %ld's block must be a multiple of the head taps", i);
		}
		if (k0 != 1 && k0 != 2) {
			rb_raise(rb_eArgError, "Level %ld's k0 must be 1 or 2", i);
		}
		if (k0 == 2 && (i != nlevels - 1 || Q < 512 || (Q & (Q - 1)) != 0)) {
			rb_raise(rb_eArgError, "Only the last level may be spread (k0 2), with a power-of-two block of at least 512");
		}
		if (CLASS_OF(sp) != numo_cDComplex) {
			rb_raise(rb_eArgError, "Level %ld's spectra must be a DComplex", i);
		}
		narray_t *sna;
		GetNArray(sp, sna);
		long per = nir * (Q + 1);
		if (NA_SIZE(sna) == 0 || NA_SIZE(sna) % per != 0) {
			rb_raise(rb_eArgError, "Level %ld's spectra must hold (block + 1) bins per partition and impulse", i);
		}
		l->Q = Q;
		l->N = 2 * Q;
		l->B = Q + 1;
		l->k0 = k0;
		l->K = NA_SIZE(sna) / per;
		l->R = l->K;
		l->spread = k0 == 2;
		long spec_n = nir * l->K * l->B;
		const double *s = conv_array(sp, numo_cDComplex, spec_n, "The spectra");
		l->hr = conv_calloc(spec_n, sizeof(double));
		l->hi = conv_calloc(spec_n, sizeof(double));
		for (long j = 0; j < spec_n; j++) {
			l->hr[j] = s[2 * j];
			l->hi[j] = s[2 * j + 1];
		}
		l->seg = conv_calloc(nin * l->N, sizeof(double));
		l->xr = conv_calloc(nin * l->R * l->B, sizeof(double));
		l->xi = conv_calloc(nin * l->R * l->B, sizeof(double));
		l->ar = conv_calloc(nout * l->B, sizeof(double));
		l->ai = conv_calloc(nout * l->B, sizeof(double));
		l->tail = conv_calloc(nout * Q, sizeof(double));
		if (l->spread) {
			l->tail_next = conv_calloc(nout * Q, sizeof(double));
			l->pending = conv_calloc(nin * l->N, sizeof(double));
			l->fa = conv_calloc(2 * l->N, sizeof(double));
			l->fb = conv_calloc(2 * l->N, sizeof(double));
			l->wtab = conv_calloc(l->N, sizeof(double));
			for (long j = 0; j < l->N / 2; j++) {
				double a = -2.0 * M_PI * (double)j / (double)l->N;
				l->wtab[2 * j] = cos(a);
				l->wtab[2 * j + 1] = sin(a);
			}
			// sub-FFTs of 2048 points where the block allows (Pocketfft's
			// 2048 took 21.6 us on the Mac and its 1024 16.4: fewer, larger
			// calls cost less per point)
			l->r = 8;
			while (l->r > 1 && l->N / l->r < 1024) {
				l->r /= 2;
			}
			l->M = l->N / l->r;
			l->stages = 0;
			for (long r = l->r; r > 1; r /= 2) {
				l->stages++;
			}
			level_tasks(l, npaths);
		}
		if ((k0 + 1) * Q > qmax) {
			qmax = (k0 + 1) * Q;
		}
		RB_GC_GUARD(sp);
	}
	e->nlevels = nlevels;
	e->quiet_after = len + 2 * qmax + D;

	RB_GC_GUARD(head);
	e->ready = 1;
	return self;
}

// The dot product of +n+ values, in four running sums.
static inline double conv_dot(const double *a, const double *b, long n)
{
	double s0 = 0, s1 = 0, s2 = 0, s3 = 0;
	long j = 0;
	for (; j + 4 <= n; j += 4) {
		s0 += a[j] * b[j];
		s1 += a[j + 1] * b[j + 1];
		s2 += a[j + 2] * b[j + 2];
		s3 += a[j + 3] * b[j + 3];
	}
	for (; j < n; j++) {
		s0 += a[j] * b[j];
	}
	return (s0 + s1) + (s2 + s3);
}

static inline long conv_mod(long j, long m)
{
	long s = j % m;
	return s < 0 ? s + m : s;
}

// Adds partition +j+ of every path, multiplying the input spectrum of block
// +spectrum_block+, into the level's sums.
static void level_mac(const struct conv_engine *e, struct conv_level *l, long j, long spectrum_block)
{
	long B = l->B;
	long slot = conv_mod(spectrum_block, l->R);
	for (long p = 0; p < e->npaths; p++) {
		const double *xr = l->xr + (e->path_in[p] * l->R + slot) * B;
		const double *xi = l->xi + (e->path_in[p] * l->R + slot) * B;
		const double *hr = l->hr + (e->path_ir[p] * l->K + j) * B;
		const double *hi = l->hi + (e->path_ir[p] * l->K + j) * B;
		double *ar = l->ar + e->path_out[p] * B;
		double *ai = l->ai + e->path_out[p] * B;
		for (long b = 0; b < B; b++) {
			ar[b] += xr[b] * hr[b] - xi[b] * hi[b];
			ai[b] += xr[b] * hi[b] + xi[b] * hr[b];
		}
	}
}

// Uniform levels: partitions 1... summed up to +target+ of them (partition
// j reads the spectrum of block (block + 1 - (1 + j))).
static void level_catch_up(const struct conv_engine *e, struct conv_level *l, long target)
{
	while (l->done < target) {
		long j = l->done + 1;
		level_mac(e, l, j, l->block - j);
		l->done++;
	}
}

// Stores the spectra of the packed transform +z+ (N complex values of
// input 0 + i input 1) in ring slot +slot+.
static void level_unpack(const struct conv_engine *e, struct conv_level *l, const double *z, long slot)
{
	long N = l->N, B = l->B;
	double *x0r = l->xr + slot * B;
	double *x0i = l->xi + slot * B;
	if (e->nin == 1) {
		for (long b = 0; b < B; b++) {
			x0r[b] = z[2 * b];
			x0i[b] = z[2 * b + 1];
		}
	} else {
		double *x1r = l->xr + (l->R + slot) * B;
		double *x1i = l->xi + (l->R + slot) * B;
		for (long b = 0; b < B; b++) {
			long q = (N - b) % N;
			double kr = z[2 * b], ki = z[2 * b + 1];
			double nr = z[2 * q], ni = z[2 * q + 1];
			// X0 = (Z[b] + conj(Z[N - b])) / 2, X1 = (Z[b] - conj(Z[N - b])) / 2i
			x0r[b] = 0.5 * (kr + nr);
			x0i[b] = 0.5 * (ki - ni);
			x1r[b] = 0.5 * (ki + ni);
			x1i[b] = -0.5 * (kr - nr);
		}
	}
}

// Writes the conjugated, Hermitian-extended spectrum sums 0 + i sums 1
// into +w+ (N complex values), whose FFT gives the outputs.
static void level_pack(const struct conv_engine *e, const struct conv_level *l, double *w)
{
	long N = l->N, B = l->B;
	const double *a0r = l->ar, *a0i = l->ai;
	const double *a1r = e->nout > 1 ? l->ar + B : NULL;
	const double *a1i = e->nout > 1 ? l->ai + B : NULL;
	for (long b = 0; b < N; b++) {
		long q = b <= l->Q ? b : N - b;
		double r0 = a0r[q], i0 = a0i[q];
		double r1 = a1r ? a1r[q] : 0.0, i1 = a1i ? a1i[q] : 0.0;
		if (b <= l->Q) {
			w[2 * b] = r0 - i1;
			w[2 * b + 1] = -(i0 + r1);
		} else {
			w[2 * b] = r0 + i1;
			w[2 * b + 1] = i0 - r1;
		}
	}
}

// Reads the outputs from +y+ (the FFT of level_pack's array: output 0 in
// the real parts, output 1 in the negated imaginary parts, last half) into
// +tail+.
static void level_store(const struct conv_engine *e, const struct conv_level *l, const double *y, double *tail)
{
	long Q = l->Q;
	for (long t = 0; t < Q; t++) {
		tail[t] = y[2 * (Q + t)];
	}
	if (e->nout > 1) {
		for (long t = 0; t < Q; t++) {
			tail[Q + t] = -y[2 * (Q + t) + 1];
		}
	}
}

static void level_shift(const struct conv_engine *e, struct conv_level *l)
{
	for (long c = 0; c < e->nin; c++) {
		memcpy(l->seg + c * l->N, l->seg + c * l->N + l->Q, l->Q * sizeof(double));
	}
	l->pos = 0;
	l->done = 0;
	l->block++;
}

static const float *conv_input(VALUE v, long need, const char *name)
{
	if (NIL_P(v)) {
		return NULL;
	}
	if (CLASS_OF(v) != numo_cSFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "%s must be nil or a contiguous 1D SFloat", name);
	}
	if ((long)RNARRAY_SHAPE(v)[0] < need) {
		rb_raise(rb_eArgError, "%s is too short", name);
	}
	return (const float *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

static long conv_room_of(const struct conv_engine *e)
{
	long room = e->D - e->hpos;
	for (long i = 0; i < e->nlevels; i++) {
		long r = e->lv[i].Q - e->lv[i].pos;
		if (r < room) {
			room = r;
		}
	}
	return room;
}

/*
 * process(outs, ins, offset, n): convolves samples offset...offset + n of
 * +ins+ (an Array of one SFloat or nil, for silence, per input) into the
 * same samples of +outs+ (one SFloat per output).  n may not pass #room.
 * Returns the room left: 0 when a uniform level's block ends
 * (#boundary_levels) or the spread level's (#task finishes it).
 */
static VALUE conv_process(VALUE self, VALUE outs, VALUE ins, VALUE offset_v, VALUE n_v)
{
	struct conv_engine *e = conv_get(self);
	long offset = NUM2LONG(offset_v);
	long n = NUM2LONG(n_v);
	long room = conv_room_of(e);
	if (offset < 0 || n < 0 || n > room) {
		rb_raise(rb_eArgError, "Process %ld samples at %ld with %ld left in the block", n, offset, room);
	}
	Check_Type(outs, T_ARRAY);
	Check_Type(ins, T_ARRAY);
	if (RARRAY_LEN(outs) != e->nout || RARRAY_LEN(ins) != e->nin) {
		rb_raise(rb_eArgError, "Expected %ld outputs and %ld inputs", e->nout, e->nin);
	}

	const float *in[CONV_MAX_CHANNELS] = { NULL, NULL };
	float *out[CONV_MAX_CHANNELS] = { NULL, NULL };
	for (long c = 0; c < e->nin; c++) {
		in[c] = conv_input(rb_ary_entry(ins, c), offset + n, "An input");
	}
	for (long c = 0; c < e->nout; c++) {
		VALUE o = rb_ary_entry(outs, c);
		if (NIL_P(o) || conv_input(o, offset + n, "An output") == NULL) {
			rb_raise(rb_eArgError, "Every output must be an SFloat");
		}
		rb_check_frozen(o);
		out[c] = mb_sfloat_ptr(o);
	}

	long D = e->D;
	for (long j = 0; j < n; j++) {
		long hp = e->hpos;
		int nonzero = 0;
		for (long c = 0; c < e->nin; c++) {
			double x = in[c] ? (double)in[c][offset + j] : 0.0;
			e->hist[c * 2 * D + D + hp] = x;
			for (long i = 0; i < e->nlevels; i++) {
				struct conv_level *l = &e->lv[i];
				l->seg[c * l->N + l->Q + l->pos] = x;
			}
			nonzero |= x != 0.0;
		}

		double y[CONV_MAX_CHANNELS] = { 0.0, 0.0 };
		for (long p = 0; p < e->npaths; p++) {
			y[e->path_out[p]] += conv_dot(e->head + e->path_ir[p] * D, e->hist + e->path_in[p] * 2 * D + hp + 1, D);
		}
		for (long i = 0; i < e->nlevels; i++) {
			struct conv_level *l = &e->lv[i];
			for (long c = 0; c < e->nout; c++) {
				y[c] += l->tail[c * l->Q + l->pos];
			}
			l->pos++;
		}
		for (long c = 0; c < e->nout; c++) {
			out[c][offset + j] = (float)y[c];
		}

		e->zero_run = nonzero ? 0 : (e->zero_run < LONG_MAX / 2 ? e->zero_run + 1 : e->zero_run);
		e->hpos = hp + 1;
		if (e->hpos == D) {
			for (long c = 0; c < e->nin; c++) {
				memcpy(e->hist + c * 2 * D, e->hist + c * 2 * D + D, D * sizeof(double));
			}
			e->hpos = 0;
		}
	}

	for (long i = 0; i < e->nlevels; i++) {
		struct conv_level *l = &e->lv[i];
		if (!l->spread && l->K > 1) {
			level_catch_up(e, l, (l->K - 1) * l->pos / l->Q);
		}
	}

	RB_GC_GUARD(outs);
	RB_GC_GUARD(ins);
	return LONG2NUM(conv_room_of(e));
}

// room: samples before #process must stop.
static VALUE conv_room(VALUE self)
{
	return LONG2NUM(conv_room_of(conv_get(self)));
}

// boundary_levels: the uniform levels whose block just ended, as a bit
// mask (bit i for level i; each needs fft_input, spectrum, and finish).
static VALUE conv_boundary_levels(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	long mask = 0;
	for (long i = 0; i < e->nlevels; i++) {
		if (!e->lv[i].spread && e->lv[i].pos == e->lv[i].Q) {
			mask |= 1L << i;
		}
	}
	return LONG2NUM(mask);
}

static struct conv_level *conv_uniform_at_boundary(struct conv_engine *e, VALUE level)
{
	long i = NUM2LONG(level);
	if (i < 0 || i >= e->nlevels || e->lv[i].spread || e->lv[i].pos != e->lv[i].Q) {
		rb_raise(rb_eRuntimeError, "Level %ld is not a uniform level at its block boundary", i);
	}
	return &e->lv[i];
}

/*
 * fft_input(level, work): fills +work+ (a DComplex of 2 * block values) with
 * the level's last two blocks of input, input 0 + i input 1.
 */
static VALUE conv_fft_input(VALUE self, VALUE level, VALUE work)
{
	struct conv_engine *e = conv_get(self);
	struct conv_level *l = conv_uniform_at_boundary(e, level);
	double *w = conv_complex_out(work, l->N, "The work array");
	const double *s0 = l->seg;
	const double *s1 = e->nin > 1 ? l->seg + l->N : NULL;
	for (long t = 0; t < l->N; t++) {
		w[2 * t] = s0[t];
		w[2 * t + 1] = s1 ? s1[t] : 0.0;
	}
	return work;
}

/*
 * spectrum(level, z, work): stores the inputs' spectra from +z+ (the FFT of
 * #fft_input's array) in the ring, adds partition 0 (and any not summed
 * yet), and fills +work+ with the packed output spectrum (see #finish).
 */
static VALUE conv_spectrum(VALUE self, VALUE level, VALUE z, VALUE work)
{
	struct conv_engine *e = conv_get(self);
	struct conv_level *l = conv_uniform_at_boundary(e, level);
	const double *zp = conv_array(z, numo_cDComplex, l->N, "The spectrum");
	double *w = conv_complex_out(work, l->N, "The work array");

	level_catch_up(e, l, l->K - 1);
	level_unpack(e, l, zp, conv_mod(l->block, l->R));
	level_mac(e, l, 0, l->block);
	level_pack(e, l, w);

	RB_GC_GUARD(z);
	return work;
}

/*
 * finish(level, y): the level's output for its next block from +y+ (the FFT
 * of #spectrum's array), and the next block starts.
 */
static VALUE conv_finish(VALUE self, VALUE level, VALUE y)
{
	struct conv_engine *e = conv_get(self);
	struct conv_level *l = conv_uniform_at_boundary(e, level);
	const double *yp = conv_array(y, numo_cDComplex, l->N, "The output transform");
	level_store(e, l, yp, l->tail);
	memset(l->ar, 0, e->nout * l->B * sizeof(double));
	memset(l->ai, 0, e->nout * l->B * sizeof(double));
	level_shift(e, l);
	RB_GC_GUARD(y);
	return self;
}

// One radix-2 pass (stage s) over butterflies b...c: combines the sequence
// pairs in +src+ into +dst+ (see the file comment).
static void spread_combine(const struct conv_level *l, long s, long b0, long b1)
{
	const double *src = (s % 2 == 0) ? l->fa : l->fb;
	double *dst = (s % 2 == 0) ? l->fb : l->fa;
	long m = l->M << s;          // sequence size before the pass
	long rc = l->N / m;          // sequences before the pass
	long step = l->N / (2 * m);  // twiddle stride
	// (butterfly b is pair i = b / m at bin k = b % m; one division per
	// chunk, not per butterfly)
	long i = b0 / m, k = b0 % m;
	for (long b = b0; b < b1; b++) {
		const double *A = src + 2 * (i * m + k);
		const double *Bv = src + 2 * ((i + rc / 2) * m + k);
		const double *w = l->wtab + 2 * (k * step);
		double tr = w[0] * Bv[0] - w[1] * Bv[1];
		double ti = w[0] * Bv[1] + w[1] * Bv[0];
		double *o = dst + 2 * (i * 2 * m + k);
		o[0] = A[0] + tr;
		o[1] = A[1] + ti;
		o[2 * m] = A[0] - tr;
		o[2 * m + 1] = A[1] - ti;
		if (++k == m) {
			k = 0;
			i++;
		}
	}
}

// The finished transform's buffer (after every pass).
static const double *spread_result(const struct conv_level *l)
{
	return (l->stages % 2 == 0) ? l->fa : l->fb;
}

static struct conv_level *conv_spread_level(struct conv_engine *e)
{
	if (e->nlevels == 0 || !e->lv[e->nlevels - 1].spread) {
		return NULL;
	}
	return &e->lv[e->nlevels - 1];
}

/*
 * task(sub): runs the spread level's work due by now (its block position),
 * returning 1 when a sub-FFT's input is in +sub+ (a DComplex of the level's
 * sub-FFT size; #task_result takes its FFT) and 0 when nothing more is due.
 * At the end of the level's block, finishes every task and starts the next
 * block.  Returns 0 without a spread level.
 */
static VALUE conv_task(VALUE self, VALUE sub)
{
	struct conv_engine *e = conv_get(self);
	struct conv_level *l = conv_spread_level(e);
	if (l == NULL) {
		return INT2FIX(0);
	}
	if (l->sub_waiting) {
		rb_raise(rb_eRuntimeError, "A sub-FFT result is due first (task_result)");
	}
	double target = (double)l->total_weight * (double)l->pos / (double)l->Q;
	while (l->tp < l->ntasks && (double)l->weight_done < target) {
		struct conv_task *t = &l->tasks[l->tp];
		switch (t->kind) {
		case TASK_SUB_F:
		case TASK_SUB_I: {
			double *w = conv_complex_out(sub, l->M, "The sub-FFT array");
			if (t->kind == TASK_SUB_F) {
				const double *p0 = l->pending;
				const double *p1 = e->nin > 1 ? l->pending + l->N : NULL;
				for (long n = 0; n < l->M; n++) {
					long src = t->a + n * l->r;
					w[2 * n] = p0[src];
					w[2 * n + 1] = p1 ? p1[src] : 0.0;
				}
			} else {
				const double *g = l->fb; // (the packed output spectrum, see TASK_PACK)
				for (long n = 0; n < l->M; n++) {
					long src = t->a + n * l->r;
					w[2 * n] = g[2 * src];
					w[2 * n + 1] = g[2 * src + 1];
				}
			}
			l->sub_waiting = 1;
			return INT2FIX(1);
		}
		case TASK_COMBINE_F:
		case TASK_COMBINE_I:
			spread_combine(l, t->a, t->b, t->c);
			break;
		case TASK_UNPACK:
			level_unpack(e, l, spread_result(l), conv_mod(l->block - 1, l->R));
			break;
		case TASK_MAC:
			level_mac(e, l, t->a, l->block - 1 - t->a);
			break;
		case TASK_PACK:
			level_pack(e, l, l->fb);
			memset(l->ar, 0, e->nout * l->B * sizeof(double));
			memset(l->ai, 0, e->nout * l->B * sizeof(double));
			break;
		case TASK_STORE:
			level_store(e, l, spread_result(l), l->tail_next);
			break;
		default:
			rb_raise(rb_eRuntimeError, "Unknown task %d", t->kind);
		}
		l->weight_done += t->weight;
		l->tp++;
	}

	if (l->pos == l->Q) {
		if (l->tp < l->ntasks) {
			rb_raise(rb_eRuntimeError, "The spread level's tasks didn't finish by its block boundary");
		}
		double *t = l->tail;
		l->tail = l->tail_next;
		l->tail_next = t;
		memcpy(l->pending, l->seg, e->nin * l->N * sizeof(double));
		level_shift(e, l);
		l->tp = 0;
		l->weight_done = 0;
	}
	return INT2FIX(0);
}

// task_result(z): the FFT of the sub-FFT input #task returned; stored as
// sequence a's transform.
static VALUE conv_task_result(VALUE self, VALUE z)
{
	struct conv_engine *e = conv_get(self);
	struct conv_level *l = conv_spread_level(e);
	if (l == NULL || !l->sub_waiting) {
		rb_raise(rb_eRuntimeError, "No sub-FFT is waiting for its result");
	}
	struct conv_task *t = &l->tasks[l->tp];
	const double *zp = conv_array(z, numo_cDComplex, l->M, "The sub-FFT result");
	memcpy(l->fa + 2 * t->a * l->M, zp, 2 * l->M * sizeof(double));
	l->sub_waiting = 0;
	l->weight_done += t->weight;
	l->tp++;
	RB_GC_GUARD(z);
	return self;
}

// sub_size: the spread level's sub-FFT size (0 without one).
static VALUE conv_sub_size(VALUE self)
{
	struct conv_level *l = conv_spread_level(conv_get(self));
	return LONG2NUM(l ? l->M : 0);
}

// quiet?: true when the inputs have been silent long enough that every
// output sample from here is zero until they sound again.
static VALUE conv_quiet(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	return e->zero_run >= e->quiet_after ? Qtrue : Qfalse;
}

// reset: silence (the impulse stays).
static VALUE conv_reset(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	memset(e->hist, 0, e->nin * 2 * e->D * sizeof(double));
	e->hpos = 0;
	for (long i = 0; i < e->nlevels; i++) {
		struct conv_level *l = &e->lv[i];
		memset(l->seg, 0, e->nin * l->N * sizeof(double));
		memset(l->xr, 0, e->nin * l->R * l->B * sizeof(double));
		memset(l->xi, 0, e->nin * l->R * l->B * sizeof(double));
		memset(l->ar, 0, e->nout * l->B * sizeof(double));
		memset(l->ai, 0, e->nout * l->B * sizeof(double));
		memset(l->tail, 0, e->nout * l->Q * sizeof(double));
		if (l->spread) {
			memset(l->tail_next, 0, e->nout * l->Q * sizeof(double));
			memset(l->pending, 0, e->nin * l->N * sizeof(double));
			l->tp = 0;
			l->weight_done = 0;
			l->sub_waiting = 0;
		}
		l->pos = 0;
		l->block = 0;
		l->done = 0;
	}
	e->zero_run = 0;
	return self;
}

#define CONV_SWAP(type, a, b) do { type t_ = (a); (a) = (b); (b) = t_; } while (0)

// swap_state(other): exchanges the running state with +other+, an engine of
// the same shape (carry adoption).
static VALUE conv_swap_state(VALUE self, VALUE other)
{
	struct conv_engine *a = conv_get(self);
	if (!rb_typeddata_is_kind_of(other, &conv_type)) {
		rb_raise(rb_eTypeError, "Can only swap state with another engine");
	}
	struct conv_engine *b = conv_get(other);
	int same = a->D == b->D && a->nin == b->nin && a->nout == b->nout && a->nlevels == b->nlevels;
	for (long i = 0; same && i < a->nlevels; i++) {
		same = a->lv[i].Q == b->lv[i].Q && a->lv[i].K == b->lv[i].K && a->lv[i].k0 == b->lv[i].k0;
	}
	if (!same) {
		rb_raise(rb_eArgError, "Engines of different shapes can't swap state");
	}
	if ((conv_spread_level(a) && conv_spread_level(a)->sub_waiting) || (conv_spread_level(b) && conv_spread_level(b)->sub_waiting)) {
		rb_raise(rb_eRuntimeError, "Can't swap state while a sub-FFT is out");
	}
	CONV_SWAP(double *, a->hist, b->hist);
	CONV_SWAP(long, a->hpos, b->hpos);
	CONV_SWAP(long, a->zero_run, b->zero_run);
	for (long i = 0; i < a->nlevels; i++) {
		struct conv_level *x = &a->lv[i], *y = &b->lv[i];
		CONV_SWAP(double *, x->seg, y->seg);
		CONV_SWAP(double *, x->xr, y->xr);
		CONV_SWAP(double *, x->xi, y->xi);
		CONV_SWAP(double *, x->ar, y->ar);
		CONV_SWAP(double *, x->ai, y->ai);
		CONV_SWAP(double *, x->tail, y->tail);
		CONV_SWAP(double *, x->tail_next, y->tail_next);
		CONV_SWAP(double *, x->pending, y->pending);
		CONV_SWAP(double *, x->fa, y->fa);
		CONV_SWAP(double *, x->fb, y->fb);
		CONV_SWAP(long, x->pos, y->pos);
		CONV_SWAP(long, x->block, y->block);
		CONV_SWAP(long, x->done, y->done);
		CONV_SWAP(long, x->tp, y->tp);
		CONV_SWAP(long, x->weight_done, y->weight_done);
	}
	return self;
}

// shape: [head taps, inputs, outputs, impulses, paths, [[block, k0,
// partitions], ...]].
static VALUE conv_shape(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	VALUE lv = rb_ary_new();
	for (long i = 0; i < e->nlevels; i++) {
		rb_ary_push(lv, rb_ary_new_from_args(3, LONG2NUM(e->lv[i].Q), LONG2NUM(e->lv[i].k0), LONG2NUM(e->lv[i].K)));
	}
	return rb_ary_new_from_args(6, LONG2NUM(e->D), LONG2NUM(e->nin), LONG2NUM(e->nout), LONG2NUM(e->nir), LONG2NUM(e->npaths), lv);
}

// position: [head position, [[level position, blocks, partitions summed or
// tasks done], ...]].
static VALUE conv_position(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	VALUE lv = rb_ary_new();
	for (long i = 0; i < e->nlevels; i++) {
		const struct conv_level *l = &e->lv[i];
		rb_ary_push(lv, rb_ary_new_from_args(3, LONG2NUM(l->pos), LONG2NUM(l->block), LONG2NUM(l->spread ? l->tp : l->done)));
	}
	return rb_ary_new_from_args(2, LONG2NUM(e->hpos), lv);
}

void Init_fast_convolve(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_convolve = rb_define_module_under(sound, "FastConvolve");
	VALUE engine = rb_define_class_under(fast_convolve, "Engine", rb_cObject);

	rb_define_alloc_func(engine, conv_alloc);
	rb_define_method(engine, "initialize", conv_initialize, 7);
	rb_define_method(engine, "process", conv_process, 4);
	rb_define_method(engine, "room", conv_room, 0);
	rb_define_method(engine, "boundary_levels", conv_boundary_levels, 0);
	rb_define_method(engine, "fft_input", conv_fft_input, 2);
	rb_define_method(engine, "spectrum", conv_spectrum, 3);
	rb_define_method(engine, "finish", conv_finish, 2);
	rb_define_method(engine, "task", conv_task, 1);
	rb_define_method(engine, "task_result", conv_task_result, 1);
	rb_define_method(engine, "sub_size", conv_sub_size, 0);
	rb_define_method(engine, "quiet?", conv_quiet, 0);
	rb_define_method(engine, "reset", conv_reset, 0);
	rb_define_method(engine, "swap_state", conv_swap_state, 1);
	rb_define_method(engine, "shape", conv_shape, 0);
	rb_define_method(engine, "position", conv_position, 0);
}
