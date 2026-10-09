/*
 * MB::Sound::FastLoop: the per-sample executor of feedback loops
 * (MB::Sound::Plan::Loop, GraphNode::FeedbackLoop).  A loop's body is
 * described by its nodes as plan ops (lib/mb/sound/plan/loop.rb) and
 * lowered to Int32 words; this runs every op once per sample, so a value
 * can go around the loop on the next sample (or after any delay), whatever
 * the block size: the output doesn't depend on how the caller splits the
 * stream into blocks.
 *
 * Registers are single floats (the plan layer's float32 arithmetic, done
 * one sample at a time); state ops keep their state in Ruby objects that
 * belong to the graph nodes (a delay line's buffer and write offset, a
 * shaper's or SVF's state Array, a one-sample history), read at the start
 * of a call and written back at the end.
 *
 * Dispatch is direct-threaded with computed goto where the compiler has it
 * (GCC and clang: labels as values), else a switch: each op is decoded
 * once per call to its label, and each sample jumps from op to op
 * (research-plan-optimizations: 20 -> 17 ns per sample on a 9-op body).
 *
 * After decoding, an exact rewriter (2026-10-10, research-fused-ops rank 4)
 * drops identity ops (x * 1 and copies: their destination becomes an alias
 * of their operand; not 0 + x, which turns -0 into +0) and turns reads of
 * constant whole-sample sinc delays into direct reads (OP_DREAD_INT,
 * without the per-sample delay clamp, speed estimate, and mode branches);
 * cubic and linear reads index the line without a modulo per tap when the
 * taps don't wrap.  Same samples and state bit for bit.
 *
 * Exact Ruby mirror: Plan::Loop::Program#run_ruby (float32 rounding after
 * each op, the shapers', SVF's, and delay lines' own Ruby kernels).  Built
 * with -ffp-contract=off so no compiler fuses products and sums.
 *
 * FastLoop.run(words, scalars, objects, inputs, params, delays, out, count)
 *   words:   Int32 NArray: [nregs, out_reg, ninputs, nparams, nrings, nhist,
 *            then ninputs input registers, nparams param registers, nrings
 *            ring object indices, nhist history object indices, then the
 *            ops (see the opcode list), ending with OP_END]
 *   scalars: DFloat NArray of compile-time numbers
 *   objects: Array of Ruby objects for ops:
 *            ring:    [buffer (SFloat), write offset (Integer), read state
 *                      Array ([0]: previous delay or nil), mode (Integer,
 *                      DelayLine::INTERPOLATION), sinc kernel Array or nil,
 *                      blend (true: sinc reads too short for the kernel
 *                      blend into cubic)]; the write offset is stored back
 *            history: [value (Float)]
 *            shaper:  its state Array [x1, ap_x1, ap_y1, primed]
 *            SVF:     its state Array [ic1, ic2]
 *   inputs:  Array of SFloat NArrays (at least +count+ samples) for the
 *            boundary inputs
 *   params:  Array of Numerics or SFloat NArrays (Constant values)
 *   delays:  Array, one per ring: the delay in samples for each sample, a
 *            Numeric or an SFloat/DFloat NArray, counted back from the
 *            sample being computed (at least 1: the newest stored sample)
 *   out:     SFloat NArray of at least +count+ samples for the output
 * Returns +out+.
 */
#include <stdint.h>
#include <string.h>
#include <math.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_clip_shape.h"
#include "mb_svf.h"
#include "mb_delay_interp.h"

#include "loop_pitch.h"

// Computed goto where the compiler has labels as values (GCC, clang), unless
// built with -DMB_LOOP_SWITCH (for comparisons)
#if defined(__GNUC__) && !defined(MB_LOOP_SWITCH)
#define MB_LOOP_GOTO 1
#else
#define MB_LOOP_GOTO 0
#endif

// Opcodes (Plan::Loop::Program::OPCODES)
enum {
	OP_END = 0,   //                       end of the body
	OP_FILL,      // dst, sc               dst = (float)scalars[sc]
	OP_MUL,       // dst, a, b             dst = a * b
	OP_MULS,      // dst, a, sc            dst = (float)c * a
	OP_ADD,       // dst, a, b             dst = a + b
	OP_ADDS,      // dst, a, sc            dst = (float)c + a
	OP_DIV,       // dst, a, b             dst = a / b
	OP_DIVS,      // dst, a, sc            dst = a / (float)c
	OP_POW,       // dst, a, b             dst = pow(a, b)
	OP_MAX,       // dst, a, b             dst = a >= b || b is NaN ? a : b
	OP_COPY,      // dst, a                dst = a
	OP_SHAPE,     // dst, a, obj, sc       dst = shaper(a) (mb_clip_shape.h; sc: mode, p1, p2, antialias)
	OP_SVF,       // dst, a, obj, fc, q, g, type, sc     dst = SVF(a) (mb_svf.h; fc, q, g: a register, or -1 - scalar index; sc: sample rate)
	OP_DREAD,     // dst, ring             dst = the ring's line at this sample's delay (before this sample's write)
	OP_DWRITE,    // ring, a               the ring's line at this sample = a; the ring advances
	OP_HREAD,     // dst, hist             dst = the history's value (the previous sample's)
	OP_HWRITE,    // hist, a               the history's value = a
	OP_MULADD,    // dst, a, b, c          dst = a + b * c (two roundings, as OP_MUL then OP_ADD)
	OP_MULSADD,   // dst, a, b, sc         dst = a + (float)c * b (as OP_MULS then OP_ADD)
	OP_COUNT,

	// Internal ops made by the decode-time rewriter (never in words)
	OP_DREAD_INT = OP_COUNT, // dst, ring    a constant whole-sample sinc delay read directly
	OP_ALL
};

// Operand words per opcode (after the opcode)
static const int op_words[OP_COUNT] = {
	[OP_END] = 0, [OP_FILL] = 2, [OP_MUL] = 3, [OP_MULS] = 3, [OP_ADD] = 3, [OP_ADDS] = 3,
	[OP_DIV] = 3, [OP_DIVS] = 3, [OP_POW] = 3, [OP_MAX] = 3, [OP_COPY] = 2, [OP_SHAPE] = 4,
	[OP_SVF] = 8, [OP_DREAD] = 2, [OP_DWRITE] = 2, [OP_HREAD] = 2, [OP_HWRITE] = 2,
	[OP_MULADD] = 4, [OP_MULSADD] = 4,
};

// Sinc reads at delays shorter than the kernel's reach (taps newer than the
// newest stored sample) blend into cubic reads over this many samples, so
// a delay sweeping through the threshold doesn't jump in tone or alias
// noise (see Plan::Loop: sinc at d - 1 >= support, cubic at d - 1 <=
// support - LOOP_SINC_BLEND).
#define LOOP_SINC_BLEND 4.0

// Lowest SVF state kept (smaller values flush to zero after each sample,
// as FastFilter.svf does after each call)
#define LOOP_SVF_FLUSH 1e-30

// Highest SVF cutoff as a fraction of the sample rate (FastFilter's
// FP_MAX_CUTOFF_RATIO)
#define LOOP_SVF_MAX_CUTOFF_RATIO 0.49

DELAY_INTERP(loop_interp, float, double)

// A decoded op.
struct ins {
	void *label; // computed goto target
	int op;
	int dst, a, b, c;
	int st;            // index into the op's state table (shapers, SVFs, rings, histories)
	float k;           // a float scalar operand
	double kd[3];      // double operands (SVF parameters given as scalars)
	int kreg[3];       // SVF parameter registers (-1: use kd)
};

struct shaper_state {
	struct clip_params cp;
	_Bool aa, primed;
	double x1, ap_x1, ap_y1;
	VALUE state;
};

struct svf_state {
	struct mb_svf c;
	int type;
	double ic1, ic2, pi_over_rate, fc_max;
	VALUE state;
};

// Most taps a sinc read can use (2 * half * max_rate + 1, with room)
#define LOOP_SINC_MAX_TAPS 128

struct ring_state {
	// Sinc weights of the last read, reused while the delay and rate stay
	// the same (the same values ring_sinc would compute)
	double cw[LOOP_SINC_MAX_TAPS];
	double cd, crate, cwsum;
	long ckmin, ckn;
	_Bool cvalid;

	float *buf;
	long cap;
	long w;
	double prev;
	_Bool have_prev, moving, blend;
	int mode;
	struct sinc_kernel k;
	double max;
	const double *dd;
	const float *df;
	double dconst;
	long dint; // the delay of OP_DREAD_INT reads (0: none)
	VALUE obj, read_state;
};

struct hist_state {
	float v;
	VALUE obj;
};

// A sinc read at +dd+ samples before +base+ (as delay_interp's sinc case,
// whose weights and sums it reproduces exactly): the weights are cached
// while the delay and rate stay put, and taps are indexed without a
// division per tap.
static inline double ring_sinc(struct ring_state *g, long base, double dd, double rate)
{
	if (!g->cvalid || dd != g->cd || rate != g->crate) {
		const struct sinc_kernel *k = &g->k;
		double fc = rate > 1 ? 1.0 / (rate < k->max_rate ? rate : k->max_rate) : 1.0;
		double support = k->half / fc;
		long kmin = (long)ceil(dd - support);
		long kmax = (long)floor(dd + support);
		long nt = kmax - kmin + 1;
		if (nt > LOOP_SINC_MAX_TAPS || nt < 0) {
			g->cvalid = 0;
			return loop_interp(g->buf, g->cap, base, dd, DELAY_SINC, &g->k, rate);
		}

		double wsum = 0;
		for (long j = 0; j < nt; j++) {
			double w = sinc_weight(k, fabs((double)(kmin + j) - dd) * fc);
			g->cw[j] = w;
			wsum += w;
		}
		g->cd = dd;
		g->crate = rate;
		g->cwsum = wsum;
		g->ckmin = kmin;
		g->ckn = nt;
		g->cvalid = 1;
	}

	long cap = g->cap;
	long kk = g->ckmin;
	long idx = base - (kk > 0 ? kk : 0);
	while (idx < 0) {
		idx += cap;
	}
	double sum = 0;
	for (long j = 0; j < g->ckn; j++, kk++) {
		if (kk > 0 && j > 0) {
			// One sample older than the previous tap
			if (--idx < 0) {
				idx += cap;
			}
		}
		sum += g->cw[j] * (double)g->buf[idx];
	}
	return g->cwsum != 0 ? sum / g->cwsum : 0;
}

// The cubic read of DELAY_INTERP (the same arithmetic) with the taps
// indexed directly when none of them wraps.
static inline double ring_cubic(const struct ring_state *g, long base, double d, double rate)
{
	double dmin = floor(d);
	double t = d - dmin;
	long di = (long)dmin;
	long im1 = base - (di > 0 ? di - 1 : 0);
	long i2 = base - di - 2;
	if (di < 0 || i2 < 0 || im1 >= g->cap) {
		return loop_interp(g->buf, g->cap, base, d, DELAY_CUBIC, &g->k, rate);
	}

	const float *buf = g->buf;
	double ym1 = buf[im1];
	double y0 = buf[base - di];
	double y1 = buf[base - di - 1];
	double y2 = buf[i2];
	double c0 = y0;
	double c1 = 0.5 * (y1 - ym1);
	double c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2;
	double c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1);
	return ((c3 * t + c2) * t + c1) * t + c0;
}

// The linear read of DELAY_INTERP with the taps indexed directly when
// neither wraps.
static inline double ring_linear(const struct ring_state *g, long base, double d, double rate)
{
	double dmin = floor(d);
	double t = d - dmin;
	long di = (long)dmin;
	long i1 = base - di - 1;
	if (di < 0 || i1 < 0) {
		return loop_interp(g->buf, g->cap, base, d, DELAY_LINEAR, &g->k, rate);
	}

	double a = g->buf[base - di];
	double b = g->buf[i1];
	return a * (1.0 - t) + b * t;
}

// Reads the ring at +dd+ samples before its newest stored sample (the
// delay minus one), with the ring's interpolation.
static inline double ring_read(struct ring_state *g, double dd, double rate)
{
	long base = g->w - 1;
	if (base < 0) {
		base += g->cap;
	}

	if (g->mode == DELAY_SINC) {
		if (dd == floor(dd) && rate <= 1) {
			return g->buf[wrap_index(base - (long)dd, g->cap)];
		}

		if (g->blend) {
			double fc = rate > 1 ? 1.0 / (rate < g->k.max_rate ? rate : g->k.max_rate) : 1.0;
			double support = g->k.half / fc;
			double ws = (dd - (support - LOOP_SINC_BLEND)) / LOOP_SINC_BLEND;
			if (ws <= 0) {
				return ring_cubic(g, base, dd, rate);
			}
			if (ws < 1) {
				double s = ring_sinc(g, base, dd, rate);
				double c = ring_cubic(g, base, dd, rate);
				return ws * s + (1.0 - ws) * c;
			}
		}
	}

	if (g->mode == DELAY_SINC) {
		return ring_sinc(g, base, dd, rate);
	}
	if (g->mode == DELAY_CUBIC) {
		return ring_cubic(g, base, dd, rate);
	}
	return ring_linear(g, base, dd, rate);
}

static float *sfloat_ptr(VALUE v, size_t count, const char *what, long idx, _Bool write)
{
	if (CLASS_OF(v) != numo_cSFloat || RNARRAY_NDIM(v) != 1 || !RTEST(nary_check_contiguous(v)) || RNARRAY_SHAPE(v)[0] < count) {
		rb_raise(rb_eArgError, "%s %ld must be a contiguous 1D SFloat of at least %zu samples", what, idx, count);
	}
	char *p = write ? nary_get_pointer_for_write(v) : (char *)nary_get_pointer_for_read(v);
	return (float *)(p + nary_get_offset(v));
}

static void read_ring(struct ring_state *g, VALUE obj, VALUE delay, size_t count, long idx)
{
	Check_Type(obj, T_ARRAY);
	if (RARRAY_LEN(obj) != 6) {
		rb_raise(rb_eArgError, "Loop ring %ld must be [buffer, write offset, read state, mode, kernel, blend]", idx);
	}
	g->obj = obj;
	g->cvalid = 0;

	VALUE buffer = rb_ary_entry(obj, 0);
	if (CLASS_OF(buffer) != numo_cSFloat || RNARRAY_NDIM(buffer) != 1 || !RTEST(nary_check_contiguous(buffer))) {
		rb_raise(rb_eArgError, "Loop ring %ld buffer must be a contiguous 1D SFloat", idx);
	}
	g->buf = (float *)(nary_get_pointer_for_write(buffer) + nary_get_offset(buffer));
	g->cap = RNARRAY_SHAPE(buffer)[0];
	g->w = NUM2LONG(rb_ary_entry(obj, 1));
	if (g->w < 0 || g->w >= g->cap) {
		rb_raise(rb_eArgError, "Loop ring %ld write offset is out of range", idx);
	}

	g->read_state = rb_ary_entry(obj, 2);
	Check_Type(g->read_state, T_ARRAY);
	VALUE prev = rb_ary_entry(g->read_state, 0);
	g->have_prev = RTEST(prev);
	g->prev = g->have_prev ? NUM2DBL(prev) : 0;

	g->mode = NUM2INT(rb_ary_entry(obj, 3));
	if (g->mode < DELAY_LINEAR || g->mode > DELAY_SINC) {
		rb_raise(rb_eArgError, "Loop ring %ld has an unknown interpolation mode", idx);
	}

	memset(&g->k, 0, sizeof(g->k));
	if (g->mode == DELAY_SINC) {
		VALUE kernel = rb_ary_entry(obj, 4);
		if (!RB_TYPE_P(kernel, T_ARRAY) || RARRAY_LEN(kernel) != 4) {
			rb_raise(rb_eArgError, "Loop ring %ld needs a sinc kernel [table, half, resolution, max_rate]", idx);
		}
		VALUE table = rb_ary_entry(kernel, 0);
		if (CLASS_OF(table) != numo_cDFloat || RNARRAY_NDIM(table) != 1 || !RTEST(nary_check_contiguous(table))) {
			rb_raise(rb_eArgError, "The sinc kernel table must be a contiguous 1D DFloat NArray");
		}
		g->k.table = (const double *)(nary_get_pointer_for_read(table) + nary_get_offset(table));
		g->k.table_length = RNARRAY_SHAPE(table)[0];
		g->k.half = NUM2DBL(rb_ary_entry(kernel, 1));
		g->k.resolution = NUM2DBL(rb_ary_entry(kernel, 2));
		g->k.max_rate = NUM2DBL(rb_ary_entry(kernel, 3));
	}
	g->blend = RTEST(rb_ary_entry(obj, 5));

	// The read position (newest stored sample, minus the delay less one)
	// must stay inside the buffer with the interpolation's margin
	g->max = g->cap - 1 - delay_margin(g->mode, &g->k);
	if (g->max < 1) {
		rb_raise(rb_eArgError, "Loop ring %ld is too small for its interpolation", idx);
	}

	g->dd = NULL;
	g->df = NULL;
	g->dconst = 0;
	g->dint = 0;
	g->moving = 0;
	if (rb_obj_is_kind_of(delay, numo_cNArray)) {
		VALUE cls = CLASS_OF(delay);
		if (RNARRAY_NDIM(delay) != 1 || RNARRAY_SHAPE(delay)[0] < count || !RTEST(nary_check_contiguous(delay))) {
			rb_raise(rb_eArgError, "Loop delay %ld must be a contiguous 1D NArray of at least the block", idx);
		}
		if (cls == numo_cDFloat) {
			g->dd = (const double *)(nary_get_pointer_for_read(delay) + nary_get_offset(delay));
		} else if (cls == numo_cSFloat) {
			g->df = (const float *)(nary_get_pointer_for_read(delay) + nary_get_offset(delay));
		} else {
			rb_raise(rb_eArgError, "Loop delay %ld must be an SFloat or DFloat NArray", idx);
		}
		g->moving = 1;
	} else {
		g->dconst = NUM2DBL(delay);
	}
}

static VALUE ruby_run(VALUE self, VALUE words, VALUE scalars, VALUE objects, VALUE inputs, VALUE params, VALUE delays, VALUE out, VALUE count_v)
{
	if (CLASS_OF(words) != numo_cInt32 || RNARRAY_NDIM(words) != 1 || !RTEST(nary_check_contiguous(words))) {
		rb_raise(rb_eArgError, "Loop words must be a contiguous Int32 NArray");
	}
	if (CLASS_OF(scalars) != numo_cDFloat || RNARRAY_NDIM(scalars) != 1 || !RTEST(nary_check_contiguous(scalars))) {
		rb_raise(rb_eArgError, "Loop scalars must be a contiguous DFloat NArray");
	}
	Check_Type(objects, T_ARRAY);
	Check_Type(inputs, T_ARRAY);
	Check_Type(params, T_ARRAY);
	Check_Type(delays, T_ARRAY);

	long count_l = NUM2LONG(count_v);
	if (count_l < 0) {
		rb_raise(rb_eArgError, "Count must not be negative");
	}
	size_t n = (size_t)count_l;

	const int32_t *w = (const int32_t *)(nary_get_pointer_for_read(words) + nary_get_offset(words));
	size_t nwords = RNARRAY_SHAPE(words)[0];
	const double *sc = (const double *)(nary_get_pointer_for_read(scalars) + nary_get_offset(scalars));
	long nscalars = RNARRAY_SHAPE(scalars)[0];
	long nobjects = RARRAY_LEN(objects);

	if (nwords < 6) {
		rb_raise(rb_eArgError, "Loop words are too short");
	}
	int nregs = w[0], out_reg = w[1], ninputs = w[2], nparams = w[3], nrings = w[4], nhist = w[5];
	if (nregs < 1 || nregs > 65536 || out_reg < 0 || out_reg >= nregs || ninputs < 0 || nparams < 0 || nrings < 0 || nhist < 0) {
		rb_raise(rb_eArgError, "Bad loop header");
	}
	size_t pc = 6;
	if (pc + (size_t)ninputs + (size_t)nparams + (size_t)nrings + (size_t)nhist > nwords) {
		rb_raise(rb_eArgError, "Loop words are too short for the header");
	}
	if (RARRAY_LEN(inputs) != ninputs || RARRAY_LEN(params) != nparams || RARRAY_LEN(delays) != nrings) {
		rb_raise(rb_eArgError, "Loop inputs, params, or delays don't match the program");
	}

	float *outp = sfloat_ptr(out, n, "Output", 0, 1);

	// Boundary inputs and params
	int *in_reg = ALLOCA_N(int, ninputs + 1);
	const float **in_ptr = ALLOCA_N(const float *, ninputs + 1);
	for (int k = 0; k < ninputs; k++) {
		in_reg[k] = w[pc++];
		if (in_reg[k] < 0 || in_reg[k] >= nregs) rb_raise(rb_eArgError, "Bad loop input register");
		in_ptr[k] = sfloat_ptr(rb_ary_entry(inputs, k), n, "Loop input", k, 0);
	}
	int *par_reg = ALLOCA_N(int, nparams + 1);
	const float **par_ptr = ALLOCA_N(const float *, nparams + 1);
	float *par_val = ALLOCA_N(float, nparams + 1);
	for (int k = 0; k < nparams; k++) {
		par_reg[k] = w[pc++];
		if (par_reg[k] < 0 || par_reg[k] >= nregs) rb_raise(rb_eArgError, "Bad loop param register");
		VALUE v = rb_ary_entry(params, k);
		if (rb_obj_is_kind_of(v, numo_cNArray)) {
			par_ptr[k] = sfloat_ptr(v, n, "Loop param", k, 0);
			par_val[k] = 0;
		} else {
			par_ptr[k] = NULL;
			par_val[k] = (float)NUM2DBL(v);
		}
	}

	struct ring_state *rings = ALLOCA_N(struct ring_state, nrings + 1);
	for (int k = 0; k < nrings; k++) {
		int oi = w[pc++];
		if (oi < 0 || oi >= nobjects) rb_raise(rb_eArgError, "Bad loop ring object");
		read_ring(&rings[k], rb_ary_entry(objects, oi), rb_ary_entry(delays, k), n, k);
	}
	struct hist_state *hists = ALLOCA_N(struct hist_state, nhist + 1);
	for (int k = 0; k < nhist; k++) {
		int oi = w[pc++];
		if (oi < 0 || oi >= nobjects) rb_raise(rb_eArgError, "Bad loop history object");
		VALUE obj = rb_ary_entry(objects, oi);
		Check_Type(obj, T_ARRAY);
		if (RARRAY_LEN(obj) != 1) rb_raise(rb_eArgError, "Loop history must be [value]");
		hists[k].obj = obj;
		hists[k].v = (float)NUM2DBL(rb_ary_entry(obj, 0));
	}

	// Decode the ops (validating operands) and count state ops
	size_t nops = 0, nshape = 0, nsvf = 0;
	for (size_t q = pc;;) {
		if (q >= nwords) rb_raise(rb_eArgError, "Loop body has no end");
		int op = w[q];
		if (op < 0 || op >= OP_COUNT) rb_raise(rb_eArgError, "Bad loop opcode %d at word %zu", op, q);
		nops++;
		if (op == OP_END) break;
		if (op == OP_SHAPE) nshape++;
		if (op == OP_SVF) nsvf++;
		q += 1 + op_words[op];
	}

	struct ins *code = ALLOCA_N(struct ins, nops);
	struct shaper_state *shapers = ALLOCA_N(struct shaper_state, nshape + 1);
	struct svf_state *svfs = ALLOCA_N(struct svf_state, nsvf + 1);
	_Bool *ring_written = ALLOCA_N(_Bool, nrings + 1);
	memset(ring_written, 0, sizeof(_Bool) * (nrings + 1));

#if MB_LOOP_GOTO
	static void *labels[OP_ALL] = {
		[OP_END] = &&L_OP_END, [OP_FILL] = &&L_OP_FILL, [OP_MUL] = &&L_OP_MUL, [OP_MULS] = &&L_OP_MULS,
		[OP_ADD] = &&L_OP_ADD, [OP_ADDS] = &&L_OP_ADDS, [OP_DIV] = &&L_OP_DIV, [OP_DIVS] = &&L_OP_DIVS,
		[OP_POW] = &&L_OP_POW, [OP_MAX] = &&L_OP_MAX, [OP_COPY] = &&L_OP_COPY, [OP_SHAPE] = &&L_OP_SHAPE,
		[OP_SVF] = &&L_OP_SVF, [OP_DREAD] = &&L_OP_DREAD, [OP_DWRITE] = &&L_OP_DWRITE,
		[OP_HREAD] = &&L_OP_HREAD, [OP_HWRITE] = &&L_OP_HWRITE, [OP_MULADD] = &&L_OP_MULADD,
		[OP_MULSADD] = &&L_OP_MULSADD, [OP_DREAD_INT] = &&L_OP_DREAD_INT,
	};
#endif

#define REG(x) do { if ((x) < 0 || (x) >= nregs) rb_raise(rb_eArgError, "Bad loop register %d at word %zu", (int)(x), q); } while (0)
#define SCALAR(x) do { if ((x) < 0 || (x) >= nscalars) rb_raise(rb_eArgError, "Bad loop scalar %d at word %zu", (int)(x), q); } while (0)
#define OBJECT(x) do { if ((x) < 0 || (x) >= nobjects) rb_raise(rb_eArgError, "Bad loop object %d at word %zu", (int)(x), q); } while (0)

	size_t ishape = 0, isvf = 0;
	for (size_t j = 0, q = pc; j < nops; j++) {
		const int32_t *o = w + q;
		struct ins *p = &code[j];
		memset(p, 0, sizeof(*p));
		p->op = o[0];
#if MB_LOOP_GOTO
		p->label = labels[p->op];
#endif

		switch (p->op) {
			case OP_END:
				break;
			case OP_FILL:
				REG(o[1]); SCALAR(o[2]);
				p->dst = o[1];
				p->k = (float)sc[o[2]];
				break;
			case OP_MUL: case OP_ADD: case OP_DIV: case OP_POW: case OP_MAX:
				REG(o[1]); REG(o[2]); REG(o[3]);
				p->dst = o[1]; p->a = o[2]; p->b = o[3];
				break;
			case OP_MULS: case OP_ADDS: case OP_DIVS:
				REG(o[1]); REG(o[2]); SCALAR(o[3]);
				p->dst = o[1]; p->a = o[2];
				p->k = (float)sc[o[3]];
				break;
			case OP_COPY:
				REG(o[1]); REG(o[2]);
				p->dst = o[1]; p->a = o[2];
				break;
			case OP_MULADD:
				REG(o[1]); REG(o[2]); REG(o[3]); REG(o[4]);
				p->dst = o[1]; p->a = o[2]; p->b = o[3]; p->c = o[4];
				break;
			case OP_MULSADD:
				REG(o[1]); REG(o[2]); REG(o[3]); SCALAR(o[4]);
				p->dst = o[1]; p->a = o[2]; p->b = o[3];
				p->k = (float)sc[o[4]];
				break;
			case OP_SHAPE: {
				REG(o[1]); REG(o[2]); OBJECT(o[3]);
				if (o[4] < 0 || o[4] + 4 > nscalars) rb_raise(rb_eArgError, "Bad loop shaper scalars at word %zu", q);
				p->dst = o[1]; p->a = o[2];
				p->st = (int)ishape;
				struct shaper_state *s = &shapers[ishape++];
				const double *k = sc + o[4];
				int mode = (int)k[0];
				if (mode < CLIP_SOFT || mode > CLIP_QUANTIZE) rb_raise(rb_eArgError, "Bad loop shaper mode %d", mode);
				const char *err = mb_clip_setup(&s->cp, (enum clip_mode)mode, k[1], k[2]);
				if (err) rb_raise(rb_eArgError, "%s", err);
				s->aa = k[3] != 0;
				s->state = rb_ary_entry(objects, o[3]);
				Check_Type(s->state, T_ARRAY);
				if (RARRAY_LEN(s->state) != 4) rb_raise(rb_eArgError, "Shaper state must have four elements");
				s->x1 = NUM2DBL(rb_ary_entry(s->state, 0));
				s->ap_x1 = NUM2DBL(rb_ary_entry(s->state, 1));
				s->ap_y1 = NUM2DBL(rb_ary_entry(s->state, 2));
				s->primed = NUM2INT(rb_ary_entry(s->state, 3)) != 0;
				break;
			}
			case OP_SVF: {
				REG(o[1]); REG(o[2]); OBJECT(o[3]); SCALAR(o[8]);
				p->dst = o[1]; p->a = o[2];
				for (int m = 0; m < 3; m++) {
					int r = o[4 + m];
					if (r >= 0) {
						REG(r);
						p->kreg[m] = r;
					} else {
						SCALAR(-1 - r);
						p->kreg[m] = -1;
						p->kd[m] = sc[-1 - r];
					}
				}
				p->st = (int)isvf;
				struct svf_state *s = &svfs[isvf++];
				s->type = o[7];
				if (s->type < SVF_LOWPASS || s->type > SVF_BANDPASS_SKIRT) rb_raise(rb_eArgError, "Bad loop SVF type %d", s->type);
				double rate = sc[o[8]];
				if (!(rate > 0) || !isfinite(rate)) rb_raise(rb_eArgError, "Bad loop SVF sample rate");
				s->pi_over_rate = M_PI / rate;
				s->fc_max = rate * LOOP_SVF_MAX_CUTOFF_RATIO;
				mb_svf_init(&s->c);
				s->state = rb_ary_entry(objects, o[3]);
				Check_Type(s->state, T_ARRAY);
				if (RARRAY_LEN(s->state) != 2) rb_raise(rb_eArgError, "SVF state must have two elements");
				s->ic1 = mb_finite_entry(s->state, 0);
				s->ic2 = mb_finite_entry(s->state, 1);
				break;
			}
			case OP_DREAD:
				REG(o[1]);
				if (o[2] < 0 || o[2] >= nrings) rb_raise(rb_eArgError, "Bad loop ring at word %zu", q);
				p->dst = o[1]; p->st = o[2];
				break;
			case OP_DWRITE:
				if (o[1] < 0 || o[1] >= nrings) rb_raise(rb_eArgError, "Bad loop ring at word %zu", q);
				if (ring_written[o[1]]) rb_raise(rb_eArgError, "Loop ring %d is written twice", o[1]);
				ring_written[o[1]] = 1;
				REG(o[2]);
				p->st = o[1]; p->a = o[2];
				break;
			case OP_HREAD:
				REG(o[1]);
				if (o[2] < 0 || o[2] >= nhist) rb_raise(rb_eArgError, "Bad loop history at word %zu", q);
				p->dst = o[1]; p->st = o[2];
				break;
			case OP_HWRITE:
				if (o[1] < 0 || o[1] >= nhist) rb_raise(rb_eArgError, "Bad loop history at word %zu", q);
				REG(o[2]);
				p->st = o[1]; p->a = o[2];
				break;
		}

		q += 1 + op_words[p->op];
	}

	for (int k = 0; k < nrings; k++) {
		if (!ring_written[k]) rb_raise(rb_eArgError, "Loop ring %d is never written", k);
	}

#undef REG
#undef SCALAR
#undef OBJECT

	// The exact rewriter (see the description): identity aliasing and
	// direct whole-sample reads
	{
		int *alias = ALLOCA_N(int, nregs);
		for (int r = 0; r < nregs; r++) {
			alias[r] = r;
		}
		size_t kept = 0;
		for (size_t j = 0; j < nops; j++) {
			struct ins *p = &code[j];
			switch (p->op) {
				case OP_END: case OP_FILL: case OP_DREAD: case OP_HREAD:
					break;
				case OP_SVF:
					p->a = alias[p->a];
					for (int m = 0; m < 3; m++) {
						if (p->kreg[m] >= 0) {
							p->kreg[m] = alias[p->kreg[m]];
						}
					}
					break;
				case OP_MUL: case OP_ADD: case OP_DIV: case OP_POW: case OP_MAX: case OP_MULSADD:
					p->a = alias[p->a];
					p->b = alias[p->b];
					break;
				case OP_MULADD:
					p->a = alias[p->a];
					p->b = alias[p->b];
					p->c = alias[p->c];
					break;
				default: // one register operand in a
					p->a = alias[p->a];
					break;
			}

			if ((p->op == OP_MULS && p->k == 1.0f) || p->op == OP_COPY) {
				alias[p->dst] = p->a;
				continue;
			}

			if (p->op == OP_DREAD) {
				struct ring_state *g = &rings[p->st];
				if (!g->moving && g->mode == DELAY_SINC) {
					double d = g->dconst;
					if (!(d >= 1)) {
						d = 1;
					} else if (d > g->max) {
						d = g->max;
					}
					if (d == floor(d)) {
						g->dint = (long)d;
						p->op = OP_DREAD_INT;
#if MB_LOOP_GOTO
						p->label = labels[p->op];
#endif
					}
				}
			}

			code[kept++] = *p;
		}
		nops = kept;
		out_reg = alias[out_reg];
	}

	float *R = ALLOCA_N(float, nregs);
	memset(R, 0, sizeof(float) * nregs);

#if MB_LOOP_GOTO
#define OPCASE(x) L_##x:
#define NEXT do { p++; goto *p->label; } while (0)
#else
#define OPCASE(x) case x:
// (not in do-while(0): continue must reach the dispatch loop)
#define NEXT { p++; continue; }
#endif

	for (size_t i = 0; i < n; i++) {
		for (int k = 0; k < ninputs; k++) {
			R[in_reg[k]] = in_ptr[k][i];
		}
		for (int k = 0; k < nparams; k++) {
			R[par_reg[k]] = par_ptr[k] ? par_ptr[k][i] : par_val[k];
		}

		const struct ins *p = code;
#if MB_LOOP_GOTO
		goto *p->label;
#else
		for (;;) switch (p->op) {
#endif

		OPCASE(OP_FILL) { R[p->dst] = p->k; NEXT; }
		OPCASE(OP_MUL) { R[p->dst] = R[p->a] * R[p->b]; NEXT; }
		OPCASE(OP_MULS) { R[p->dst] = p->k * R[p->a]; NEXT; }
		OPCASE(OP_ADD) { R[p->dst] = R[p->a] + R[p->b]; NEXT; }
		OPCASE(OP_ADDS) { R[p->dst] = p->k + R[p->a]; NEXT; }
		OPCASE(OP_DIV) { R[p->dst] = R[p->a] / R[p->b]; NEXT; }
		OPCASE(OP_DIVS) { R[p->dst] = R[p->a] / p->k; NEXT; }
		OPCASE(OP_POW) { R[p->dst] = (float)pow(R[p->a], R[p->b]); NEXT; }
		OPCASE(OP_MAX) {
			float a = R[p->a], b = R[p->b];
			R[p->dst] = (a >= b || b != b) ? a : b;
			NEXT;
		}
		OPCASE(OP_COPY) { R[p->dst] = R[p->a]; NEXT; }
		OPCASE(OP_MULADD) {
			float t = R[p->b] * R[p->c];
			R[p->dst] = R[p->a] + t;
			NEXT;
		}
		OPCASE(OP_MULSADD) {
			float t = p->k * R[p->b];
			R[p->dst] = R[p->a] + t;
			NEXT;
		}
		OPCASE(OP_SHAPE) {
			struct shaper_state *s = &shapers[p->st];
			mb_clip_run(&s->cp, &R[p->a], &R[p->dst], 1, s->aa, &s->x1, &s->ap_x1, &s->ap_y1, &s->primed);
			NEXT;
		}
		OPCASE(OP_SVF) {
			struct svf_state *s = &svfs[p->st];
			double fc = p->kreg[0] >= 0 ? R[p->kreg[0]] : p->kd[0];
			double q = p->kreg[1] >= 0 ? R[p->kreg[1]] : p->kd[1];
			double g = p->kreg[2] >= 0 ? R[p->kreg[2]] : p->kd[2];
			mb_svf_coefficients(&s->c, s->type, fc, q, g, s->pi_over_rate, s->fc_max);
			double y = mb_svf_step(&s->c, R[p->a], &s->ic1, &s->ic2);
			if (!isfinite(s->ic1) || fabs(s->ic1) < LOOP_SVF_FLUSH) {
				s->ic1 = 0.0;
			}
			if (!isfinite(s->ic2) || fabs(s->ic2) < LOOP_SVF_FLUSH) {
				s->ic2 = 0.0;
			}
			R[p->dst] = (float)y;
			NEXT;
		}
		OPCASE(OP_DREAD) {
			struct ring_state *g = &rings[p->st];
			double d = g->dd ? g->dd[i] : (g->df ? (double)g->df[i] : g->dconst);
			if (!(d >= 1)) {
				d = 1; // also NaN
			} else if (d > g->max) {
				d = g->max;
			}
			double rate = g->have_prev && g->moving ? fabs(1.0 - (d - g->prev)) : 1.0;
			g->prev = d;
			g->have_prev = 1;
			R[p->dst] = (float)ring_read(g, d - 1.0, rate);
			NEXT;
		}
		OPCASE(OP_DREAD_INT) {
			// ring_read's whole-sample sinc read at d - 1 before the newest
			// sample: buf[w - 1 - (d - 1)]
			const struct ring_state *g = &rings[p->st];
			long idx = g->w - g->dint;
			if (idx < 0) {
				idx += g->cap;
			}
			R[p->dst] = g->buf[idx];
			NEXT;
		}
		OPCASE(OP_DWRITE) {
			struct ring_state *g = &rings[p->st];
			g->buf[g->w] = R[p->a];
			if (++g->w >= g->cap) {
				g->w = 0;
			}
			NEXT;
		}
		OPCASE(OP_HREAD) { R[p->dst] = hists[p->st].v; NEXT; }
		OPCASE(OP_HWRITE) { hists[p->st].v = R[p->a]; NEXT; }
		OPCASE(OP_END) { goto sample_done; }

#if !MB_LOOP_GOTO
			default:
				goto sample_done;
		}
#endif

sample_done:
		outp[i] = R[out_reg];
	}

#undef OPCASE
#undef NEXT

	// Store the state back
	for (size_t k = 0; k < nshape; k++) {
		struct shaper_state *s = &shapers[k];
		if (s->aa && n > 0) {
			rb_ary_store(s->state, 0, rb_float_new(s->x1));
			rb_ary_store(s->state, 1, rb_float_new(s->ap_x1));
			rb_ary_store(s->state, 2, rb_float_new(s->ap_y1));
			rb_ary_store(s->state, 3, INT2NUM(1));
		}
	}
	for (size_t k = 0; k < nsvf; k++) {
		rb_ary_store(svfs[k].state, 0, rb_float_new(svfs[k].ic1));
		rb_ary_store(svfs[k].state, 1, rb_float_new(svfs[k].ic2));
	}
	for (int k = 0; k < nrings; k++) {
		struct ring_state *g = &rings[k];
		rb_ary_store(g->obj, 1, LONG2NUM(g->w));
		if (g->dint > 0 && n > 0) {
			// As OP_DREAD would have left it
			g->prev = (double)g->dint;
			g->have_prev = 1;
		}
		if (g->have_prev) {
			rb_ary_store(g->read_state, 0, rb_float_new(g->prev));
		}
	}
	for (int k = 0; k < nhist; k++) {
		rb_ary_store(hists[k].obj, 0, rb_float_new(hists[k].v));
	}

	RB_GC_GUARD(words);
	RB_GC_GUARD(scalars);
	RB_GC_GUARD(objects);
	RB_GC_GUARD(inputs);
	RB_GC_GUARD(params);
	RB_GC_GUARD(delays);
	RB_GC_GUARD(out);

	return out;
}

// The opcodes and constants, for specs to compare with the Ruby side.
static VALUE ruby_constants(VALUE self)
{
	VALUE h = rb_hash_new();
	rb_hash_aset(h, ID2SYM(rb_intern("end")), INT2NUM(OP_END));
	rb_hash_aset(h, ID2SYM(rb_intern("fill")), INT2NUM(OP_FILL));
	rb_hash_aset(h, ID2SYM(rb_intern("mul")), INT2NUM(OP_MUL));
	rb_hash_aset(h, ID2SYM(rb_intern("muls")), INT2NUM(OP_MULS));
	rb_hash_aset(h, ID2SYM(rb_intern("add")), INT2NUM(OP_ADD));
	rb_hash_aset(h, ID2SYM(rb_intern("adds")), INT2NUM(OP_ADDS));
	rb_hash_aset(h, ID2SYM(rb_intern("div")), INT2NUM(OP_DIV));
	rb_hash_aset(h, ID2SYM(rb_intern("divs")), INT2NUM(OP_DIVS));
	rb_hash_aset(h, ID2SYM(rb_intern("pow")), INT2NUM(OP_POW));
	rb_hash_aset(h, ID2SYM(rb_intern("max")), INT2NUM(OP_MAX));
	rb_hash_aset(h, ID2SYM(rb_intern("copy")), INT2NUM(OP_COPY));
	rb_hash_aset(h, ID2SYM(rb_intern("shape")), INT2NUM(OP_SHAPE));
	rb_hash_aset(h, ID2SYM(rb_intern("svf")), INT2NUM(OP_SVF));
	rb_hash_aset(h, ID2SYM(rb_intern("dread")), INT2NUM(OP_DREAD));
	rb_hash_aset(h, ID2SYM(rb_intern("dwrite")), INT2NUM(OP_DWRITE));
	rb_hash_aset(h, ID2SYM(rb_intern("hread")), INT2NUM(OP_HREAD));
	rb_hash_aset(h, ID2SYM(rb_intern("hwrite")), INT2NUM(OP_HWRITE));
	rb_hash_aset(h, ID2SYM(rb_intern("muladd")), INT2NUM(OP_MULADD));
	rb_hash_aset(h, ID2SYM(rb_intern("mulsadd")), INT2NUM(OP_MULSADD));
	rb_hash_aset(h, ID2SYM(rb_intern("sinc_blend")), DBL2NUM(LOOP_SINC_BLEND));
	rb_hash_aset(h, ID2SYM(rb_intern("svf_flush")), DBL2NUM(LOOP_SVF_FLUSH));
#if MB_LOOP_GOTO
	rb_hash_aset(h, ID2SYM(rb_intern("dispatch")), ID2SYM(rb_intern("goto")));
#else
	rb_hash_aset(h, ID2SYM(rb_intern("dispatch")), ID2SYM(rb_intern("switch")));
#endif
	return h;
}

void Init_fast_loop(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_loop = rb_define_module_under(sound, "FastLoop");

	rb_define_module_function(fast_loop, "run", ruby_run, 8);
	rb_define_module_function(fast_loop, "constants", ruby_constants, 0);

	mb_loop_pitch_init(fast_loop);
}
