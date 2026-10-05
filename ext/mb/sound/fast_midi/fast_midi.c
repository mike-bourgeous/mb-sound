/*
 * MIDI input and output through RtMidi (https://github.com/thestk/rtmidi,
 * vendored 6.0.0, MIT-style license in RtMidi-LICENSE; see README.md for
 * updating it) for MB::Sound::MIDI::Input and MIDI::Output:
 * CoreMIDI on macOS, the ALSA sequencer and JACK MIDI on Linux.
 *
 * RtMidi's own thread queues incoming messages, and Ruby polls the queue
 * (rtmidi_in_get_message) once per audio buffer, so no Ruby code runs on
 * a MIDI thread.  Every RtMidi call goes through its C API, which catches
 * C++ exceptions and clears the ok field; those are raised here as
 * FastMIDI::Error.  The C API's msg field points into the destroyed
 * exception, so it is never read; RtMidi prints the details to stderr.
 *
 * (C)2026 Mike Bourgeous
 */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <ruby.h>

#include "rtmidi_c.h"


// The longest message (e.g. SysEx) read at once
#define MAX_MESSAGE 65536

// The most messages one #read returns
#define MAX_MESSAGES 4096

static VALUE cError;

static VALUE api_to_sym(enum RtMidiApi api)
{
	const char *name = rtmidi_api_name(api);
	return name ? ID2SYM(rb_intern(name)) : Qnil;
}

// A Symbol or String API name (:core, :alsa, :jack) or nil for RtMidi's
// choice.
static enum RtMidiApi sym_to_api(VALUE api)
{
	if (NIL_P(api)) {
		return RTMIDI_API_UNSPECIFIED;
	}

	VALUE name = rb_funcall(api, rb_intern("to_s"), 0);
	enum RtMidiApi result = rtmidi_compiled_api_by_name(StringValueCStr(name));
	if (result == RTMIDI_API_UNSPECIFIED) {
		rb_raise(rb_eArgError, "MIDI API %s is not compiled in (see FastMIDI.compiled_apis)", StringValueCStr(name));
	}

	return result;
}

// Raises FastMIDI::Error with +what+ if the last RtMidi call failed.
static void check(RtMidiPtr device, const char *what)
{
	if (device == NULL) {
		rb_raise(cError, "%s failed", what);
	}
	if (!device->ok) {
		rb_raise(cError, "%s failed (see RtMidi's message above)", what);
	}
}

// Frees +device+ (an input if +input+, else an output) and raises
// FastMIDI::Error saying +what+ failed.
NORETURN(static void fail(RtMidiPtr device, int input, const char *what));
static void fail(RtMidiPtr device, int input, const char *what)
{
	if (device != NULL) {
		if (input) {
			rtmidi_in_free(device);
		} else {
			rtmidi_out_free(device);
		}
	}
	rb_raise(cError, "%s failed (see RtMidi's message above)", what);
}

// Returns an Array of the port names of +device+.
static VALUE port_names(RtMidiPtr device)
{
	unsigned int count = rtmidi_get_port_count(device);
	check(device, "Listing MIDI ports");

	VALUE names = rb_ary_new_capa(count);
	for (unsigned int i = 0; i < count; i++) {
		int length = 0;
		rtmidi_get_port_name(device, i, NULL, &length);
		if (length <= 0) {
			rb_ary_push(names, rb_utf8_str_new_cstr(""));
			continue;
		}

		char *buf = ALLOCA_N(char, length + 1);
		rtmidi_get_port_name(device, i, buf, &length);
		buf[length < 0 ? 0 : length] = 0;
		rb_ary_push(names, rb_utf8_str_new_cstr(buf));
	}

	return names;
}

// port_names for rb_protect, which passes a VALUE.
static VALUE protected_port_names(VALUE device)
{
	return port_names((RtMidiPtr)device);
}

/*
 * call-seq:
 *   MB::Sound::FastMIDI.compiled_apis -> [:alsa, :jack]
 *
 * The MIDI APIs this build supports, in RtMidi's order of preference.
 */
static VALUE ruby_compiled_apis(VALUE self)
{
	enum RtMidiApi apis[RTMIDI_API_NUM];
	int count = rtmidi_get_compiled_api(apis, RTMIDI_API_NUM);

	VALUE list = rb_ary_new();
	for (int i = 0; i < count; i++) {
		rb_ary_push(list, api_to_sym(apis[i]));
	}

	return list;
}

/*
 * call-seq:
 *   MB::Sound::FastMIDI.input_ports(api, client_name) -> [name, ...]
 *
 * Lists the MIDI input ports (sources) +api+ (a Symbol, or nil for
 * RtMidi's choice) can open.  Raises FastMIDI::Error if the API can't
 * start (e.g. :jack without a running JACK server).
 */
static VALUE ruby_input_ports(VALUE self, VALUE api, VALUE client_name)
{
	RtMidiInPtr device = rtmidi_in_create(sym_to_api(api), StringValueCStr(client_name), 100);
	if (device == NULL || !device->ok) {
		fail(device, 1, "Starting MIDI input");
	}

	int state;
	VALUE names = rb_protect(protected_port_names, (VALUE)device, &state);
	rtmidi_in_free(device);
	if (state) {
		rb_jump_tag(state);
	}

	return names;
}


/* Input -------------------------------------------------------------------- */

struct midi_input {
	RtMidiInPtr device;
	pid_t pid;
	unsigned char *buf;
};

static void input_release(struct midi_input *in)
{
	// A forked child has no RtMidi thread to stop; leave the copy alone.
	if (in->device != NULL && in->pid == getpid()) {
		rtmidi_close_port(in->device);
		rtmidi_in_free(in->device);
	}
	in->device = NULL;
}

static void input_free(void *ptr)
{
	struct midi_input *in = ptr;
	input_release(in);
	free(in->buf);
	free(in);
}

static const rb_data_type_t input_type = {
	.wrap_struct_name = "MB::Sound::FastMIDI::Input",
	.function = {
		.dmark = NULL,
		.dfree = input_free,
		.dsize = NULL,
	},
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE input_alloc(VALUE klass)
{
	struct midi_input *in = calloc(1, sizeof(struct midi_input));
	if (in == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate MIDI input");
	}
	in->pid = getpid();
	return TypedData_Wrap_Struct(klass, &input_type, in);
}

static struct midi_input *get_input(VALUE self)
{
	struct midi_input *in;
	TypedData_Get_Struct(self, struct midi_input, &input_type, in);
	if (in->pid != getpid()) {
		rb_raise(rb_eIOError, "This MIDI input was opened by another process (pid %d)", (int)in->pid);
	}
	if (in->device == NULL) {
		rb_raise(rb_eIOError, "This MIDI input is closed");
	}
	return in;
}

/*
 * call-seq:
 *   Input.new(api, client_name, port_index, port_name, queue_size)
 *
 * Opens MIDI input through +api+ (a Symbol, or nil for RtMidi's choice)
 * as client +client_name+.  With an Integer +port_index+ (see
 * FastMIDI.input_ports), connects to that source and names our port
 * +port_name+; with nil, creates a virtual port named +port_name+ that
 * other programs (DAWs, connection managers) connect to.  +queue_size+
 * messages are buffered between #read calls.  SysEx is received; MIDI
 * clock and active sensing are ignored.
 */
static VALUE input_initialize(VALUE self, VALUE api, VALUE client_name, VALUE port_index, VALUE port_name, VALUE queue_size)
{
	struct midi_input *in;
	TypedData_Get_Struct(self, struct midi_input, &input_type, in);
	if (in->device != NULL) {
		rb_raise(cError, "MIDI input is already open");
	}

	in->buf = malloc(MAX_MESSAGE);
	if (in->buf == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate the MIDI message buffer");
	}

	unsigned int queue = NUM2UINT(queue_size);
	if (queue < 1) {
		rb_raise(rb_eArgError, "Queue size must be positive");
	}

	RtMidiInPtr device = rtmidi_in_create(sym_to_api(api), StringValueCStr(client_name), queue);
	if (device == NULL || !device->ok) {
		fail(device, 1, "Starting MIDI input");
	}
	in->device = device;

	if (NIL_P(port_index)) {
		rtmidi_open_virtual_port(device, StringValueCStr(port_name));
	} else {
		rtmidi_open_port(device, NUM2UINT(port_index), StringValueCStr(port_name));
	}
	if (!device->ok) {
		input_release(in);
		rb_raise(cError, "Opening the MIDI input port failed (see RtMidi's message above)");
	}

	rtmidi_in_ignore_types(device, false, true, true);

	RB_GC_GUARD(client_name);
	RB_GC_GUARD(port_name);

	return self;
}

/*
 * call-seq:
 *   input.read -> [[delta_seconds, bytes], ...]
 *
 * Returns the messages received since the last read (without waiting; an
 * empty Array if none), each with the seconds since the previous message
 * and its bytes as a binary String.
 */
static VALUE input_read(VALUE self)
{
	struct midi_input *in = get_input(self);
	VALUE messages = rb_ary_new();

	for (int i = 0; i < MAX_MESSAGES; i++) {
		size_t size = MAX_MESSAGE;
		double delta = rtmidi_in_get_message(in->device, in->buf, &size);
		check(in->device, "Reading MIDI");
		if (size == 0) {
			break;
		}

		rb_ary_push(messages, rb_ary_new_from_args(2, DBL2NUM(delta), rb_str_new((const char *)in->buf, size)));
	}

	return messages;
}

/* The MIDI API in use, as a Symbol (:core, :alsa, :jack). */
static VALUE input_api(VALUE self)
{
	return api_to_sym(rtmidi_in_get_current_api(get_input(self)->device));
}

/* The MIDI sources this input's API could connect to (see FastMIDI.input_ports). */
static VALUE input_ports(VALUE self)
{
	return port_names(get_input(self)->device);
}

/* Closes the port and stops RtMidi's thread.  Safe to call more than once. */
static VALUE input_close(VALUE self)
{
	struct midi_input *in;
	TypedData_Get_Struct(self, struct midi_input, &input_type, in);
	input_release(in);
	return Qnil;
}

static VALUE input_closed(VALUE self)
{
	struct midi_input *in;
	TypedData_Get_Struct(self, struct midi_input, &input_type, in);
	return in->device == NULL ? Qtrue : Qfalse;
}


/* Test output ---------------------------------------------------------------- */

// A minimal MIDI output (MB::Sound::MIDI::Output): sends raw messages to a
// virtual port or a connected destination.  A fuller MIDI output (clocks,
// scheduling) is part of a later sequence/MIDI/synth overhaul.

static void output_free(void *ptr)
{
	RtMidiOutPtr device = ptr;
	if (device != NULL) {
		rtmidi_close_port(device);
		rtmidi_out_free(device);
	}
}

static const rb_data_type_t output_type = {
	.wrap_struct_name = "MB::Sound::FastMIDI::Output",
	.function = {
		.dmark = NULL,
		.dfree = output_free,
		.dsize = NULL,
	},
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static RtMidiOutPtr get_output(VALUE self)
{
	RtMidiOutPtr device;
	TypedData_Get_Struct(self, struct RtMidiWrapper, &output_type, device);
	if (device == NULL) {
		rb_raise(rb_eIOError, "This MIDI output is closed");
	}
	return device;
}

/*
 * call-seq:
 *   MB::Sound::FastMIDI.output_ports(api, client_name) -> [name, ...]
 *
 * Lists the MIDI destinations +api+ (a Symbol, or nil for RtMidi's choice)
 * can send to.
 */
static VALUE ruby_output_ports(VALUE self, VALUE api, VALUE client_name)
{
	RtMidiOutPtr device = rtmidi_out_create(sym_to_api(api), StringValueCStr(client_name));
	if (device == NULL || !device->ok) {
		fail(device, 0, "Starting MIDI output");
	}

	int state;
	VALUE names = rb_protect(protected_port_names, (VALUE)device, &state);
	rtmidi_out_free(device);
	if (state) {
		rb_jump_tag(state);
	}

	return names;
}

/*
 * call-seq:
 *   Output.new(api, client_name, port_index, port_name) -> output
 *
 * Opens MIDI output through +api+ as client +client_name+: connected to
 * destination +port_index+ (see FastMIDI.output_ports) with our port named
 * +port_name+, or with nil, a virtual source named +port_name+ that other
 * programs connect to.
 */
static VALUE output_new(VALUE klass, VALUE api, VALUE client_name, VALUE port_index, VALUE port_name)
{
	RtMidiOutPtr device = rtmidi_out_create(sym_to_api(api), StringValueCStr(client_name));
	if (device == NULL || !device->ok) {
		fail(device, 0, "Starting MIDI output");
	}

	VALUE self = TypedData_Wrap_Struct(klass, &output_type, device);

	if (NIL_P(port_index)) {
		rtmidi_open_virtual_port(device, StringValueCStr(port_name));
	} else {
		rtmidi_open_port(device, NUM2UINT(port_index), StringValueCStr(port_name));
	}
	if (!device->ok) {
		// Close RtMidi's client now (e.g. a JACK client that connected
		// before the port failed) rather than when GC frees the object, by
		// which time its server may be gone (a JACK client closed after its
		// server stopped crashed libjack's threads)
		DATA_PTR(self) = NULL;
		output_free(device);
		rb_raise(cError, "Opening the MIDI output port failed (see RtMidi's message above)");
	}

	return self;
}

/*
 * call-seq:
 *   output.close -> nil
 *
 * Closes the port and frees the client.  Safe to call more than once.
 */
static VALUE output_close(VALUE self)
{
	RtMidiOutPtr device;
	TypedData_Get_Struct(self, struct RtMidiWrapper, &output_type, device);
	if (device != NULL) {
		DATA_PTR(self) = NULL;
		output_free(device);
	}
	return Qnil;
}

static VALUE output_closed(VALUE self)
{
	return DATA_PTR(self) == NULL ? Qtrue : Qfalse;
}

/* The MIDI API in use, as a Symbol. */
static VALUE output_api(VALUE self)
{
	return api_to_sym(rtmidi_out_get_current_api(get_output(self)));
}

/*
 * call-seq:
 *   output.send_bytes(string) -> nil
 *
 * Sends one MIDI message (its bytes as a String).
 */
static VALUE output_send(VALUE self, VALUE bytes)
{
	RtMidiOutPtr device = get_output(self);
	StringValue(bytes);
	rtmidi_out_send_message(device, (const unsigned char *)RSTRING_PTR(bytes), (int)RSTRING_LEN(bytes));
	check(device, "Sending MIDI");
	return Qnil;
}

void Init_fast_midi(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_midi = rb_define_module_under(sound, "FastMIDI");

	cError = rb_define_class_under(fast_midi, "Error", rb_eRuntimeError);

	rb_define_const(fast_midi, "RTMIDI_VERSION", rb_str_freeze(rb_str_new_cstr(rtmidi_get_version())));
	rb_define_module_function(fast_midi, "compiled_apis", ruby_compiled_apis, 0);
	rb_define_module_function(fast_midi, "input_ports", ruby_input_ports, 2);
	rb_define_module_function(fast_midi, "output_ports", ruby_output_ports, 2);

	VALUE input = rb_define_class_under(fast_midi, "Input", rb_cObject);
	rb_define_alloc_func(input, input_alloc);
	rb_define_method(input, "initialize", input_initialize, 5);
	rb_define_method(input, "read", input_read, 0);
	rb_define_method(input, "api", input_api, 0);
	rb_define_method(input, "ports", input_ports, 0);
	rb_define_method(input, "close", input_close, 0);
	rb_define_method(input, "closed?", input_closed, 0);

	VALUE output = rb_define_class_under(fast_midi, "Output", rb_cObject);
	rb_undef_alloc_func(output);
	rb_define_singleton_method(output, "new", output_new, 4);
	rb_define_method(output, "send_bytes", output_send, 1);
	rb_define_method(output, "api", output_api, 0);
	rb_define_method(output, "close", output_close, 0);
	rb_define_method(output, "closed?", output_closed, 0);
}
