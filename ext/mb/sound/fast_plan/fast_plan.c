/*
 * MB::Sound::FastPlan: the executor of the plan layer (lib/mb/sound/plan.rb),
 * a small register machine for audio.  A plan is a region of a GraphNode
 * graph (Multipliers, Mixers, Constants, oscillators, ...) described by its
 * nodes as a list of ops (MB::Sound::Plan::Op) and lowered to Int32 words
 * (MB::Sound::Plan::Program#lower).  One call runs every op over one block,
 * so a region costs one Ruby->C call instead of one #sample call per node
 * (and per Tee branch).
 *
 * Registers hold a block of float32 samples (or complex float32 pairs).
 * Each register is a scratch slot, a boundary input buffer (read in place),
 * a Constant's param (a value filled into its slot, or its buffer), or the
 * output buffer.  Ops work on whole blocks (block-at-a-time; a per-sample
 * loop mode for feedback regions is a planned extension, see plan.rb).
 *
 * Every op does exactly the float operations of the node it replaces, in
 * the same order (Numo's and FastArithmetic's arithmetic, with real
 * operands promoted to (x, +0.0) for complex results; FastSound.oscillate's
 * and FastSynth.oscillate_bl's loops through the shared headers), so plans
 * give the same samples as the unfused graph.  Each product and sum is its
 * own statement, so no compiler contracts them into FMAs.  The Ruby mirror
 * is Plan::Program#run_ruby (each op's #run_ruby).
 *
 * Oscillator state stays in the Tone's State object (its Arrays are read
 * and written as the kernels do), and phase jumps (reset inputs) call the
 * Tone's own Ruby (Tone#plan_reset), so planned and unplanned blocks can
 * alternate and resets cost what they cost unplanned.
 *
 * FastPlan.run(words, scalars, objects, inputs, params, scratch, out, count)
 *   words:   Int32 NArray: [nregs, nslots, then 4 words per register
 *            (kind, index, complex, slot), then the ops]
 *   scalars: DFloat NArray of compile-time numbers (Consts as re, im pairs;
 *            tone settings)
 *   objects: Array of Ruby objects for ops (per tone: [tone, state, freq,
 *            width])
 *   inputs:  Array of the boundary inputs' NArrays (nil: an optional input
 *            that ended)
 *   params:  Array of Constant values (Numeric) or buffers (NArray)
 *   scratch: SFloat NArray of nslots * stride floats (stride >= 2 * count)
 *   out:     SFloat or SComplex NArray of at least +count+ samples
 */
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <complex.h>

#include <ruby.h>
#include "numo/narray.h"

#include "mb_ext_helpers.h"
#include "mb_osc_shapes.h"
#include "mb_bl_osc.h"
#include "mb_clip_shape.h"
#include "mb_fast_math.h"
#include "mb_envelope.h"

// Register kinds (Plan::Program::REG_KINDS)
enum { REG_SLOT = 0, REG_INPUT = 1, REG_PARAM = 2, REG_OUT = 3 };

// Opcodes (Plan::Program::OPCODES)
enum {
	OP_FILL = 1,  // dst, sc                     dst = (re, im) of scalars[sc]
	OP_MUL,       // dst, a, b                   dst = a * b
	OP_MULS,      // dst, a, sc                  dst = c * a
	OP_ADD,       // dst, a, b                   dst = a + b
	OP_ADDS,      // dst, a, sc                  dst = c + a
	OP_DIV,       // dst, a, b                   dst = a / b (real)
	OP_DIVS,      // dst, a, sc                  dst = a / c (real)
	OP_POW,       // dst, a, b                   dst = pow(a, b) (real)
	OP_PART,      // dst, a, which               dst = real (0) or imag (1) part of a
	OP_TONE,      // see run_tone
	OP_COPY,      // dst, a, 0                   dst = a
	OP_SHAPE,     // dst, a, object, sc          dst = shaper(a) (FastClip.shape); object: state Array; sc: mode, p1, p2, antialias
	OP_NOTE_FREQ, // dst, a, object, 0           dst = frequency of note numbers a (FastSound.number_to_freq) in the tuning object's current note/frequency
	OP_EVENTS,    // dst, object, 0              dst = the event list object rendered (see run_events)
	OP_KEEP,      // dst, a, object              object [target, name]: target's ivar name (or Hash key) = last sample of a; dst unused
	OP_ENVELOPE,  // see run_envelope
};

// Event list modes and entry kinds (Plan::EventList)
enum { EVENTS_HELD = 0, EVENTS_IMPULSES = 1 };
enum event_kind { EV_FILL = 0, EV_IMPULSE = 1, EV_GLIDE = 2, EV_BUFFER = 3 };
#define EV_ENTRY_SIZE 8

// Kernels of OP_TONE (Plan::Op::Tone::KERNELS)
enum { TONE_NAIVE = 0, TONE_SYNTH = 1 };

typedef struct { float r, i; } mb_cf;

static ID id_phase, id_blep, id_noise, id_jump_residual, id_last_freq, id_last_width;
static ID id_plan_reset, id_plan_residual_used, id_note, id_frequency;

// The register file of one call.
struct regs {
	float **p;        // data (float pairs for complex registers)
	const char *c;    // 1 for complex registers
};

// A complex product written out, each product in its own statement (no
// FMA), with x first as in FastArithmetic's CMUL.
static inline mb_cf cmul(float xr, float xi, float yr, float yi)
{
	float a = xr * yr;
	float b = xi * yi;
	float c = xr * yi;
	float d = xi * yr;
	mb_cf z;
	z.r = a - b;
	z.i = c + d;
	return z;
}

// The arithmetic ops below have one loop per operand type combination, so
// the inner loops have no branches (a real operand of a complex result is
// (x, +0.0), as Numo promotes it).

static void op_mul(const struct regs *R, int d, int a, int b, size_t n)
{
	float *D = R->p[d];
	const float *A = R->p[a], *B = R->p[b];
	if (!R->c[d]) {
		for (size_t i = 0; i < n; i++) D[i] = A[i] * B[i];
		return;
	}

	mb_cf *DC = (mb_cf *)D;
	const float zero = 0.0f;
	if (R->c[a] && R->c[b]) {
		for (size_t i = 0; i < n; i++) DC[i] = cmul(A[2 * i], A[2 * i + 1], B[2 * i], B[2 * i + 1]);
	} else if (R->c[a]) {
		for (size_t i = 0; i < n; i++) DC[i] = cmul(A[2 * i], A[2 * i + 1], B[i], zero);
	} else {
		for (size_t i = 0; i < n; i++) DC[i] = cmul(A[i], zero, B[2 * i], B[2 * i + 1]);
	}
}

static void op_muls(const struct regs *R, int d, int a, double cr, double ci, size_t n)
{
	float *D = R->p[d];
	const float *A = R->p[a];
	if (!R->c[d]) {
		float c = (float)cr;
		for (size_t i = 0; i < n; i++) D[i] = c * A[i];
		return;
	}

	float xr = (float)cr, xi = (float)ci;
	const float zero = 0.0f;
	mb_cf *DC = (mb_cf *)D;
	if (R->c[a]) {
		for (size_t i = 0; i < n; i++) DC[i] = cmul(xr, xi, A[2 * i], A[2 * i + 1]);
	} else {
		for (size_t i = 0; i < n; i++) DC[i] = cmul(xr, xi, A[i], zero);
	}
}

static void op_add(const struct regs *R, int d, int a, int b, size_t n)
{
	float *D = R->p[d];
	const float *A = R->p[a], *B = R->p[b];
	if (!R->c[d]) {
		for (size_t i = 0; i < n; i++) D[i] = A[i] + B[i];
		return;
	}

	const float zero = 0.0f;
	if (R->c[a] && R->c[b]) {
		for (size_t i = 0; i < 2 * n; i++) D[i] = A[i] + B[i];
	} else if (R->c[a]) {
		for (size_t i = 0; i < n; i++) {
			float re = A[2 * i] + B[i];
			float im = A[2 * i + 1] + zero;
			D[2 * i] = re;
			D[2 * i + 1] = im;
		}
	} else {
		for (size_t i = 0; i < n; i++) {
			float re = A[i] + B[2 * i];
			float im = zero + B[2 * i + 1];
			D[2 * i] = re;
			D[2 * i + 1] = im;
		}
	}
}

static void op_adds(const struct regs *R, int d, int a, double cr, double ci, size_t n)
{
	float *D = R->p[d];
	const float *A = R->p[a];
	if (!R->c[d]) {
		float c = (float)cr;
		for (size_t i = 0; i < n; i++) D[i] = c + A[i];
		return;
	}

	float xr = (float)cr, xi = (float)ci;
	const float zero = 0.0f;
	if (R->c[a]) {
		for (size_t i = 0; i < n; i++) {
			float re = xr + A[2 * i];
			float im = xi + A[2 * i + 1];
			D[2 * i] = re;
			D[2 * i + 1] = im;
		}
	} else {
		for (size_t i = 0; i < n; i++) {
			float re = xr + A[i];
			float im = xi + zero;
			D[2 * i] = re;
			D[2 * i + 1] = im;
		}
	}
}

static void fill(float *D, _Bool is_complex, double cr, double ci, size_t n)
{
	if (is_complex) {
		mb_cf c = { (float)cr, (float)ci };
		mb_cf *DC = (mb_cf *)D;
		for (size_t i = 0; i < n; i++) DC[i] = c;
	} else {
		float c = (float)cr;
		for (size_t i = 0; i < n; i++) D[i] = c;
	}
}

// A signal input of a tone: a register (real parts of a complex one) from
// sample +start+, or a scalar.
static inline void tone_signal(struct mb_signal *s, const struct regs *R, int r, double scalar, size_t start)
{
	if (r >= 0 && R->p[r]) {
		s->step = R->c[r] ? 2 : 1;
		s->ptr = R->p[r] + start * s->step;
		s->scalar = s->ptr[0];
	} else {
		s->ptr = NULL;
		s->step = 1;
		s->scalar = scalar;
	}
}

// The value of a tone input at sample i as a Ruby Float (Tone#input_at).
static inline VALUE tone_input_at(const struct regs *R, int r, double scalar, size_t i)
{
	if (r >= 0 && R->p[r]) {
		return DBL2NUM(R->c[r] ? R->p[r][2 * i] : R->p[r][i]);
	}
	return DBL2NUM(scalar);
}

// FastSound.oscillate's loop (fast_sound.c ruby_oscillate) on one segment.
static void naive_segment(enum wave_types wt, void *out, _Bool complex_out, size_t length,
		const struct mb_signal *f, const struct mb_signal *p, double adv, double rndadv, double g, double off,
		VALUE phase_state, VALUE noise, _Bool fast)
{
	double phi = NUM2DBL(rb_ary_entry(phase_state, 0));

	uint64_t rng = 0;
	if (!NIL_P(noise)) {
		rng = NUM2ULL(rb_ary_entry(noise, 0));
	} else if (rndadv != 0) {
		rb_raise(rb_eArgError, "Noise (a random advance) needs a generator state");
	}

	double freq = f->scalar;
	const float *freqptr = f->ptr;
	size_t freqstep = f->step;
	double pm = p->scalar;
	const float *pmptr = p->ptr;
	size_t pmstep = p->step;

	_Bool constant = !freqptr && rndadv == 0;
	double steps = 0;
	for (size_t i = 0; i < length; i++) {
		if (freqptr) {
			freq = freqptr[i * freqstep];
		}
		if (pmptr) {
			pm = pmptr[i * pmstep];
		}

		double inc = phasor_increment(freq, adv, rndadv, &rng);
		if (constant) {
			steps = inc * i;
		}

		if (fast) {
			// Plan.precision :fast (sine and complex sine; see
			// mb_fast_math.h and Plan::FastMath.shape_ruby)
			double s, c;
			double x = pm * (1.0 / (2.0 * M_PI));
			x = mb_wrap(phi + steps, 1.0) + x;
			mb_fast_sincos_cycles(x, &s, &c);
			double re = s * g;
			re = re + off;
			if (complex_out) {
				double im = -c;
				im = im * g;
				((float *)out)[2 * i] = (float)re;
				((float *)out)[2 * i + 1] = (float)im;
			} else {
				((float *)out)[i] = (float)re;
			}
		} else {
			double complex v = shape_sample(wt, mb_wrap(phi + steps, 1.0), inc, pm) * g + off;

			if (complex_out) {
				((complex float *)out)[i] = v;
			} else {
				((float *)out)[i] = creal(v);
			}
		}

		if (!constant) {
			steps += inc;
		}
	}

	if (constant) {
		steps = phasor_increment(freq, adv, 0, &rng) * length;
	}
	rb_ary_store(phase_state, 0, rb_float_new(mb_wrap(phi + steps, 1.0)));
	if (!NIL_P(noise)) {
		rb_ary_store(noise, 0, ULL2NUM(rng));
	}
}

// FastSynth.oscillate_bl through mb_bl_oscillate on one segment, with the
// state Arrays read and written as ruby_oscillate_bl does.
static void synth_segment(enum bl_wave wt, float *out, size_t length,
		const struct mb_signal *f, const struct mb_signal *p, const struct mb_signal *w,
		double adv, double g, double off, double lo, double hi, _Bool dc, VALUE phase_state, VALUE bl_state)
{
	Check_Type(bl_state, T_ARRAY);
	if (RARRAY_LEN(bl_state) != 4) {
		rb_raise(rb_eArgError, "Band-limiting state must have four elements");
	}

	struct mb_bl_state st;
	st.phi = NUM2DBL(rb_ary_entry(phase_state, 0));
	st.prev_e = NUM2DBL(rb_ary_entry(bl_state, 0));
	st.prev_inc = NUM2DBL(rb_ary_entry(bl_state, 1));
	st.prev_pm = NUM2DBL(rb_ary_entry(bl_state, 2));
	st.primed = NUM2INT(rb_ary_entry(bl_state, 3));

	mb_bl_oscillate(wt, out, length, f, p, w, adv, g, off, lo, hi, dc, &st);

	rb_ary_store(phase_state, 0, rb_float_new(st.phi));
	if (length > 0) {
		rb_ary_store(bl_state, 0, rb_float_new(st.prev_e));
		rb_ary_store(bl_state, 1, rb_float_new(st.prev_inc));
		rb_ary_store(bl_state, 2, rb_float_new(st.prev_pm));
		rb_ary_store(bl_state, 3, INT2NUM(1));
	}
}

// Adds a queued band-limited phase jump step (State#jump_residual, a
// DFloat) to +seg+, as Tone#add_jump_residual does, and lets the tone keep
// the rest of it.
static void add_residual(VALUE tone, VALUE state, float *seg, size_t length, double g)
{
	VALUE res = rb_ivar_get(state, id_jump_residual);
	if (NIL_P(res)) {
		return;
	}

	if (CLASS_OF(res) != numo_cDFloat || RNARRAY_NDIM(res) != 1 || !RTEST(nary_check_contiguous(res))) {
		rb_raise(rb_eTypeError, "A planned tone's jump residual must be a contiguous DFloat");
	}

	size_t rl = RNARRAY_SHAPE(res)[0];
	size_t m = length < rl ? length : rl;
	const double *r = (const double *)(nary_get_pointer_for_read(res) + nary_get_offset(res));
	for (size_t i = 0; i < m; i++) {
		double s = r[i] * g;
		double v = (double)seg[i] + s;
		seg[i] = (float)v;
	}
	RB_GC_GUARD(res);

	rb_funcall(tone, id_plan_residual_used, 1, SIZET2NUM(m));
}

/*
 * OP_TONE: dst, object, kernel, wave, freq_r, pm_r, width_r, reset_r,
 * target_r, gain_r, sc (registers -1 for scalars or none).  Scalars from
 * sc: freq, pm, width, gain, advance, random advance, gain (#at), offset,
 * fade lo, fade hi, remove DC, has width, gain mode (0 none, 1 scalar, 2
 * register), fast shapes (Plan.precision :fast).  The object is [tone, state, frequency value, width value].
 * See Tone#sample_c and #sample_segments for the steps.
 */
static void run_tone(const int32_t *op, const struct regs *R, const double *sc, VALUE objects, size_t n)
{
	int dst = op[1];
	VALUE obj = rb_ary_entry(objects, op[2]);
	int kernel = op[3], wave = op[4];
	int fr = op[5], pr = op[6], wr = op[7], rr = op[8], tr = op[9], gr = op[10];
	const double *s = sc + op[11];

	VALUE tone = rb_ary_entry(obj, 0);
	VALUE state = rb_ary_entry(obj, 1);

	double freq_s = s[0], pm_s = s[1], width_s = s[2], gain_s = s[3];
	double adv = s[4], rndadv = s[5], g = s[6], off = s[7], lo = s[8], hi = s[9];
	_Bool dc = s[10] != 0, has_width = s[11] != 0;
	int gain_mode = (int)s[12];
	_Bool fast = s[13] != 0;
	if (fast && wave != OSC_SINE && wave != OSC_COMPLEX_SINE) rb_raise(rb_eArgError, "Fast plan tones are sines only");

	_Bool complex_out = R->c[dst];
	float *out = R->p[dst];

	VALUE phase_state = rb_ivar_get(state, id_phase);
	VALUE bl_state = kernel == TONE_SYNTH ? rb_ivar_get(state, id_blep) : Qnil;
	VALUE noise = kernel == TONE_NAIVE ? rb_ivar_get(state, id_noise) : Qnil;
	Check_Type(phase_state, T_ARRAY);

	const float *reset = rr >= 0 ? R->p[rr] : NULL;
	size_t reset_step = rr >= 0 && R->c[rr] ? 2 : 1;

	size_t start = 0;
	size_t scan = 0;
	for (;;) {
		// The next reset point at or after +scan+ (Tone#reset_points:
		// nonzero samples, either part of a complex one)
		size_t stop = n;
		if (reset) {
			for (; scan < n; scan++) {
				float re = reset[scan * reset_step];
				float im = reset_step == 2 ? reset[scan * 2 + 1] : 0.0f;
				if (re != 0 || im != 0) {
					stop = scan;
					break;
				}
			}
		}

		if (stop > start) {
			size_t len = stop - start;
			struct mb_signal f, p, w;
			tone_signal(&f, R, fr, freq_s, start);
			tone_signal(&p, R, pr, pm_s, start);

			if (kernel == TONE_SYNTH) {
				tone_signal(&w, R, wr, has_width ? width_s : 0.5, start);
				float *seg = out + start;
				synth_segment((enum bl_wave)wave, seg, len, &f, &p, &w, adv, g, off, lo, hi, dc, phase_state, bl_state);
				add_residual(tone, state, seg, len, g);
			} else {
				void *seg = complex_out ? (void *)(out + 2 * start) : (void *)(out + start);
				naive_segment((enum wave_types)wave, seg, complex_out, len, &f, &p, adv, rndadv, g, off, phase_state, noise, fast && kernel == TONE_NAIVE);
			}
		}

		if (stop >= n) {
			break;
		}

		// The jump before sample +stop+, in the tone's Ruby (target, random
		// phase, band-limited step)
		VALUE target = tr >= 0 && R->p[tr] ? tone_input_at(R, tr, 0, stop) : Qnil;
		rb_funcall(tone, id_plan_reset, 4,
				tone_input_at(R, fr, freq_s, stop),
				tone_input_at(R, pr, pm_s, stop),
				has_width || wr >= 0 ? tone_input_at(R, wr, width_s, stop) : Qnil,
				target);

		start = stop;
		scan = stop + 1;
	}

	// The #gain input (FastArithmetic.scale's arithmetic)
	if (gain_mode != 0) {
		const float *gp = gain_mode == 2 ? R->p[gr] : NULL;
		float gc = (float)gain_s;
		if (complex_out) {
			const float zero = 0.0f;
			for (size_t k = 0; k < n; k++) {
				float x = gp ? gp[k] : gc;
				float a = out[2 * k];
				float b = out[2 * k + 1];
				float p1 = a * x;
				float p2 = b * zero;
				float p3 = a * zero;
				float p4 = b * x;
				out[2 * k] = p1 - p2;
				out[2 * k + 1] = p3 + p4;
			}
		} else if (gp) {
			for (size_t k = 0; k < n; k++) out[k] = out[k] * gp[k];
		} else {
			for (size_t k = 0; k < n; k++) out[k] = out[k] * gc;
		}
	}

	// state.last_freq and last_width (Tone#sample_c)
	VALUE freq_v = rb_ary_entry(obj, 2);
	rb_ivar_set(state, id_last_freq, fr >= 0 ? DBL2NUM(R->p[fr][(n - 1) * (R->c[fr] ? 2 : 1)]) : freq_v);
	VALUE width_v = rb_ary_entry(obj, 3);
	rb_ivar_set(state, id_last_width, wr >= 0 ? DBL2NUM(R->p[wr][(n - 1) * (R->c[wr] ? 2 : 1)]) : width_v);

	RB_GC_GUARD(obj);
	RB_GC_GUARD(phase_state);
	RB_GC_GUARD(bl_state);
	RB_GC_GUARD(noise);
}

// OP_SHAPE: the shaper of FastClip.shape (mb_clip_shape.h) with the
// node's state Array [last input, allpass last input, allpass last output,
// primed].
static void run_shape(const int32_t *op, const struct regs *R, const double *sc, VALUE objects, size_t n)
{
	VALUE state = rb_ary_entry(objects, op[3]);
	const double *s = sc + op[4];
	int mode = (int)s[0];
	if (mode < CLIP_SOFT || mode > CLIP_QUANTIZE) rb_raise(rb_eArgError, "Bad plan shaper mode %d", mode);

	struct clip_params cp;
	const char *err = mb_clip_setup(&cp, (enum clip_mode)mode, s[1], s[2]);
	if (err) rb_raise(rb_eArgError, "%s", err);
	_Bool aa = s[3] != 0;

	Check_Type(state, T_ARRAY);
	if (RARRAY_LEN(state) != 4) rb_raise(rb_eArgError, "Shaper state must have four elements");
	double x1 = NUM2DBL(rb_ary_entry(state, 0));
	double ap_x1 = NUM2DBL(rb_ary_entry(state, 1));
	double ap_y1 = NUM2DBL(rb_ary_entry(state, 2));
	_Bool primed = NUM2INT(rb_ary_entry(state, 3)) != 0;

	mb_clip_run(&cp, R->p[op[2]], R->p[op[1]], n, aa, &x1, &ap_x1, &ap_y1, &primed);

	if (aa && n > 0) {
		rb_ary_store(state, 0, rb_float_new(x1));
		rb_ary_store(state, 1, rb_float_new(ap_x1));
		rb_ary_store(state, 2, rb_float_new(ap_y1));
		rb_ary_store(state, 3, INT2NUM(1));
	}
	RB_GC_GUARD(state);
}

// The ramp of Notes::Glide#fill (Plan::EventList.glide_ruby): every
// operation in double precision as Numo does it, each in its own statement.
static void glide_ramp(float *D, size_t n, double start, double target, double position, double length, double k)
{
	MB_ENV_NO_CONTRACT
	double diff = target - start;
	for (size_t i = 0; i < n; i++) {
		double t = position + 1.0 + (double)i;
		t = t / length;
		t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
		double shaped = t * -2.0;
		shaped = shaped + 3.0;
		double sq = t * t;
		shaped = shaped * sq;
		if (k != 0) {
			double bump = t * -1.0;
			bump = bump + 1.0;
			bump = bump * bump;
			sq = sq * t;
			bump = bump * sq;
			bump = bump * k;
			shaped = shaped + bump;
		}
		shaped = shaped * diff;
		shaped = shaped + start;
		D[i] = (float)shaped;
	}
}

static inline long ev_long(VALUE v)
{
	return FIXNUM_P(v) ? FIX2LONG(v) : NUM2LONG(v);
}

/*
 * OP_EVENTS: renders a Plan::EventList (a flat Array: the mode, then
 * entries of EV_ENTRY_SIZE values: kind, from, to, five arguments) into
 * +n+ samples of D.  Held lists' entries cover the block; impulse lists are
 * zeros plus single samples.  Entries past +n+ (a short block) are cut.
 */
static void run_events(float *D, VALUE list, size_t n)
{
	Check_Type(list, T_ARRAY);
	long len = RARRAY_LEN(list);
	if (len < 1 || (len - 1) % EV_ENTRY_SIZE != 0) rb_raise(rb_eArgError, "Bad plan event list length %ld", len);
	const VALUE *e = RARRAY_CONST_PTR(list);

	long mode = ev_long(e[0]);
	if (mode == EVENTS_IMPULSES) {
		memset(D, 0, n * sizeof(float));
	} else if (mode != EVENTS_HELD) {
		rb_raise(rb_eArgError, "Bad plan event list mode %ld", mode);
	}

	for (long j = 1; j < len; j += EV_ENTRY_SIZE) {
		long kind = ev_long(e[j]);
		long from = ev_long(e[j + 1]);
		long to = ev_long(e[j + 2]);
		if (from < 0 || to < from) rb_raise(rb_eArgError, "Bad plan event entry %ld...%ld", from, to);
		if ((size_t)from >= n) continue;
		if ((size_t)to > n) to = (long)n;

		switch (kind) {
			case EV_FILL: {
				float v = (float)NUM2DBL(e[j + 3]);
				for (long i = from; i < to; i++) D[i] = v;
				break;
			}
			case EV_IMPULSE:
				D[from] = (float)NUM2DBL(e[j + 3]);
				break;
			case EV_GLIDE:
				glide_ramp(D + from, (size_t)(to - from), NUM2DBL(e[j + 3]), NUM2DBL(e[j + 4]), NUM2DBL(e[j + 5]), NUM2DBL(e[j + 6]), NUM2DBL(e[j + 7]));
				break;
			case EV_BUFFER: {
				VALUE b = e[j + 3];
				if (CLASS_OF(b) != numo_cSFloat || RNARRAY_NDIM(b) != 1 || RNARRAY_SHAPE(b)[0] < (size_t)(to - from) || !RTEST(nary_check_contiguous(b))) {
					rb_raise(rb_eArgError, "A plan event buffer must be a contiguous SFloat of at least %ld samples", to - from);
				}
				const float *src = (const float *)(nary_get_pointer_for_read(b) + nary_get_offset(b));
				memcpy(D + from, src, (size_t)(to - from) * sizeof(float));
				break;
			}
			default:
				rb_raise(rb_eArgError, "Bad plan event entry kind %ld", kind);
		}
	}
	RB_GC_GUARD(list);
}

// An envelope signal from a register (real) or a scalar.
static inline void env_reg_signal(struct env_signal *s, const struct regs *R, int r, double scalar)
{
	s->scalar = scalar;
	s->d = NULL;
	s->f = r >= 0 ? R->p[r] : NULL;
}

/*
 * OP_ENVELOPE: dst, object, sc, nseg, then per segment: time, curve, and
 * level registers and the shape, then hold, gate, trigger, velocity,
 * choke, lift, and octaves registers (-1: the scalar).  Scalars from sc:
 * the config (flags, release node, velocity low, high, dB, choke samples,
 * curve scale, slope samples, overshoot, loop node or -1), then per
 * segment time, curve, level, then hold and the six inputs.  The object
 * is [envelope, state DFloat].  An idle envelope whose gate and trigger
 * stay quiet skips the kernel as Envelope#quiet_idle? does.
 */
static void run_envelope(const int32_t *op, const struct regs *R, const double *sc, VALUE objects, size_t n, long nregs)
{
	VALUE obj = rb_ary_entry(objects, op[2]);
	VALUE state = rb_ary_entry(obj, 1);
	if (CLASS_OF(state) != numo_cDFloat || RNARRAY_NDIM(state) != 1 || RNARRAY_SHAPE(state)[0] != ST_SIZE || !RTEST(nary_check_contiguous(state))) {
		rb_raise(rb_eArgError, "A planned envelope's state must be a contiguous DFloat of %d values", ST_SIZE);
	}
	double *st = (double *)(nary_get_pointer_for_write(state) + nary_get_offset(state));
	const double *s = sc + op[3];
	long nseg = op[4];

	struct mb_env_args a;
	a.nseg = nseg;
	a.flags = (int)s[0];
	a.release_node = (long)s[1];
	a.velocity_low = s[2];
	a.velocity_high = s[3];
	a.velocity_db = (int)s[4];
	a.choke_samples = env_length(s[5]);
	a.curve_scale = s[6];
	a.slope_samples = s[7];
	a.overshoot = s[8];
	a.loop_node = (long)s[9];
	if (a.release_node < 1 || a.release_node >= nseg) rb_raise(rb_eArgError, "Release node must be from 1 to %ld", nseg - 1);
	if (a.loop_node < -1 || a.loop_node > a.release_node) rb_raise(rb_eArgError, "Bad plan envelope loop node %ld", a.loop_node);
	if (a.velocity_db && !(a.velocity_low > 0 && a.velocity_high > 0)) rb_raise(rb_eArgError, "Velocity gains must be positive for dB scaling");

	const int32_t *w = op + 5;
	const double *segc = s + 10;
	for (long k = 0; k < nseg; k++) {
		for (int j = 0; j < 3; j++) {
			if (w[4 * k + j] >= nregs || (w[4 * k + j] >= 0 && (R->c[w[4 * k + j]] || !R->p[w[4 * k + j]]))) rb_raise(rb_eArgError, "Bad plan envelope register");
		}
		env_reg_signal(&a.times[k], R, w[4 * k], segc[3 * k]);
		env_reg_signal(&a.curves[k], R, w[4 * k + 1], segc[3 * k + 1]);
		env_reg_signal(&a.levels[k], R, w[4 * k + 2], segc[3 * k + 2]);
		a.shapes[k] = w[4 * k + 3];
		if (a.shapes[k] != ENV_SHAPE_EXP && a.shapes[k] != ENV_SHAPE_S) rb_raise(rb_eArgError, "Unknown segment shape %d", a.shapes[k]);
	}

	const int32_t *in = w + 4 * nseg;
	const double *inc = segc + 3 * nseg;
	for (int j = 0; j < 7; j++) {
		if (in[j] >= nregs || (in[j] >= 0 && (R->c[in[j]] || !R->p[in[j]]))) rb_raise(rb_eArgError, "Bad plan envelope input register");
	}
	env_reg_signal(&a.hold, R, in[0], inc[0]);
	env_reg_signal(&a.gate, R, in[1], inc[1]);
	env_reg_signal(&a.trigger, R, in[2], inc[2]);
	env_reg_signal(&a.velocity, R, in[3], inc[3]);
	env_reg_signal(&a.choke, R, in[4], inc[4]);
	env_reg_signal(&a.lift, R, in[5], inc[5]);
	env_reg_signal(&a.octaves, R, in[6], inc[6]);

	float *o = R->p[op[1]];

	// Envelope#quiet_idle?: idle, the gate low, no octaves, and the gate and
	// trigger quiet for the whole block
	if ((int)st[ST_STAGE] == ENV_IDLE && st[ST_GATE] == 0 && !(a.flags & ENV_OCTAVES)) {
		int quiet = 1;
		for (size_t i = 0; quiet && i < n; i++) {
			if (env_at(&a.gate, i) != 0 || env_at(&a.trigger, i) > 0) quiet = 0;
		}
		if (quiet) {
			memset(o, 0, n * sizeof(float));
			st[ST_LEVEL] = 0;
			st[ST_PREV_LEVEL] = 0;
			st[ST_TRIGGER] = 0;
			st[ST_NOTE_POSITION] += (double)n;
			RB_GC_GUARD(obj);
			return;
		}
	}

	if (mb_env_process(&a, o, n, st) != 0) {
		rb_raise(rb_eArgError, "Segment index %ld out of range in envelope state", (long)st[ST_SEGMENT]);
	}
	RB_GC_GUARD(obj);
	RB_GC_GUARD(state);
}

// Checks a buffer for register r: contiguous, the register's class, and at
// least n samples.  Returns its data.
static float *buffer_for(VALUE v, _Bool is_complex, size_t n, const char *what, long idx)
{
	VALUE cls = is_complex ? numo_cSComplex : numo_cSFloat;
	if (CLASS_OF(v) != cls || RNARRAY_NDIM(v) != 1 || RNARRAY_SHAPE(v)[0] < n || !RTEST(nary_check_contiguous(v))) {
		rb_raise(rb_eArgError, "Plan %s %ld must be a contiguous %s of at least %zu samples", what, idx, is_complex ? "SComplex" : "SFloat", n);
	}
	return (float *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
}

static VALUE ruby_run(VALUE self, VALUE words, VALUE scalars, VALUE objects, VALUE inputs, VALUE params,
		VALUE scratch, VALUE out, VALUE count_v)
{
	size_t n = NUM2SIZET(count_v);

	if (CLASS_OF(words) != numo_cInt32 || !RTEST(nary_check_contiguous(words))) rb_raise(rb_eArgError, "Plan words must be a contiguous Int32 NArray");
	if (CLASS_OF(scalars) != numo_cDFloat || !RTEST(nary_check_contiguous(scalars))) rb_raise(rb_eArgError, "Plan scalars must be a contiguous DFloat NArray");
	if (CLASS_OF(scratch) != numo_cSFloat || !RTEST(nary_check_contiguous(scratch))) rb_raise(rb_eArgError, "Plan scratch must be a contiguous SFloat NArray");
	Check_Type(objects, T_ARRAY);
	Check_Type(inputs, T_ARRAY);
	Check_Type(params, T_ARRAY);

	const int32_t *w = (const int32_t *)(nary_get_pointer_for_read(words) + nary_get_offset(words));
	size_t nwords = RNARRAY_SIZE(words);
	const double *sc = (const double *)(nary_get_pointer_for_read(scalars) + nary_get_offset(scalars));
	size_t nscalars = RNARRAY_SIZE(scalars);

	if (nwords < 2) rb_raise(rb_eArgError, "Plan words are too short");
	long nregs = w[0], nslots = w[1];
	if (nregs < 1 || nslots < 0 || (size_t)(2 + 4 * nregs) > nwords) rb_raise(rb_eArgError, "Bad plan register table");

	size_t stride = 0;
	float *mem = NULL;
	if (nslots > 0) {
		stride = RNARRAY_SIZE(scratch) / nslots;
		if (stride < 2 * n) rb_raise(rb_eArgError, "Plan scratch is too small for %zu samples", n);
		mem = (float *)(nary_get_pointer_for_write(scratch) + nary_get_offset(scratch));
	}

	float *ptrs[nregs];
	char cplx[nregs];
	struct regs R = { ptrs, cplx };

	// Bind the registers
	for (long r = 0; r < nregs; r++) {
		const int32_t *e = w + 2 + 4 * r;
		int kind = e[0], idx = e[1], slot = e[3];
		cplx[r] = e[2] != 0;
		if (slot >= nslots) rb_raise(rb_eArgError, "Bad plan slot %d", slot);

		switch (kind) {
			case REG_SLOT:
				if (slot < 0) rb_raise(rb_eArgError, "Plan register %ld has no slot", r);
				ptrs[r] = mem + slot * stride;
				break;

			case REG_INPUT: {
				VALUE v = rb_ary_entry(inputs, idx);
				ptrs[r] = NIL_P(v) ? NULL : buffer_for(v, cplx[r], n, "input", idx);
				break;
			}

			case REG_PARAM: {
				VALUE v = rb_ary_entry(params, idx);
				if (RB_FLOAT_TYPE_P(v) || RB_INTEGER_TYPE_P(v) || RB_TYPE_P(v, T_RATIONAL)) {
					if (slot < 0) rb_raise(rb_eArgError, "Plan param register %ld has no slot", r);
					ptrs[r] = mem + slot * stride;
					fill(ptrs[r], cplx[r], NUM2DBL(v), 0.0, n);
				} else if (RB_TYPE_P(v, T_COMPLEX)) {
					if (!cplx[r]) rb_raise(rb_eArgError, "Plan param %d is complex but its register is real", idx);
					if (slot < 0) rb_raise(rb_eArgError, "Plan param register %ld has no slot", r);
					ptrs[r] = mem + slot * stride;
					fill(ptrs[r], 1, NUM2DBL(rb_complex_real(v)), NUM2DBL(rb_complex_imag(v)), n);
				} else {
					ptrs[r] = buffer_for(v, cplx[r], n, "param", idx);
				}
				break;
			}

			case REG_OUT:
				ptrs[r] = buffer_for(out, cplx[r], n, "output", 0);
				break;

			default:
				rb_raise(rb_eArgError, "Bad plan register kind %d", kind);
		}
	}

	// Run the ops
	size_t pc = 2 + 4 * nregs;
	while (pc < nwords) {
		const int32_t *op = w + pc;
		size_t len;
		switch (op[0]) {
			case OP_FILL:
				len = 3;
				break;
			case OP_MUL: case OP_MULS: case OP_ADD: case OP_ADDS: case OP_DIV: case OP_DIVS: case OP_POW: case OP_PART: case OP_COPY:
				len = 4;
				break;
			case OP_TONE:
				len = 12;
				break;
			case OP_SHAPE: case OP_NOTE_FREQ:
				len = 5;
				break;
			case OP_EVENTS: case OP_KEEP:
				len = 4;
				break;
			case OP_ENVELOPE:
				if (pc + 5 > nwords || op[4] < 2 || op[4] > ENV_MAX_SEGMENTS) rb_raise(rb_eArgError, "Bad plan envelope at word %zu", pc);
				len = 5 + 4 * (size_t)op[4] + 7;
				break;
			default:
				rb_raise(rb_eArgError, "Bad plan opcode %d at word %zu", op[0], pc);
		}
		if (pc + len > nwords) rb_raise(rb_eArgError, "Truncated plan op at word %zu", pc);

		// Every register operand must be bound (an ended optional input
		// is NULL, which only tone resets and targets may read)
		int d = op[1];
		if (d < 0 || d >= nregs || !ptrs[d]) rb_raise(rb_eArgError, "Bad plan destination at word %zu", pc);
		if (op[0] != OP_FILL && op[0] != OP_TONE && op[0] != OP_EVENTS && op[0] != OP_ENVELOPE) {
			if (op[2] < 0 || op[2] >= nregs || !ptrs[op[2]]) rb_raise(rb_eArgError, "Bad plan operand at word %zu", pc);
		}
		if ((op[0] == OP_MUL || op[0] == OP_ADD || op[0] == OP_DIV || op[0] == OP_POW) && (op[3] < 0 || op[3] >= nregs || !ptrs[op[3]])) {
			rb_raise(rb_eArgError, "Bad plan operand at word %zu", pc);
		}
		if ((op[0] == OP_FILL && (op[2] < 0 || (size_t)op[2] + 2 > nscalars)) ||
				((op[0] == OP_MULS || op[0] == OP_ADDS || op[0] == OP_DIVS) && (op[3] < 0 || (size_t)op[3] + 2 > nscalars))) {
			rb_raise(rb_eArgError, "Bad plan scalar at word %zu", pc);
		}

		switch (op[0]) {
			case OP_FILL:
				fill(ptrs[d], cplx[d], sc[op[2]], sc[op[2] + 1], n);
				break;

			case OP_MUL:
				op_mul(&R, d, op[2], op[3], n);
				break;

			case OP_MULS:
				op_muls(&R, d, op[2], sc[op[3]], sc[op[3] + 1], n);
				break;

			case OP_ADD:
				op_add(&R, d, op[2], op[3], n);
				break;

			case OP_ADDS:
				op_adds(&R, d, op[2], sc[op[3]], sc[op[3] + 1], n);
				break;

			case OP_DIV: {
				if (cplx[d] || cplx[op[2]] || cplx[op[3]]) rb_raise(rb_eArgError, "Plan division is real only");
				float *D = ptrs[d];
				const float *A = ptrs[op[2]], *B = ptrs[op[3]];
				for (size_t i = 0; i < n; i++) D[i] = A[i] / B[i];
				break;
			}

			case OP_DIVS: {
				if (cplx[d] || cplx[op[2]]) rb_raise(rb_eArgError, "Plan division is real only");
				float *D = ptrs[d];
				const float *A = ptrs[op[2]];
				float c = (float)sc[op[3]];
				for (size_t i = 0; i < n; i++) D[i] = A[i] / c;
				break;
			}

			case OP_POW: {
				if (cplx[d] || cplx[op[2]] || cplx[op[3]]) rb_raise(rb_eArgError, "Plan power is real only");
				float *D = ptrs[d];
				const float *A = ptrs[op[2]], *B = ptrs[op[3]];
				for (size_t i = 0; i < n; i++) D[i] = pow(A[i], B[i]);
				break;
			}

			case OP_PART: {
				if (cplx[d] || !cplx[op[2]]) rb_raise(rb_eArgError, "Plan part needs a complex operand and a real result");
				float *D = ptrs[d];
				const float *A = ptrs[op[2]] + (op[3] ? 1 : 0);
				for (size_t i = 0; i < n; i++) D[i] = A[2 * i];
				break;
			}

			case OP_SHAPE:
				if (cplx[d] || cplx[op[2]]) rb_raise(rb_eArgError, "Plan shapers are real only");
				if (op[3] < 0 || op[3] >= RARRAY_LEN(objects)) rb_raise(rb_eArgError, "Bad plan shaper object at word %zu", pc);
				if (op[4] < 0 || (size_t)op[4] + 4 > nscalars) rb_raise(rb_eArgError, "Bad plan shaper scalars at word %zu", pc);
				run_shape(op, &R, sc, objects, n);
				break;

			case OP_NOTE_FREQ: {
				if (cplx[d] || cplx[op[2]]) rb_raise(rb_eArgError, "Plan note frequencies are real only");
				if (op[3] < 0 || op[3] >= RARRAY_LEN(objects)) rb_raise(rb_eArgError, "Bad plan tuning object at word %zu", pc);
				VALUE tuning = rb_ary_entry(objects, op[3]);
				double tnum = NUM2DBL(rb_funcall(tuning, id_note, 0));
				double tfrq = NUM2DBL(rb_funcall(tuning, id_frequency, 0));
				float *D = ptrs[d];
				const float *A = ptrs[op[2]];
				for (size_t i = 0; i < n; i++) D[i] = mb_num2freq(A[i], tnum, tfrq);
				break;
			}

			case OP_COPY:
				if (cplx[d] != cplx[op[2]]) rb_raise(rb_eArgError, "Plan copy needs registers of one type");
				memcpy(ptrs[d], ptrs[op[2]], n * (cplx[d] ? 2 : 1) * sizeof(float));
				break;

			case OP_EVENTS:
				if (cplx[d]) rb_raise(rb_eArgError, "Plan events are real");
				if (op[2] < 0 || op[2] >= RARRAY_LEN(objects)) rb_raise(rb_eArgError, "Bad plan event list at word %zu", pc);
				run_events(ptrs[d], rb_ary_entry(objects, op[2]), n);
				break;

			case OP_KEEP: {
				if (cplx[op[2]]) rb_raise(rb_eArgError, "Plan keep is real only");
				if (op[3] < 0 || op[3] >= RARRAY_LEN(objects)) rb_raise(rb_eArgError, "Bad plan keep object at word %zu", pc);
				if (n == 0) break;
				VALUE ko = rb_ary_entry(objects, op[3]);
				VALUE target = rb_ary_entry(ko, 0);
				VALUE name = rb_ary_entry(ko, 1);
				VALUE last = DBL2NUM(ptrs[op[2]][n - 1]);
				if (RB_TYPE_P(target, T_HASH)) {
					rb_hash_aset(target, name, last);
				} else {
					rb_ivar_set(target, SYM2ID(name), last);
				}
				break;
			}

			case OP_ENVELOPE:
				if (cplx[d]) rb_raise(rb_eArgError, "Plan envelopes are real");
				if (op[2] < 0 || op[2] >= RARRAY_LEN(objects)) rb_raise(rb_eArgError, "Bad plan envelope object at word %zu", pc);
				if (op[3] < 0 || (size_t)op[3] + 10 + 3 * (size_t)op[4] + 7 > nscalars) rb_raise(rb_eArgError, "Bad plan envelope scalars at word %zu", pc);
				run_envelope(op, &R, sc, objects, n, nregs);
				break;

			case OP_TONE: {
				if (op[2] < 0 || op[2] >= RARRAY_LEN(objects)) rb_raise(rb_eArgError, "Bad plan tone object at word %zu", pc);
				if (op[11] < 0 || (size_t)op[11] + 14 > nscalars) rb_raise(rb_eArgError, "Bad plan tone scalars at word %zu", pc);
				for (int k = 5; k <= 10; k++) {
					if (op[k] >= nregs) rb_raise(rb_eArgError, "Bad plan tone input at word %zu", pc);
				}
				if ((op[5] >= 0 && !ptrs[op[5]]) || (op[6] >= 0 && !ptrs[op[6]]) || (op[7] >= 0 && !ptrs[op[7]]) || (op[10] >= 0 && !ptrs[op[10]])) {
					rb_raise(rb_eArgError, "A planned tone's input is missing at word %zu", pc);
				}
				if (op[3] == TONE_SYNTH && cplx[d]) rb_raise(rb_eArgError, "Band-limited plan tones are real");
				if (op[3] != TONE_NAIVE && op[3] != TONE_SYNTH) rb_raise(rb_eArgError, "Bad plan tone kernel %d", op[3]);
				if (op[10] >= 0 && cplx[op[10]]) rb_raise(rb_eArgError, "A planned tone's gain must be real");
				if (op[4] < 0 || op[4] > OSC_PARABOLA) rb_raise(rb_eArgError, "Bad plan wave %d", op[4]);
				run_tone(op, &R, sc, objects, n);
				break;
			}
		}

		pc += len;
	}

	RB_GC_GUARD(words);
	RB_GC_GUARD(scalars);
	RB_GC_GUARD(objects);
	RB_GC_GUARD(inputs);
	RB_GC_GUARD(params);
	RB_GC_GUARD(scratch);
	RB_GC_GUARD(out);

	return out;
}

// The executor's enum values, for specs that check the Ruby side's tables.
static VALUE ruby_enums(VALUE self)
{
	VALUE h = rb_hash_new();
	rb_hash_aset(h, ID2SYM(rb_intern("reg_slot")), INT2NUM(REG_SLOT));
	rb_hash_aset(h, ID2SYM(rb_intern("reg_input")), INT2NUM(REG_INPUT));
	rb_hash_aset(h, ID2SYM(rb_intern("reg_param")), INT2NUM(REG_PARAM));
	rb_hash_aset(h, ID2SYM(rb_intern("reg_out")), INT2NUM(REG_OUT));
	rb_hash_aset(h, ID2SYM(rb_intern("fill")), INT2NUM(OP_FILL));
	rb_hash_aset(h, ID2SYM(rb_intern("mul")), INT2NUM(OP_MUL));
	rb_hash_aset(h, ID2SYM(rb_intern("muls")), INT2NUM(OP_MULS));
	rb_hash_aset(h, ID2SYM(rb_intern("add")), INT2NUM(OP_ADD));
	rb_hash_aset(h, ID2SYM(rb_intern("adds")), INT2NUM(OP_ADDS));
	rb_hash_aset(h, ID2SYM(rb_intern("div")), INT2NUM(OP_DIV));
	rb_hash_aset(h, ID2SYM(rb_intern("divs")), INT2NUM(OP_DIVS));
	rb_hash_aset(h, ID2SYM(rb_intern("pow")), INT2NUM(OP_POW));
	rb_hash_aset(h, ID2SYM(rb_intern("part")), INT2NUM(OP_PART));
	rb_hash_aset(h, ID2SYM(rb_intern("tone")), INT2NUM(OP_TONE));
	rb_hash_aset(h, ID2SYM(rb_intern("copy")), INT2NUM(OP_COPY));
	rb_hash_aset(h, ID2SYM(rb_intern("shape")), INT2NUM(OP_SHAPE));
	rb_hash_aset(h, ID2SYM(rb_intern("note_freq")), INT2NUM(OP_NOTE_FREQ));
	rb_hash_aset(h, ID2SYM(rb_intern("events")), INT2NUM(OP_EVENTS));
	rb_hash_aset(h, ID2SYM(rb_intern("keep")), INT2NUM(OP_KEEP));
	rb_hash_aset(h, ID2SYM(rb_intern("envelope")), INT2NUM(OP_ENVELOPE));
	rb_hash_aset(h, ID2SYM(rb_intern("events_held")), INT2NUM(EVENTS_HELD));
	rb_hash_aset(h, ID2SYM(rb_intern("events_impulses")), INT2NUM(EVENTS_IMPULSES));
	rb_hash_aset(h, ID2SYM(rb_intern("ev_fill")), INT2NUM(EV_FILL));
	rb_hash_aset(h, ID2SYM(rb_intern("ev_impulse")), INT2NUM(EV_IMPULSE));
	rb_hash_aset(h, ID2SYM(rb_intern("ev_glide")), INT2NUM(EV_GLIDE));
	rb_hash_aset(h, ID2SYM(rb_intern("ev_buffer")), INT2NUM(EV_BUFFER));
	rb_hash_aset(h, ID2SYM(rb_intern("env_state_size")), INT2NUM(ST_SIZE));
	rb_hash_aset(h, ID2SYM(rb_intern("tone_naive")), INT2NUM(TONE_NAIVE));
	rb_hash_aset(h, ID2SYM(rb_intern("tone_synth")), INT2NUM(TONE_SYNTH));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_sine")), INT2NUM(OSC_SINE));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_complex_sine")), INT2NUM(OSC_COMPLEX_SINE));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_triangle")), INT2NUM(OSC_TRIANGLE));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_complex_triangle")), INT2NUM(OSC_COMPLEX_TRIANGLE));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_square")), INT2NUM(OSC_SQUARE));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_complex_square")), INT2NUM(OSC_COMPLEX_SQUARE));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_ramp")), INT2NUM(OSC_RAMP));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_complex_ramp")), INT2NUM(OSC_COMPLEX_RAMP));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_gauss")), INT2NUM(OSC_GAUSS));
	rb_hash_aset(h, ID2SYM(rb_intern("osc_parabola")), INT2NUM(OSC_PARABOLA));
	rb_hash_aset(h, ID2SYM(rb_intern("bl_ramp")), INT2NUM(BL_RAMP));
	rb_hash_aset(h, ID2SYM(rb_intern("bl_square")), INT2NUM(BL_SQUARE));
	rb_hash_aset(h, ID2SYM(rb_intern("bl_triangle")), INT2NUM(BL_TRIANGLE));
	rb_hash_aset(h, ID2SYM(rb_intern("bl_sine")), INT2NUM(BL_SINE));
	rb_hash_aset(h, ID2SYM(rb_intern("bl_parabola")), INT2NUM(BL_PARABOLA));
	return h;
}

void Init_fast_plan(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_plan = rb_define_module_under(sound, "FastPlan");

	id_phase = rb_intern("@phase");
	id_blep = rb_intern("@blep");
	id_noise = rb_intern("@noise");
	id_jump_residual = rb_intern("@jump_residual");
	id_last_freq = rb_intern("@last_freq");
	id_last_width = rb_intern("@last_width");
	id_plan_reset = rb_intern("plan_reset");
	id_plan_residual_used = rb_intern("plan_residual_used");
	id_note = rb_intern("note");
	id_frequency = rb_intern("frequency");

	rb_define_module_function(fast_plan, "run", ruby_run, 8);
	rb_define_module_function(fast_plan, "enums", ruby_enums, 0);
}
