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

/*
 * Reads +count+ frames in the new sample rate, writing into the given
 * Numo::SFloat.
 */
static VALUE ruby_sample(VALUE self, VALUE narray, VALUE count)
{
	VALUE ntype = CLASS_OF(narray);
	if (ntype != numo_cSFloat) {
		rb_raise(rb_eArgError, "Expected Numo::SFloat, got %"PRIsVALUE, ntype);
	}

	if (!TEST_INPLACE(narray)) {
		rb_raise(rb_eArgError, "Can only read into an in-place Numo::SFloat instance (call #inplace or #inplace! first)");
	}

	if (!RTEST(nary_check_contiguous(narray))) {
		rb_raise(rb_eArgError, "Can only read into a contiguous Numo::SFloat instance");
	}

	VALUE state = rb_iv_get(self, "@state");
	SRC_STATE *src_state = TypedData_Get_Struct(state, SRC_STATE, &state_type_info, src_state);
	double ratio = NUM2DBL(rb_iv_get(self, "@ratio"));
	long frames_requested = NUM2LONG(count);
	float *ptr = (float *)(nary_get_pointer_for_write(narray) + nary_get_offset(narray));

	long upstream_frames = lround(frames_requested / ratio);
	printf("Setting upstream frames_requested to %ld based on frames_requested=%ld and ratio=%f\n", upstream_frames, frames_requested, ratio);
	rb_iv_set(self, "@read_size", LONG2NUM(upstream_frames));

	long frames_read = src_callback_read(src_state, ratio, frames_requested, ptr);

	if (frames_read != frames_requested) {
		// FIXME: handle end-of-stream condition where less data is returned
		rb_raise(rb_eIOError, "libsamplerate gave us %ld frames instead of the %ld we requested", frames_read, frames_requested);
	}

	VALUE ruby_frames = LONG2NUM(frames_read);
	VALUE result_range = rb_range_new(INT2FIX(0), ruby_frames, 1);
	return rb_funcall(narray, rb_intern("[]"), 1, result_range);
}

/*
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
 * For the initial implementation I will use the former approach.
 */
static long read_callback(void *data, float **audio)
{
	VALUE self = (VALUE)data;
	
	VALUE buf = rb_iv_get(self, "@buf");
	*audio = (float *)(nary_get_pointer_for_read(buf) + nary_get_offset(buf));

	long samples_read = NUM2LONG(rb_iv_get(self, "@read_size"));

	printf("Reading %ld upstream samples for libsamplerate\n", samples_read); // XXX

	return samples_read;
}

/*
 * Initializes a libsamplerate-based resampler with the given conversion
 * +ratio+ (output rate divided by input rate).
 */
static VALUE ruby_fast_resample_init(VALUE self, VALUE ratio)
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
	rb_iv_set(self, "@buf", rb_funcall(numo_cSFloat, rb_intern("zeros"), 1, INT2NUM(48000)));

	// TODO: Allow switching converter type
	int error = 0;
	SRC_STATE *src_state = src_callback_new(read_callback, SRC_SINC_BEST_QUALITY, 1, &error, (void *)self);

	if (src_state == NULL) {
		rb_raise(rb_eRuntimeError, "Error %d initializing libsamplerate: %s", error, src_strerror(error));
	}

	VALUE state = TypedData_Wrap_Struct(src_state_class, &state_type_info, src_state);
	rb_iv_set(self, "@state", state);

	return self;
}

void Init_fast_resample(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	fast_resample_class = rb_define_class_under(sound, "FastResample", rb_cObject);

	src_state_class = rb_define_class_under(fast_resample_class, "SrcState", rb_cBasicObject);
	rb_undef_alloc_func(src_state_class);

	rb_define_method(fast_resample_class, "initialize", ruby_fast_resample_init, 1);
	rb_define_method(fast_resample_class, "sample", ruby_sample, 2);

	rb_attr(fast_resample_class, rb_intern("ratio"), 1, 0, 0);
	rb_attr(fast_resample_class, rb_intern("read_size"), 1, 1, 0);
}
