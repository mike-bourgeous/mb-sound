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

static VALUE resample_class;
static VALUE src_data_class;
static VALUE src_state_class;

/*
 * Initializes a libsamplerate-based resampler with the given conversion
 * +ratio+ (output rate divided by input rate).
 */
static VALUE ruby_resample_init(VALUE self, VALUE ratio)
{
	float r = NUM2DBL(ratio);

	// TODO

	return DBL2NUM(r);
}

void Init_resample(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	resample_class = rb_define_class_under(sound, "Resample", rb_cObject);
	src_data_class = rb_define_class_under(resample_class, "Data", rb_cBasicObject);
	src_state_class = rb_define_class_under(resample_class, "State", rb_cBasicObject);

	rb_define_method(resample_class, "initialize", ruby_resample_init, 1);
}
