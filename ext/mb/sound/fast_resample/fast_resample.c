/*
 * Interface to libsamplerate for internal use by mb-sound.
 * (C)2025 Mike Bourgeous
 *
 * Extension references:
 * https://docs.ruby-lang.org/en/2.7.0/extension_rdoc.html
 * https://rubyreferences.github.io/rubyref/advanced/extensions.html
 */
#include <samplerate.h>

#include <ruby.h>

#include "numo/narray.h"

static VALUE fast_resample_class;
static VALUE src_state_class;

static ID sym_array_lookup;
static ID sym_array_assign;
static ID sym_zeros;

static void deinit_samplerate_state(void *state)
{
	if (state) {
		printf("Closing libsamplerate at %p\n", state); // XXX
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

static void grow_narray(VALUE self, long min_size)
{
	VALUE min_rb = LONG2NUM(min_size);
	VALUE buf = rb_iv_get(self, "@buf");
	if (buf == Qnil || rb_class_of(buf) != numo_cSFloat) {
		printf("Creating internal buffer with size %ld\n", min_size); // XXX
		rb_iv_set(self, "@buf", rb_funcall(numo_cSFloat, sym_zeros, 1, min_rb));
	} else {
		narray_t *na;
		GetNArray(buf, na);
		long bufsize = NA_SIZE(na);

		if (bufsize < min_size) {
			printf("Growing internal buffer from %ld to %ld\n", bufsize, min_size); // XXX

			VALUE newbuf = rb_funcall(numo_cSFloat, sym_zeros, 1, min_rb);
			VALUE assign_range = rb_range_new(INT2FIX(0), LONG2NUM(bufsize), 1);
			rb_funcall(newbuf, sym_array_assign, 2, assign_range, buf);

			rb_iv_set(self, "@buf", newbuf);
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

	VALUE buf = rb_iv_get(self, "@buf");

	VALUE state = rb_iv_get(self, "@state");
	SRC_STATE *src_state = TypedData_Get_Struct(state, SRC_STATE, &state_type_info, src_state);

	double ratio = NUM2DBL(rb_iv_get(self, "@ratio"));
	float *ptr = (float *)(nary_get_pointer_for_write(buf) + nary_get_offset(buf));

	long upstream_frames = lround(frames_requested / ratio);
	printf("Setting upstream frames_requested to %ld based on frames_requested=%ld and ratio=%f\n", upstream_frames, frames_requested, ratio); // XXX
	rb_iv_set(self, "@read_size", LONG2NUM(upstream_frames));

	long frames_read = src_callback_read(src_state, ratio, frames_requested, ptr);

	if (frames_read != frames_requested) {
		// FIXME: handle end-of-stream condition where less data is returned by returning a smaller block or Qnil
		rb_raise(rb_eIOError, "libsamplerate gave us %ld frames instead of the %ld we requested", frames_read, frames_requested);
	}

	VALUE ruby_frames = LONG2NUM(frames_read);
	VALUE result_range = rb_range_new(INT2FIX(0), ruby_frames, 1);
	return rb_funcall(buf, rb_intern("[]"), 1, result_range);
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
	VALUE block = rb_iv_get(self, "@callback");
	VALUE block_class = rb_class_of(block);
	if (block_class != rb_cProc) {
		rb_raise(rb_eTypeError, "Callback is %"PRIsVALUE", not a Proc", block_class);
	}
	
	VALUE samples_requested = rb_iv_get(self, "@read_size");
	printf("Reading %ld upstream samples for libsamplerate\n", NUM2LONG(samples_requested)); // XXX

	VALUE block_args = rb_ary_new_from_args(1, samples_requested);
	VALUE buf = rb_proc_call(block, block_args);

	if (buf == Qnil) {
		*audio = NULL;
		return 0;
	}

	*audio = (float *)(nary_get_pointer_for_read(buf) + nary_get_offset(buf));

	narray_t *na;
	GetNArray(buf, na);
	long samples_read = NA_SIZE(na);
	printf("Block gave us %ld samples\n", samples_read); // XXX

	return samples_read;
}

/**
 * Initializes a libsamplerate-based resampler with the given conversion
 * +ratio+ (output rate divided by input rate).
 */
static VALUE ruby_fast_resample_initialize(VALUE self, VALUE ratio)
{
	double r = NUM2DBL(ratio);

	if (r > 256.0) {
		rb_raise(rb_eArgError, "Sample rate ratio must be <= 256 (got %f)", r);
	} else if (r < 1.0 / 256.0) {
		rb_raise(rb_eArgError, "Sample rate ratio must be >= 1/256 (%f) (got %f)", 1.0 / 256.0, r);
	} else if (isnan(r)) {
		rb_raise(rb_eArgError, "Sample rate ratio must not be NaN");
	}

	rb_iv_set(self, "@ratio", DBL2NUM(r));
	rb_iv_set(self, "@read_size", INT2NUM(0));
	rb_iv_set(self, "@buf", Qnil);

	rb_need_block();
	rb_iv_set(self, "@callback", rb_block_proc());

	// TODO: Allow switching converter type
	int error = 0;
	SRC_STATE *src_state = src_callback_new(read_callback, SRC_SINC_BEST_QUALITY, 1, &error, (void *)self);

	if (src_state == NULL) {
		rb_raise(rb_eRuntimeError, "Error %d initializing libsamplerate: %s", error, src_strerror(error));
	}

	// TODO: Add size tracking for Ruby's GC
	VALUE state = TypedData_Wrap_Struct(src_state_class, &state_type_info, src_state);
	rb_iv_set(self, "@state", state);

	return self;
}

void Init_fast_resample(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	fast_resample_class = rb_define_class_under(sound, "FastResample", rb_cObject);

	src_state_class = rb_define_class_under(fast_resample_class, "SrcState", rb_cObject);
	rb_undef_alloc_func(src_state_class);

	rb_define_method(fast_resample_class, "initialize", ruby_fast_resample_initialize, 1);
	rb_define_method(fast_resample_class, "read", ruby_read, 1);

	// The ratio can be changed at runtime and libsamplerate will smoothly interpolate
	rb_attr(fast_resample_class, rb_intern("ratio"), 1, 1, 0);
	rb_attr(fast_resample_class, rb_intern("read_size"), 1, 1, 0);

	sym_zeros = rb_intern("zeros");
	sym_array_lookup = rb_intern("[]");
	sym_array_assign = rb_intern("[]=");

	VALUE converter_types = rb_hash_new();
	VALUE converter_descriptions = rb_hash_new();
	for (int index = 0; index < 1000000; index++) {
		const char *name = src_get_name(index);
		const char *desc = src_get_description(index);
		if (name == NULL || desc == NULL) {
			break;
		}

		VALUE converter_name = ID2SYM(rb_intern(name));
		rb_hash_aset(converter_types, converter_name, INT2FIX(index));
		rb_hash_aset(converter_descriptions, converter_name, rb_str_new_cstr(desc));
	}

	rb_define_const(fast_resample_class, "CONVERTER_IDS", converter_types);
	rb_define_const(fast_resample_class, "CONVERTER_DESCRIPTIONS", converter_descriptions);
}
