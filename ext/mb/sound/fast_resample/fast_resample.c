/*
 * Interface to libsamplerate for internal use by mb-sound.
 * (C)2025 Mike Bourgeous
 *
 * Extension references:
 * https://docs.ruby-lang.org/en/2.7.0/extension_rdoc.html
 * https://rubyreferences.github.io/rubyref/advanced/extensions.html
 * https://silverhammermba.github.io/emberb/c/
 */
#include <math.h>
#include <samplerate.h>

#include <ruby.h>

#include "numo/narray.h"

// Ruby objects are not kept in C static variables: the GC doesn't see them
// there unless registered, and could free a hash while Init_fast_resample
// was still filling it (an intermittent segfault on load).  Functions look up
// the class's constants instead (see class_const).  IDs are not GC-managed.
static ID sym_atbuf;
static ID sym_atratio;
static ID sym_atcallback;
static ID sym_atstate;
static ID sym_atread_size;
static ID sym_atview;
static ID sym_array_lookup;
static ID sym_array_assign;
static ID sym_zeros;

#define mbfr_debug(...) { \
	if (ruby_debug) { \
		rb_warn("%s: %d (%s)", __FILE__, __LINE__, __func__); \
		rb_warn(__VA_ARGS__); \
	} \
}

static void deinit_samplerate_state(void *state)
{
	if (state) {
		mbfr_debug("Closing libsamplerate at %p\n", state);
		SRC_STATE *src_state = state;
		src_delete(src_state);
	}
}

static const rb_data_type_t state_type_info = {
	.wrap_struct_name = "mb-sound-resample-SRC_STATE",
	.function = {
		.dfree = deinit_samplerate_state,
	},
};

/**
 * Creates the internal output buffer if it doesn't exist, grows it if it's
 * smaller than min_size.
 */
static void grow_narray(VALUE self, long min_size)
{
	VALUE min_rb = LONG2NUM(min_size);
	VALUE buf = rb_ivar_get(self, sym_atbuf);
	if (buf == Qnil || rb_class_of(buf) != numo_cSFloat) {
		mbfr_debug("Creating internal buffer with size %ld\n", min_size);
		rb_ivar_set(self, sym_atbuf, rb_funcall(numo_cSFloat, sym_zeros, 1, min_rb));
	} else {
		narray_t *na;
		GetNArray(buf, na);
		long bufsize = NA_SIZE(na);

		if (bufsize < min_size) {
			mbfr_debug("Growing internal buffer from %ld to %ld\n", bufsize, min_size);

			VALUE newbuf = rb_funcall(numo_cSFloat, sym_zeros, 1, min_rb);
			VALUE assign_range = rb_range_new(INT2FIX(0), LONG2NUM(bufsize), 1);
			rb_funcall(newbuf, sym_array_assign, 2, assign_range, buf);

			rb_ivar_set(self, sym_atbuf, newbuf);
		}
	}
}

/**
 * Reads +count+ frames in the new sample rate, writing into the given
 * Numo::SFloat +narray+.  The given block will be called zero or more times
 * with a number of samples to read from the upstream.
 *
 * Returns the internal buffer, or a subset view thereof.
 */
static VALUE ruby_read(VALUE self, VALUE count)
{
	long frames_requested = NUM2LONG(count);
	grow_narray(self, frames_requested);

	VALUE buf = rb_ivar_get(self, sym_atbuf);

	VALUE state = rb_ivar_get(self, sym_atstate);
	SRC_STATE *src_state = TypedData_Get_Struct(state, SRC_STATE, &state_type_info, src_state);

	double ratio = NUM2DBL(rb_ivar_get(self, sym_atratio));
	float *ptr = (float *)(nary_get_pointer_for_write(buf) + nary_get_offset(buf));

	long upstream_frames = lround(frames_requested / ratio);
	if (upstream_frames < 2) {
		upstream_frames = 2;
	}
	mbfr_debug("Setting upstream frames_requested to %ld based on frames_requested=%ld and ratio=%f\n", upstream_frames, frames_requested, ratio);
	rb_ivar_set(self, sym_atread_size, LONG2NUM(upstream_frames));

	long frames_read = src_callback_read(src_state, ratio, frames_requested, ptr);

	if (frames_read == 0) {
		return Qnil;
	} else if (frames_read > frames_requested) {
		rb_raise(rb_eIOError, "libsamplerate gave us %ld frames instead of the %ld we requested", frames_read, frames_requested);
	}

	// The whole buffer, or a view of its start, kept for the next read of
	// the same length (so steady reads allocate nothing)
	if ((size_t)frames_read == RNARRAY_SIZE(buf)) {
		return buf;
	}

	VALUE view = rb_ivar_get(self, sym_atview);
	if (!NIL_P(view) && RNARRAY_TYPE(view) == NARRAY_VIEW_T && RNARRAY_VIEW(view)->data == buf &&
			RNARRAY_SIZE(view) == (size_t)frames_read) {
		return view;
	}

	VALUE ruby_frames = LONG2NUM(frames_read);
	VALUE result_range = rb_range_new(INT2FIX(0), ruby_frames, 1);
	view = rb_funcall(buf, sym_array_lookup, 1, result_range);
	rb_ivar_set(self, sym_atview, view);
	return view;
}

/**
 * Called by libsamplerate to read data for conversion within ruby_sample().
 *
 * ----
 *
 * libsamplerate doesn't tell us anything about how much data it needs -- it
 * just keeps asking until it either has enough to satisfy the read request, or
 * we return a count of zero.
 *
 * So we can either try to calculate a ratio and return that amount here, or we
 * can use a small size and let libsamplerate read repeatedly.  Which is best
 * depends on the upstream graph and the app's performance and latency
 * requirements.
 *
 * For the initial implementation I will use the former approach, passing the
 * upstream read callback in @block and the upstream read count in @read_size.
 *
 * Libsamplerate treats an upstream result size of 0 as end of stream.
 */
static long read_callback(void *data, float **audio)
{
	VALUE self = (VALUE)data;
	VALUE block = rb_ivar_get(self, sym_atcallback);
	VALUE block_class = rb_class_of(block);
	if (block_class != rb_cProc) {
		rb_raise(rb_eTypeError, "Callback is %"PRIsVALUE", not a Proc", block_class);
	}

	VALUE samples_requested = rb_ivar_get(self, sym_atread_size);
	mbfr_debug("Reading %ld upstream samples for libsamplerate\n", NUM2LONG(samples_requested));

	VALUE buf = rb_proc_call_with_block(block, 1, &samples_requested, Qnil);

	if (buf == Qnil) {
		*audio = NULL;
		return 0;
	}

	VALUE buf_class = rb_class_of(buf);
	if (buf_class != numo_cSFloat) {
		rb_raise(rb_eTypeError, "Data from read callback is %"PRIsVALUE", not Numo::SFloat", buf_class);
	}

	*audio = (float *)(nary_get_pointer_for_read(buf) + nary_get_offset(buf));

	narray_t *na;
	GetNArray(buf, na);
	long samples_read = NA_SIZE(na);
	mbfr_debug("Block gave us %ld samples\n", samples_read);

	return samples_read;
}

// Returns the constant +name+ from the class of +self+ (e.g. CONVERTER_IDS or
// SrcState, defined by Init_fast_resample).  Only used while setting up a
// resampler, not per sample.
static VALUE class_const(VALUE self, const char *name)
{
	return rb_const_get(rb_obj_class(self), rb_intern(name));
}

// mode can either be one of the libsamplerate keys from
// MB::Sound::GraphNode::Resample::MODES, or one of the resampler names (as a
// String or Symbol) provided by libsamplerate at runtime.
static VALUE ruby_lookup_converter(VALUE self, VALUE mode)
{
	VALUE libsamplerate_best = ID2SYM(rb_intern("libsamplerate_best"));
	VALUE libsamplerate_fastest = ID2SYM(rb_intern("libsamplerate_fastest"));
	VALUE libsamplerate_linear = ID2SYM(rb_intern("libsamplerate_linear"));
	VALUE libsamplerate_zoh = ID2SYM(rb_intern("libsamplerate_zoh"));

	mbfr_debug("Looking up converter %+"PRIsVALUE, mode);

	// Convert String to Symbol if needed
	if (RB_TYPE_P(mode, T_STRING)) {
		mbfr_debug("Converting string to symbol");
		mode = ID2SYM(rb_intern_str(mode));
	}

	// Look up integer mode IDs
	if (RB_TYPE_P(mode, T_FIXNUM)) {
		mbfr_debug("Looking up integer ID");
		VALUE mode_name = rb_hash_aref(class_const(self, "CONVERTER_NAMES"), mode);
		if (NIL_P(mode_name)) {
			rb_raise(rb_eArgError, "Unsupported mode ID %+"PRIsVALUE, mode);
		}
		mode = mode_name;
	}

	if (mode == libsamplerate_best) {
		return INT2FIX(SRC_SINC_BEST_QUALITY);
	}
	if (mode == libsamplerate_fastest) {
		return INT2FIX(SRC_SINC_FASTEST);
	}
	if (mode == libsamplerate_linear) {
		return INT2FIX(SRC_LINEAR);
	}
	if (mode == libsamplerate_zoh) {
		return INT2FIX(SRC_ZERO_ORDER_HOLD);
	}

	VALUE mapped_mode = rb_hash_aref(class_const(self, "CONVERTER_IDS"), mode);
	if (NIL_P(mapped_mode)) {
		rb_raise(rb_eArgError, "Unsupported converter mode %+"PRIsVALUE, mode);
	}

	return mapped_mode;
}

// This is a separate Ruby function so that rb_hash_fetch does not get the block
// passed to the constructor.  Prior to this change, rb_hash_fetch was calling
// the read method supplied to the constructor (which expects an integer number
// of samples) with the name of the samplerate converter mode.
static VALUE ruby_setup_converter_type(VALUE self, VALUE mode)
{
	VALUE converter_id = rb_funcall(self, rb_intern("lookup_converter"), 1, mode);
	VALUE converter_name = rb_hash_fetch(class_const(self, "CONVERTER_NAMES"), converter_id);
	VALUE converter_desc = rb_hash_fetch(class_const(self, "CONVERTER_DESCRIPTIONS"), converter_name);
	rb_iv_set(self, "@mode_id", converter_id);
	rb_iv_set(self, "@mode_name", converter_name);
	rb_iv_set(self, "@mode_description", converter_desc);

	return Qnil;
}

/**
 * Initializes a libsamplerate-based resampler with the given conversion
 * +ratio+ (output rate divided by input rate).
 */
static VALUE ruby_fast_resample_initialize(int argc, VALUE *argv, VALUE self)
{
	VALUE ratio, mode, callback;

	mbfr_debug("Starting resampler initialization with %d arguments", argc);

	rb_need_block();
	if (rb_scan_args(argc, argv, "11&", &ratio, &mode, &callback) < 1) {
		rb_raise(rb_eArgError, "Too few arguments to constructor");
	}

	mbfr_debug("Ratio is %+"PRIsVALUE", mode is %+"PRIsVALUE", callback is %+"PRIsVALUE, ratio, mode, callback);

	if (NIL_P(mode)) {
		mode = ID2SYM(rb_intern("libsamplerate_best"));
	}

	double r = NUM2DBL(ratio);
	if (r > 256.0) {
		rb_raise(rb_eArgError, "Sample rate ratio must be <= 256 (got %f)", r);
	} else if (r < 1.0 / 256.0) {
		rb_raise(rb_eArgError, "Sample rate ratio must be >= 1/256 (%f) (got %f)", 1.0 / 256.0, r);
	} else if (isnan(r)) {
		rb_raise(rb_eArgError, "Sample rate ratio must not be NaN");
	}

	rb_ivar_set(self, sym_atratio, DBL2NUM(r));
	rb_ivar_set(self, sym_atread_size, INT2NUM(0));
	rb_ivar_set(self, sym_atbuf, Qnil);
	rb_ivar_set(self, sym_atview, Qnil);
	rb_ivar_set(self, sym_atcallback, callback);

	rb_funcall(self, rb_intern("setup_converter_type"), 1, mode);

	mbfr_debug("Creating libsamplerate handle");
	int error = 0;
	SRC_STATE *src_state = src_callback_new(read_callback, FIX2INT(rb_iv_get(self, "@mode_id")), 1, &error, (void *)self);
	if (src_state == NULL) {
		rb_raise(rb_eRuntimeError, "Error %d initializing libsamplerate: %s", error, src_strerror(error));
	}

	// TODO: Add size tracking for Ruby's GC
	VALUE state = TypedData_Wrap_Struct(class_const(self, "SrcState"), &state_type_info, src_state);
	rb_ivar_set(self, sym_atstate, state);

	mbfr_debug("Initialization complete");

	return self;
}

/*
 * call-seq:
 *   MB::Sound::FastResample.min_phase(out, input, table, phases, taps, scale, start, num, den, base) -> out
 *
 * A causal (minimum-phase) polyphase resampler step (GraphNode::Resample's
 * :min_phase mode; exact Ruby mirror Resample::MinPhase.run_ruby).  Output
 * frame k is output frame start + k of the stream, at input position
 * t = (start + k) * num / den (num / den input frames per output frame,
 * exactly, so positions don't depend on how the stream is split into
 * reads); +input+ (a contiguous Numo::SFloat) holds input frames from
 * frame +base+ on.  Each output is the sum over taps j of
 * input[floor(t) - j] times the prototype +table+ (a contiguous Numo::DFloat
 * of phases * taps + 1 values: the minimum-phase lowpass sampled +phases+
 * times per input frame, then a 0) at ((t - floor(t)) + j) * scale *
 * phases, interpolated linearly, times +scale+ (1 when upsampling, the
 * output/input ratio when downsampling, which stretches the filter to the
 * lower cutoff).  So it reads no input past floor(t): no lookahead.
 * Raises if a tap would read before +base+ or past the input.
 */
static VALUE ruby_min_phase(VALUE self, VALUE out, VALUE input, VALUE table, VALUE phases, VALUE taps, VALUE scale, VALUE start, VALUE num, VALUE den, VALUE base)
{
	if (CLASS_OF(out) != numo_cSFloat || RNARRAY_NDIM(out) != 1 || !RTEST(nary_check_contiguous(out))) {
		rb_raise(rb_eArgError, "Output must be a contiguous 1D Numo::SFloat");
	}
	if (CLASS_OF(input) != numo_cSFloat || RNARRAY_NDIM(input) != 1 || !RTEST(nary_check_contiguous(input))) {
		rb_raise(rb_eArgError, "Input must be a contiguous 1D Numo::SFloat");
	}
	if (CLASS_OF(table) != numo_cDFloat || RNARRAY_NDIM(table) != 1 || !RTEST(nary_check_contiguous(table))) {
		rb_raise(rb_eArgError, "Table must be a contiguous 1D Numo::DFloat");
	}

	long n_out = (long)RNARRAY_SHAPE(out)[0];
	long n_in = (long)RNARRAY_SHAPE(input)[0];
	long n_table = (long)RNARRAY_SHAPE(table)[0];
	long ph = NUM2LONG(phases);
	long tp = NUM2LONG(taps);
	double sc = NUM2DBL(scale);
	long long st0 = NUM2LL(start);
	long long nu = NUM2LL(num);
	long long de = NUM2LL(den);
	long long b0 = NUM2LL(base);

	if (ph < 1 || tp < 1 || n_table != ph * tp + 1) {
		rb_raise(rb_eArgError, "Table must have phases * taps + 1 values (got %ld for %ld * %ld)", n_table, ph, tp);
	}
	if (!(sc > 0 && sc <= 1) || nu < 1 || de < 1 || st0 < 0) {
		rb_raise(rb_eArgError, "Scale must be in (0, 1], num and den positive, and start non-negative");
	}

	// Taps reached at this scale (the stretched filter's length in input frames)
	long reach = (long)ceil(tp / sc);
	long limit = ph * tp; // table index past the last coefficient

	if (n_out > 0) {
		long long first = st0 * nu / de - b0;
		long long last = (st0 + n_out - 1) * nu / de - b0;
		if (first - (reach - 1) < 0) {
			rb_raise(rb_eArgError, "Input needs %ld frames of history before frame %lld", reach - 1, first + b0);
		}
		if (last >= n_in) {
			rb_raise(rb_eArgError, "Input frame %lld is past the %ld-frame input from frame %lld", last + b0, n_in, b0);
		}
	}

	const float *x = (const float *)(nary_get_pointer_for_read(input) + nary_get_offset(input));
	const double *h = (const double *)(nary_get_pointer_for_read(table) + nary_get_offset(table));
	float *y = (float *)(nary_get_pointer_for_write(out) + nary_get_offset(out));
	double sp = sc * (double)ph;

	// Coefficient sets for the first MP_SLOTS fractional positions seen
	// (integer and small rational ratios repeat a few: 2x up uses 0 and
	// 0.5, 2x down only 0), each computed as below, so the sums are the
	// same as computing every tap's coefficient in place
	enum { MP_SLOTS = 8 };
	double *coefs = ALLOC_N(double, (size_t)reach * (MP_SLOTS + 1));
	long long keys[MP_SLOTS];
	long lens[MP_SLOTS + 1];
	int used = 0;

	for (long k = 0; k < n_out; k++) {
		long long a = (st0 + k) * nu;
		long n = (long)(a / de - b0);
		long long rem = a % de;

		int slot = -1;
		for (int s = 0; s < used; s++) {
			if (keys[s] == rem) {
				slot = s;
				break;
			}
		}
		if (slot < 0) {
			slot = used < MP_SLOTS ? used++ : MP_SLOTS; // (the last set is scratch once the slots fill)
			if (slot < MP_SLOTS) {
				keys[slot] = rem;
			}
			double f = (double)rem / (double)de;
			double *c = coefs + (size_t)slot * (size_t)reach;
			long len = 0;
			for (long j = 0; j < reach; j++) {
				double tau = (f + (double)j) * sp;
				long i = (long)tau;
				if (i >= limit) {
					break;
				}
				c[j] = h[i] + (tau - (double)i) * (h[i + 1] - h[i]);
				len = j + 1;
			}
			lens[slot] = len;
		}

		const double *c = coefs + (size_t)slot * (size_t)reach;
		long len = lens[slot];
		const float *xn = x + n;
		double acc = 0.0;
		for (long j = 0; j < len; j++) {
			acc += (double)xn[-j] * c[j];
		}
		y[k] = (float)(acc * sc);
	}

	xfree(coefs);

	RB_GC_GUARD(out);
	RB_GC_GUARD(input);
	RB_GC_GUARD(table);

	return out;
}

void Init_fast_resample(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_resample_class = rb_define_class_under(sound, "FastResample", rb_cObject);

	VALUE src_state_class = rb_define_class_under(fast_resample_class, "SrcState", rb_cObject);
	rb_undef_alloc_func(src_state_class);

	rb_define_method(fast_resample_class, "initialize", ruby_fast_resample_initialize, -1);
	rb_define_method(fast_resample_class, "read", ruby_read, 1);
	rb_define_singleton_method(fast_resample_class, "min_phase", ruby_min_phase, 10);

	rb_define_private_method(fast_resample_class, "lookup_converter", ruby_lookup_converter, 1);
	rb_define_private_method(fast_resample_class, "setup_converter_type", ruby_setup_converter_type, 1);

	// The ratio can be changed at runtime and libsamplerate will smoothly interpolate
	rb_attr(fast_resample_class, rb_intern("ratio"), 1, 1, 0);
	rb_attr(fast_resample_class, rb_intern("mode_name"), 1, 0, 0);
	rb_attr(fast_resample_class, rb_intern("mode_id"), 1, 0, 0);
	rb_attr(fast_resample_class, rb_intern("mode_description"), 1, 0, 0);

	sym_atbuf = rb_intern("@buf");
	sym_atratio = rb_intern("@ratio");
	sym_atcallback = rb_intern("@callback");
	sym_atstate = rb_intern("@state");
	sym_atread_size = rb_intern("@read_size");
	sym_atview = rb_intern("@view");
	sym_zeros = rb_intern("zeros");
	sym_array_lookup = rb_intern("[]");
	sym_array_assign = rb_intern("[]=");

	// Locals, so the GC sees them on the C stack while they are filled
	VALUE converter_ids = rb_hash_new();
	VALUE converter_descriptions = rb_hash_new();
	for (int index = 0; index < 1000000; index++) {
		const char *name = src_get_name(index);
		const char *desc = src_get_description(index);
		if (name == NULL || desc == NULL) {
			break;
		}

		VALUE converter_name = ID2SYM(rb_intern(name));
		rb_hash_aset(converter_ids, converter_name, INT2FIX(index));
		rb_hash_aset(converter_descriptions, converter_name, rb_str_new_cstr(desc));
	}

	VALUE converter_names = rb_funcall(converter_ids, rb_intern("invert"), 0);

	rb_define_const(fast_resample_class, "CONVERTER_IDS", rb_hash_freeze(converter_ids));
	rb_define_const(fast_resample_class, "CONVERTER_NAMES", rb_hash_freeze(converter_names));
	rb_define_const(fast_resample_class, "CONVERTER_DESCRIPTIONS", rb_hash_freeze(converter_descriptions));
}
