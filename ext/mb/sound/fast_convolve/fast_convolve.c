/*
 * MB::Sound::FastConvolve::Engine: zero-latency partitioned convolution for
 * GraphNode::Convolver (#convolve).
 *
 * An impulse response of L samples is cut into K partitions of P samples
 * (the last one zero-padded).  The first partition (the "head") runs in the
 * time domain, one dot product of P taps per sample and path, so the output
 * has no latency (Gardner 1995; Lake DSP's patent, US 5,502,747, has
 * expired).  Partitions 1...K-1 run as a uniformly partitioned
 * overlap-save convolution with a frequency-domain delay line: every P
 * input samples (a block), the last 2P inputs of each channel are
 * transformed (an FFT of N = 2P points, done in Ruby by Pocketfft between
 * calls), stored in a ring of K-1 spectra, and multiplied by the
 * partitions' spectra; the inverse transform's last P samples are the
 * output of partitions 1...K-1 for the next block.  Partition k reads the
 * spectrum k blocks back, so every partition but the first can be summed
 * before the block ends: #process spreads those multiply-adds evenly over
 * the block's samples (by the block position, so the work per buffer stays
 * flat and the order of the sums is the same at any buffer size), leaving
 * only partition 1 and the two transforms for the block boundary.
 *
 * Channels: up to two inputs and two outputs, and any number of impulse
 * channels; each path [input, output, impulse] adds input * impulse to the
 * output (mono, stereo, mono to stereo, true stereo).  Two real channels
 * share each complex FFT (input x0 + i x1; outputs from one transform of
 * the conjugated, Hermitian-extended spectrum A0 + i A1), so one block
 * costs two complex transforms whatever the channels.
 *
 * A block boundary, from Ruby (Convolver):
 *     room = engine.process(outs, ins, offset, n)   # n <= room before the call
 *     if room == 0
 *       engine.fft_input(work)                      # x0 + i x1, N points
 *       z = Pocketfft.fft(work)
 *       engine.spectrum(z, work)                    # ring, partition 1, packed output spectrum
 *       engine.finish(Pocketfft.fft(work))          # tails for the next block
 *     end
 * With K == 1 (an impulse no longer than P) there is no frequency-domain
 * part and #process wraps the block itself (room never returns 0).
 *
 * Everything is double precision; inputs are read as float32 and outputs
 * written as float32.  The Ruby mirror (MB::Sound::Convolution::RubyEngine)
 * sums in other orders, so they agree within a tolerance, not bit for bit.
 */

#include <limits.h>
#include <stdint.h>
#include <string.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"

#define CONV_MAX_CHANNELS 2

struct conv_engine {
	int ready;
	long P;      // partition (block) size
	long K;      // partitions, the head included
	long N;      // FFT size, 2P
	long B;      // bins per spectrum, P + 1
	long M;      // spectra in the ring, K - 1
	long nin, nout, nir, npaths;
	long length; // the impulse's length in samples (the quiet check)
	long *path_in, *path_out, *path_ir;

	double *head;   // nir * P: each impulse's first partition, reversed
	double *hr, *hi; // nir * M * B: partitions 1...K-1 (spectra, scaled by 1 / N)

	double *seg;    // nin * N: the last block and the current one
	double *xr, *xi; // nin * M * B: the ring of input spectra
	double *ar, *ai; // nout * B: partitions' sums for the next block
	double *tail;   // nout * P: the frequency-domain part of this block

	long pos;       // samples of the current block done
	long block;     // blocks completed
	long done;      // partitions 2... summed for the next block
	long zero_run;  // consecutive zero input samples (capped)
};

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
	free(e->hr);
	free(e->hi);
	free(e->seg);
	free(e->xr);
	free(e->xi);
	free(e->ar);
	free(e->ai);
	free(e->tail);
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
		total += 3 * e->npaths * sizeof(long);
		total += (e->nir * e->P + 2 * e->nir * e->M * e->B) * sizeof(double);
		total += (e->nin * e->N + 2 * e->nin * e->M * e->B + 2 * e->nout * e->B + e->nout * e->P) * sizeof(double);
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

// A writable contiguous 1D DComplex of +count+ values.
static double *conv_complex_out(VALUE v, size_t count, const char *name)
{
	conv_array(v, numo_cDComplex, count, name);
	rb_check_frozen(v);
	return (double *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
}

/*
 * Engine.new(partition, inputs, outputs, paths, heads, spectra, length)
 *
 * +paths+ is an Array of [input, output, impulse] index triples; +heads+ a
 * DFloat of impulses * partition values (each impulse's first partition,
 * reversed); +spectra+ a DComplex of impulses * (partitions - 1) *
 * (partition + 1) values (the FFTs of 2 * partition points of partitions
 * 1..., scaled by 1 / (2 * partition)), or nil for one partition;
 * +length+ the impulse length in samples.
 */
static VALUE conv_initialize(VALUE self, VALUE partition, VALUE inputs, VALUE outputs, VALUE paths, VALUE heads, VALUE spectra, VALUE length)
{
	struct conv_engine *e;
	TypedData_Get_Struct(self, struct conv_engine, &conv_type, e);
	if (e->ready) {
		rb_raise(rb_eRuntimeError, "Convolution engine already initialized");
	}

	long P = NUM2LONG(partition);
	if (P < 1 || P > (1L << 20)) {
		rb_raise(rb_eArgError, "The partition must be from 1 to 2**20 samples");
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

	narray_t *hna;
	if (CLASS_OF(heads) != numo_cDFloat) {
		rb_raise(rb_eArgError, "The heads must be a DFloat");
	}
	GetNArray(heads, hna);
	if (NA_SIZE(hna) == 0 || NA_SIZE(hna) % P != 0) {
		rb_raise(rb_eArgError, "The heads must hold a whole number of partitions");
	}
	long nir = NA_SIZE(hna) / P;
	long K = 1;
	if (!NIL_P(spectra)) {
		narray_t *sna;
		if (CLASS_OF(spectra) != numo_cDComplex) {
			rb_raise(rb_eArgError, "The spectra must be a DComplex");
		}
		GetNArray(spectra, sna);
		long per = nir * (P + 1);
		if (NA_SIZE(sna) == 0 || NA_SIZE(sna) % per != 0) {
			rb_raise(rb_eArgError, "The spectra must hold (partition + 1) bins per partition and impulse");
		}
		K = 1 + NA_SIZE(sna) / per;
	}

	long len = NUM2LONG(length);
	if (len < 0) {
		rb_raise(rb_eArgError, "The length must not be negative");
	}

	long *pin = conv_calloc(npaths, sizeof(long));
	long *pout = conv_calloc(npaths, sizeof(long));
	long *pir = conv_calloc(npaths, sizeof(long));
	e->path_in = pin;
	e->path_out = pout;
	e->path_ir = pir;
	for (long p = 0; p < npaths; p++) {
		VALUE t = rb_ary_entry(paths, p);
		Check_Type(t, T_ARRAY);
		if (RARRAY_LEN(t) != 3) {
			rb_raise(rb_eArgError, "Each path is [input, output, impulse]");
		}
		pin[p] = NUM2LONG(rb_ary_entry(t, 0));
		pout[p] = NUM2LONG(rb_ary_entry(t, 1));
		pir[p] = NUM2LONG(rb_ary_entry(t, 2));
		if (pin[p] < 0 || pin[p] >= nin || pout[p] < 0 || pout[p] >= nout || pir[p] < 0 || pir[p] >= nir) {
			rb_raise(rb_eArgError, "Path %ld [%ld, %ld, %ld] is out of range", p, pin[p], pout[p], pir[p]);
		}
	}

	e->P = P;
	e->K = K;
	e->N = 2 * P;
	e->B = P + 1;
	e->M = K - 1;
	e->nin = nin;
	e->nout = nout;
	e->nir = nir;
	e->npaths = npaths;
	e->length = len;

	const double *hp = conv_array(heads, numo_cDFloat, nir * P, "The heads");
	e->head = conv_calloc(nir * P, sizeof(double));
	memcpy(e->head, hp, nir * P * sizeof(double));

	long spec = nir * e->M * e->B;
	e->hr = conv_calloc(spec, sizeof(double));
	e->hi = conv_calloc(spec, sizeof(double));
	if (K > 1) {
		const double *sp = conv_array(spectra, numo_cDComplex, spec, "The spectra");
		for (long i = 0; i < spec; i++) {
			e->hr[i] = sp[2 * i];
			e->hi[i] = sp[2 * i + 1];
		}
	}

	e->seg = conv_calloc(nin * e->N, sizeof(double));
	e->xr = conv_calloc(nin * e->M * e->B, sizeof(double));
	e->xi = conv_calloc(nin * e->M * e->B, sizeof(double));
	e->ar = conv_calloc(nout * e->B, sizeof(double));
	e->ai = conv_calloc(nout * e->B, sizeof(double));
	e->tail = conv_calloc(nout * P, sizeof(double));

	RB_GC_GUARD(heads);
	RB_GC_GUARD(spectra);
	e->ready = 1;
	return self;
}

// The dot product of +n+ values (the head partition at one sample), in four
// running sums so the loop pipelines.
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

// The ring slot of the spectrum +j+ blocks from the start (j may be
// negative early on: a slot not written yet, holding zeros).
static inline long conv_slot(const struct conv_engine *e, long j)
{
	long s = j % e->M;
	return s < 0 ? s + e->M : s;
}

// Adds partition +k+ (1...K-1) of every path into the sums for the next
// block: the input spectrum of block (block + 1 - k) times H[k].
static void conv_mac(struct conv_engine *e, long k)
{
	long B = e->B;
	long slot = conv_slot(e, e->block + 1 - k);
	for (long p = 0; p < e->npaths; p++) {
		const double *xr = e->xr + (e->path_in[p] * e->M + slot) * B;
		const double *xi = e->xi + (e->path_in[p] * e->M + slot) * B;
		const double *hr = e->hr + (e->path_ir[p] * e->M + (k - 1)) * B;
		const double *hi = e->hi + (e->path_ir[p] * e->M + (k - 1)) * B;
		double *ar = e->ar + e->path_out[p] * B;
		double *ai = e->ai + e->path_out[p] * B;
		for (long b = 0; b < B; b++) {
			ar[b] += xr[b] * hr[b] - xi[b] * hi[b];
			ai[b] += xr[b] * hi[b] + xi[b] * hr[b];
		}
	}
}

// Sums partitions 2... up to +target+ of them (see #process).
static void conv_catch_up(struct conv_engine *e, long target)
{
	while (e->done < target) {
		conv_mac(e, e->done + 2);
		e->done++;
	}
}

// Ends a block: the last block's inputs move to the first half.
static void conv_shift(struct conv_engine *e)
{
	for (long c = 0; c < e->nin; c++) {
		memcpy(e->seg + c * e->N, e->seg + c * e->N + e->P, e->P * sizeof(double));
	}
	e->pos = 0;
	e->done = 0;
	e->block++;
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

/*
 * process(outs, ins, offset, n): convolves samples offset...offset + n of
 * the inputs +ins+ (an Array of one SFloat or nil, for silence, per input)
 * into the same samples of +outs+ (an Array of one SFloat per output).  n
 * may not pass the block boundary (see #room).  Returns the room left in
 * the block: 0 when the block boundary needs its transforms (see the file
 * comment).
 */
static VALUE conv_process(VALUE self, VALUE outs, VALUE ins, VALUE offset_v, VALUE n_v)
{
	struct conv_engine *e = conv_get(self);
	long offset = NUM2LONG(offset_v);
	long n = NUM2LONG(n_v);
	if (offset < 0 || n < 0 || n > e->P - e->pos) {
		rb_raise(rb_eArgError, "Process %ld samples at %ld with %ld left in the block", n, offset, e->P - e->pos);
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

	long P = e->P;
	long N = e->N;
	for (long j = 0; j < n; j++) {
		long pos = e->pos;
		int nonzero = 0;
		for (long c = 0; c < e->nin; c++) {
			double x = in[c] ? (double)in[c][offset + j] : 0.0;
			e->seg[c * N + P + pos] = x;
			nonzero |= x != 0.0;
		}

		double y[CONV_MAX_CHANNELS] = { 0.0, 0.0 };
		for (long p = 0; p < e->npaths; p++) {
			y[e->path_out[p]] += conv_dot(e->head + e->path_ir[p] * P, e->seg + e->path_in[p] * N + pos + 1, P);
		}
		for (long c = 0; c < e->nout; c++) {
			out[c][offset + j] = (float)(y[c] + e->tail[c * P + pos]);
		}

		e->zero_run = nonzero ? 0 : (e->zero_run < LONG_MAX / 2 ? e->zero_run + 1 : e->zero_run);
		e->pos = pos + 1;
	}

	if (e->K > 2) {
		conv_catch_up(e, (e->K - 2) * e->pos / P);
	}
	if (e->pos == P && e->K == 1) {
		conv_shift(e);
	}

	RB_GC_GUARD(outs);
	RB_GC_GUARD(ins);
	return LONG2NUM(P - e->pos);
}

// room: samples left before the next block boundary.
static VALUE conv_room(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	return LONG2NUM(e->P - e->pos);
}

static void conv_check_boundary(struct conv_engine *e)
{
	if (e->K < 2 || e->pos != e->P) {
		rb_raise(rb_eRuntimeError, "Not at a block boundary with a frequency-domain part");
	}
}

/*
 * fft_input(work): fills +work+ (a DComplex of 2 * partition values) with
 * the last two blocks of input, input 0 + i input 1.  Returns +work+.
 */
static VALUE conv_fft_input(VALUE self, VALUE work)
{
	struct conv_engine *e = conv_get(self);
	conv_check_boundary(e);
	double *w = conv_complex_out(work, e->N, "The work array");
	const double *s0 = e->seg;
	const double *s1 = e->nin > 1 ? e->seg + e->N : NULL;
	for (long t = 0; t < e->N; t++) {
		w[2 * t] = s0[t];
		w[2 * t + 1] = s1 ? s1[t] : 0.0;
	}
	return work;
}

/*
 * spectrum(z, work): stores the inputs' spectra from +z+ (the FFT of
 * #fft_input's array) in the ring, adds partition 1 (and any partitions not
 * summed yet), and fills +work+ with the conjugated, Hermitian-extended
 * spectrum output 0 + i output 1, whose FFT gives the outputs (#finish).
 * Returns +work+.
 */
static VALUE conv_spectrum(VALUE self, VALUE z, VALUE work)
{
	struct conv_engine *e = conv_get(self);
	conv_check_boundary(e);
	long N = e->N;
	long B = e->B;
	const double *zp = conv_array(z, numo_cDComplex, N, "The spectrum");
	double *w = conv_complex_out(work, N, "The work array");

	conv_catch_up(e, e->K - 2);

	long slot = conv_slot(e, e->block);
	double *x0r = e->xr + slot * B;
	double *x0i = e->xi + slot * B;
	if (e->nin == 1) {
		for (long b = 0; b < B; b++) {
			x0r[b] = zp[2 * b];
			x0i[b] = zp[2 * b + 1];
		}
	} else {
		double *x1r = e->xr + (e->M + slot) * B;
		double *x1i = e->xi + (e->M + slot) * B;
		for (long b = 0; b < B; b++) {
			long q = (N - b) % N;
			double kr = zp[2 * b], ki = zp[2 * b + 1];
			double nr = zp[2 * q], ni = zp[2 * q + 1];
			// X0 = (Z[b] + conj(Z[N - b])) / 2, X1 = (Z[b] - conj(Z[N - b])) / 2i
			x0r[b] = 0.5 * (kr + nr);
			x0i[b] = 0.5 * (ki - ni);
			x1r[b] = 0.5 * (ki + ni);
			x1i[b] = -0.5 * (kr - nr);
		}
	}

	conv_mac(e, 1);

	const double *a0r = e->ar, *a0i = e->ai;
	const double *a1r = e->nout > 1 ? e->ar + B : NULL;
	const double *a1i = e->nout > 1 ? e->ai + B : NULL;
	for (long b = 0; b < N; b++) {
		long q = b <= e->P ? b : N - b;
		double r0 = a0r[q], i0 = a0i[q];
		double r1 = a1r ? a1r[q] : 0.0, i1 = a1i ? a1i[q] : 0.0;
		if (b <= e->P) {
			// conj(A0 + i A1)
			w[2 * b] = r0 - i1;
			w[2 * b + 1] = -(i0 + r1);
		} else {
			// conj(conj(A0) + i conj(A1)) at the mirrored bin
			w[2 * b] = r0 + i1;
			w[2 * b + 1] = i0 - r1;
		}
	}

	RB_GC_GUARD(z);
	return work;
}

/*
 * finish(y): takes the next block's frequency-domain output from +y+ (the
 * FFT of #spectrum's array: output 0 in the real parts, output 1 in the
 * negated imaginary parts, last half) and starts the next block.
 */
static VALUE conv_finish(VALUE self, VALUE y)
{
	struct conv_engine *e = conv_get(self);
	conv_check_boundary(e);
	long P = e->P;
	const double *yp = conv_array(y, numo_cDComplex, e->N, "The output transform");
	for (long t = 0; t < P; t++) {
		e->tail[t] = yp[2 * (P + t)];
	}
	if (e->nout > 1) {
		for (long t = 0; t < P; t++) {
			e->tail[P + t] = -yp[2 * (P + t) + 1];
		}
	}
	memset(e->ar, 0, e->nout * e->B * sizeof(double));
	memset(e->ai, 0, e->nout * e->B * sizeof(double));
	conv_shift(e);
	RB_GC_GUARD(y);
	return self;
}

// quiet?: true when the inputs have been silent long enough that every
// output sample from here is zero until they sound again.
static VALUE conv_quiet(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	return e->zero_run >= e->length + 2 * e->N ? Qtrue : Qfalse;
}

// reset: silence (the impulse stays).
static VALUE conv_reset(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	memset(e->seg, 0, e->nin * e->N * sizeof(double));
	memset(e->xr, 0, e->nin * e->M * e->B * sizeof(double));
	memset(e->xi, 0, e->nin * e->M * e->B * sizeof(double));
	memset(e->ar, 0, e->nout * e->B * sizeof(double));
	memset(e->ai, 0, e->nout * e->B * sizeof(double));
	memset(e->tail, 0, e->nout * e->P * sizeof(double));
	e->pos = 0;
	e->block = 0;
	e->done = 0;
	e->zero_run = 0;
	return self;
}

#define CONV_SWAP(type, a, b) do { type t_ = (a); (a) = (b); (b) = t_; } while (0)

// swap_state(other): exchanges the running state (inputs, spectra, sums,
// tails, position) with +other+, an engine of the same shape (carry
// adoption: the rebuilt node continues the old one's sound).
static VALUE conv_swap_state(VALUE self, VALUE other)
{
	struct conv_engine *a = conv_get(self);
	if (!rb_typeddata_is_kind_of(other, &conv_type)) {
		rb_raise(rb_eTypeError, "Can only swap state with another engine");
	}
	struct conv_engine *b = conv_get(other);
	if (a->P != b->P || a->K != b->K || a->nin != b->nin || a->nout != b->nout) {
		rb_raise(rb_eArgError, "Engines of different shapes can't swap state");
	}
	CONV_SWAP(double *, a->seg, b->seg);
	CONV_SWAP(double *, a->xr, b->xr);
	CONV_SWAP(double *, a->xi, b->xi);
	CONV_SWAP(double *, a->ar, b->ar);
	CONV_SWAP(double *, a->ai, b->ai);
	CONV_SWAP(double *, a->tail, b->tail);
	CONV_SWAP(long, a->pos, b->pos);
	CONV_SWAP(long, a->block, b->block);
	CONV_SWAP(long, a->done, b->done);
	CONV_SWAP(long, a->zero_run, b->zero_run);
	return self;
}

// shape: [partition, partitions, inputs, outputs, impulses, paths].
static VALUE conv_shape(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	return rb_ary_new_from_args(6, LONG2NUM(e->P), LONG2NUM(e->K), LONG2NUM(e->nin), LONG2NUM(e->nout), LONG2NUM(e->nir), LONG2NUM(e->npaths));
}

// position: [samples into the block, blocks completed, partitions summed].
static VALUE conv_position(VALUE self)
{
	struct conv_engine *e = conv_get(self);
	return rb_ary_new_from_args(3, LONG2NUM(e->pos), LONG2NUM(e->block), LONG2NUM(e->done));
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
	rb_define_method(engine, "fft_input", conv_fft_input, 1);
	rb_define_method(engine, "spectrum", conv_spectrum, 2);
	rb_define_method(engine, "finish", conv_finish, 1);
	rb_define_method(engine, "quiet?", conv_quiet, 0);
	rb_define_method(engine, "reset", conv_reset, 0);
	rb_define_method(engine, "swap_state", conv_swap_state, 1);
	rb_define_method(engine, "shape", conv_shape, 0);
	rb_define_method(engine, "position", conv_position, 0);
}
