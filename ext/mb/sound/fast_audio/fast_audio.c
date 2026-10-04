/*
 * Sound card output through miniaudio (https://miniaud.io) for
 * MB::Sound::DeviceOutput.
 *
 * Ruby writes audio into a lock-free single-producer, single-consumer ring
 * buffer, and miniaudio's device thread reads it from a C callback.  The
 * callback never touches Ruby objects, never takes the GVL, never allocates,
 * and never blocks (it only try-locks to wake the writer), so garbage
 * collection or a busy Ruby thread can't stall the sound card; the ring
 * absorbs them.  Ruby keeps the GVL while there is room in the ring, and
 * releases it only to wait for the device to drain the ring to half full, so
 * one GVL round trip covers many buffers.  The device clock paces the writer.
 *
 * A mono writer is fanned out to every device channel in C.
 *
 * (C)2026 Mike Bourgeous
 */
#include <stdatomic.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>
#include <math.h>

#include <samplerate.h>

#include <ruby.h>
#include <ruby/thread.h>

#include "numo/narray.h"

#include "mb_miniaudio.h"

#define MAX_CHANNELS 64
#define MAX_BACKENDS 16

// How long the writer sleeps at most before checking the ring again, in case
// the callback's try-lock wakeup was missed.
#define WAIT_TIMEOUT_NS 5000000

static VALUE cError;

static const struct {
	const char *name;
	ma_backend backend;
} backend_names[] = {
	{ "coreaudio", ma_backend_coreaudio },
	{ "pulseaudio", ma_backend_pulseaudio },
	{ "alsa", ma_backend_alsa },
	{ "jack", ma_backend_jack },
	{ "null", ma_backend_null },
	{ "wasapi", ma_backend_wasapi },
	{ "dsound", ma_backend_dsound },
	{ "winmm", ma_backend_winmm },
	{ "sndio", ma_backend_sndio },
	{ "audio4", ma_backend_audio4 },
	{ "oss", ma_backend_oss },
};

static VALUE backend_to_sym(ma_backend backend)
{
	for (size_t i = 0; i < sizeof(backend_names) / sizeof(backend_names[0]); i++) {
		if (backend_names[i].backend == backend) {
			return ID2SYM(rb_intern(backend_names[i].name));
		}
	}

	return Qnil;
}

// Fills +list+ from a Ruby Array of backend Symbols or Strings (e.g.
// [:jack, :pulseaudio]), in order of preference.  Returns the number of
// backends, or 0 for nil (miniaudio's default order).
static ma_uint32 parse_backends(VALUE backends, ma_backend *list)
{
	if (NIL_P(backends)) {
		return 0;
	}

	Check_Type(backends, T_ARRAY);
	long count = RARRAY_LEN(backends);
	if (count > MAX_BACKENDS) {
		rb_raise(rb_eArgError, "Too many backends (%ld > %d)", count, MAX_BACKENDS);
	}

	for (long i = 0; i < count; i++) {
		VALUE name = rb_funcall(rb_ary_entry(backends, i), rb_intern("to_s"), 0);
		const char *cname = StringValueCStr(name);
		int found = 0;

		for (size_t j = 0; j < sizeof(backend_names) / sizeof(backend_names[0]); j++) {
			if (strcmp(cname, backend_names[j].name) == 0) {
				list[i] = backend_names[j].backend;
				found = 1;
				break;
			}
		}

		if (!found) {
			rb_raise(rb_eArgError, "Unknown audio backend: %s", cname);
		}
	}

	return (ma_uint32)count;
}

// Initializes +context+ with the given backends (see parse_backends), raising
// on failure.  miniaudio never starts a JACK server (tryStartServer is off),
// so a JACK backend is only used when jackd or pipewire-jack is running.
static void init_context(ma_context *context, VALUE backends, const char *client_name)
{
	ma_backend list[MAX_BACKENDS];
	ma_uint32 count = parse_backends(backends, list);

	ma_context_config config = ma_context_config_init();
	config.jack.pClientName = client_name;
	config.jack.tryStartServer = MA_FALSE;

	ma_result result = ma_context_init(count ? list : NULL, count, &config, context);
	if (result != MA_SUCCESS) {
		rb_raise(cError, "Could not start any audio backend: %s", ma_result_description(result));
	}
}

static VALUE device_info_list(ma_device_info *infos, ma_uint32 count)
{
	VALUE list = rb_ary_new_capa(count);

	for (ma_uint32 i = 0; i < count; i++) {
		VALUE h = rb_hash_new();
		rb_hash_aset(h, ID2SYM(rb_intern("index")), UINT2NUM(i));
		rb_hash_aset(h, ID2SYM(rb_intern("name")), rb_utf8_str_new_cstr(infos[i].name));
		rb_hash_aset(h, ID2SYM(rb_intern("default")), infos[i].isDefault ? Qtrue : Qfalse);
		rb_ary_push(list, h);
	}

	return list;
}

struct device_list_args {
	ma_context *context;
	VALUE result;
};

static VALUE device_list_body(VALUE arg)
{
	struct device_list_args *a = (struct device_list_args *)arg;
	ma_device_info *playback, *capture;
	ma_uint32 playback_count, capture_count;

	ma_result result = ma_context_get_devices(a->context, &playback, &playback_count, &capture, &capture_count);
	if (result != MA_SUCCESS) {
		rb_raise(cError, "Could not list audio devices: %s", ma_result_description(result));
	}

	a->result = rb_hash_new();
	rb_hash_aset(a->result, ID2SYM(rb_intern("backend")), backend_to_sym(a->context->backend));
	rb_hash_aset(a->result, ID2SYM(rb_intern("playback")), device_info_list(playback, playback_count));
	rb_hash_aset(a->result, ID2SYM(rb_intern("capture")), device_info_list(capture, capture_count));

	return Qnil;
}

static VALUE device_list_ensure(VALUE arg)
{
	ma_context_uninit(((struct device_list_args *)arg)->context);
	return Qnil;
}

/*
 * call-seq:
 *   MB::Sound::FastAudio.devices(backends, client_name) -> { backend:, playback: [...], capture: [...] }
 *
 * Lists the devices of the first backend in +backends+ (an Array of Symbols,
 * or nil for miniaudio's default order) that starts.  Each device is a Hash
 * with :index (for Playback.new), :name, and :default.
 */
static VALUE ruby_devices(VALUE self, VALUE backends, VALUE client_name)
{
	ma_context context;
	init_context(&context, backends, StringValueCStr(client_name));

	struct device_list_args args = { &context, Qnil };
	rb_ensure(device_list_body, (VALUE)&args, device_list_ensure, (VALUE)&args);

	return args.result;
}

/*
 * call-seq:
 *   MB::Sound::FastAudio.enabled_backends -> [:pulseaudio, :alsa, :jack, :null]
 *
 * The backends miniaudio supports on this platform, in its default order of
 * preference (whether they can start depends on the system).
 */
static VALUE ruby_enabled_backends(VALUE self)
{
	ma_backend backends[MA_BACKEND_COUNT];
	size_t count;

	if (ma_get_enabled_backends(backends, MA_BACKEND_COUNT, &count) != MA_SUCCESS) {
		rb_raise(cError, "Could not list audio backends");
	}

	VALUE list = rb_ary_new();
	for (size_t i = 0; i < count; i++) {
		VALUE sym = backend_to_sym(backends[i]);
		if (!NIL_P(sym)) {
			rb_ary_push(list, sym);
		}
	}

	return list;
}


/* Playback ----------------------------------------------------------------- */

struct playback {
	// Ring buffer of interleaved frames with out_channels samples each.
	// Positions count frames since opening and only increase; the writer
	// owns write_pos and the device callback owns read_pos.
	float *data;
	size_t capacity; // frames, a power of two
	size_t queue_limit; // most frames the writer queues (sets the latency)
	size_t max_queue; // the largest #queue_limit= allowed (sizes the ring)
	int in_channels; // channels written from Ruby (1 is fanned out)
	int out_channels; // channels sent to miniaudio
	_Atomic size_t write_pos;
	_Atomic size_t read_pos;

	_Atomic size_t underruns; // times the device ran out of queued audio
	_Atomic size_t frames_played; // device clock in frames (including silence)
	_Atomic size_t max_callback; // most frames the device asked for at once
	int starving; // callback only: the last callback ran out of audio

	_Atomic int open;
	_Atomic int stopped; // miniaudio stopped the device (e.g. unplugged)
	pid_t pid; // the process that opened the device (it doesn't survive fork)

	// Only used for the writer to sleep while the ring is full.
	pthread_mutex_t lock;
	pthread_cond_t space;
	int interrupted;

	ma_context context;
	ma_device device;
	int context_ready;
	int device_ready;

	// Optional record of the first capture_frames frames played (for specs)
	float *capture;
	size_t capture_frames;
	_Atomic size_t capture_length;

	// The rate #write's audio is at.  When the device runs at another rate,
	// the writer resamples with libsamplerate (src is NULL otherwise), so
	// the ring and the callback only see device-rate frames.
	ma_uint32 input_rate;
	SRC_STATE *src;
	double src_ratio; // device rate / input rate

	// Writer scratch: interleaved input frames and resampled frames
	float *in_buf;
	size_t in_cap; // frames
	float *out_buf;
	size_t out_cap; // frames
};

// Releases the device and context (not the ring, which a writer in another
// thread may still be looking at until it sees that the output is closed).
static void playback_release_device(struct playback *p)
{
	// A forked child has no device thread to stop; leave the copies alone.
	if (p->pid != getpid()) {
		p->device_ready = 0;
		p->context_ready = 0;
		return;
	}

	if (p->device_ready) {
		ma_device_uninit(&p->device);
		p->device_ready = 0;
	}

	if (p->context_ready) {
		ma_context_uninit(&p->context);
		p->context_ready = 0;
	}
}

static void playback_wake_writer(struct playback *p)
{
	pthread_mutex_lock(&p->lock);
	p->interrupted = 1;
	pthread_cond_broadcast(&p->space);
	pthread_mutex_unlock(&p->lock);
}

static void playback_free(void *ptr)
{
	struct playback *p = ptr;

	atomic_store(&p->open, 0);
	playback_release_device(p);

	free(p->data);
	free(p->capture);
	free(p->in_buf);
	free(p->out_buf);
	if (p->src != NULL) {
		src_delete(p->src);
	}

	if (p->pid == getpid()) {
		pthread_cond_destroy(&p->space);
		pthread_mutex_destroy(&p->lock);
	}

	free(p);
}

static size_t playback_memsize(const void *ptr)
{
	const struct playback *p = ptr;
	return sizeof(*p) + (p->capacity + p->capture_frames + p->in_cap + p->out_cap) * p->out_channels * sizeof(float);
}

static const rb_data_type_t playback_type = {
	.wrap_struct_name = "MB::Sound::FastAudio::Playback",
	.function = {
		.dmark = NULL,
		.dfree = playback_free,
		.dsize = playback_memsize,
	},
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static struct playback *get_playback(VALUE self)
{
	struct playback *p;
	TypedData_Get_Struct(self, struct playback, &playback_type, p);
	if (p->data == NULL) {
		rb_raise(cError, "Playback was not initialized");
	}
	return p;
}

// miniaudio's device thread.  Realtime safe: no Ruby, no allocation, no
// blocking locks.
static void playback_callback(ma_device *device, void *output, const void *input, ma_uint32 frames)
{
	struct playback *p = device->pUserData;
	float *out = output;
	size_t ch = p->out_channels;
	size_t mask = p->capacity - 1;

	size_t rp = atomic_load_explicit(&p->read_pos, memory_order_relaxed);
	size_t wp = atomic_load_explicit(&p->write_pos, memory_order_acquire);
	size_t available = wp - rp;
	size_t count = available < frames ? available : frames;

	// Copy in up to two pieces, around the end of the ring
	size_t start = rp & mask;
	size_t first = p->capacity - start;
	if (first > count) {
		first = count;
	}
	memcpy(out, p->data + start * ch, first * ch * sizeof(float));
	memcpy(out + first * ch, p->data, (count - first) * ch * sizeof(float));

	if (count < frames) {
		memset(out + count * ch, 0, (frames - count) * ch * sizeof(float));

		// Count each time the audio runs out, not every silent callback
		// (audio shorter than one callback ran out too)
		if (count > 0 || !p->starving) {
			atomic_fetch_add_explicit(&p->underruns, 1, memory_order_relaxed);
			p->starving = 1;
		}
	} else {
		p->starving = 0;
	}

	atomic_store_explicit(&p->read_pos, rp + count, memory_order_release);
	atomic_fetch_add_explicit(&p->frames_played, frames, memory_order_relaxed);
	if (frames > atomic_load_explicit(&p->max_callback, memory_order_relaxed)) {
		atomic_store_explicit(&p->max_callback, frames, memory_order_relaxed);
	}

	if (p->capture != NULL) {
		size_t length = atomic_load_explicit(&p->capture_length, memory_order_relaxed);
		if (length < p->capture_frames) {
			size_t n = p->capture_frames - length;
			if (n > frames) {
				n = frames;
			}
			memcpy(p->capture + length * ch, out, n * ch * sizeof(float));
			atomic_store_explicit(&p->capture_length, length + n, memory_order_release);
		}
	}

	// Wake the writer if it's waiting, without ever blocking this thread
	if (pthread_mutex_trylock(&p->lock) == 0) {
		pthread_cond_signal(&p->space);
		pthread_mutex_unlock(&p->lock);
	}
}

static void playback_notification(const ma_device_notification *notification)
{
	struct playback *p = notification->pDevice->pUserData;

	if (notification->type == ma_device_notification_type_stopped) {
		atomic_store(&p->stopped, 1);

		if (pthread_mutex_trylock(&p->lock) == 0) {
			pthread_cond_broadcast(&p->space);
			pthread_mutex_unlock(&p->lock);
		}
	}
}

static VALUE playback_alloc(VALUE klass)
{
	struct playback *p = calloc(1, sizeof(struct playback));
	if (p == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate audio playback");
	}

	p->pid = getpid();
	pthread_mutex_init(&p->lock, NULL);
	pthread_cond_init(&p->space, NULL);

	return TypedData_Wrap_Struct(klass, &playback_type, p);
}

// Opens the device (with the context already initialized), raising on
// failure.  See playback_initialize.
// Opens the device at +sample_rate+, or at the device's own rate if it
// can't run at that one.  With +allow_rate_change+, CoreAudio may change
// the device's system-wide rate (miniaudio's allowNominalSampleRateChange).
static void playback_open_device(struct playback *p, long device_index, ma_uint32 sample_rate, ma_uint32 period, int allow_rate_change)
{
	ma_device_id *device_id = NULL;

	if (device_index >= 0) {
		ma_device_info *infos;
		ma_uint32 count;
		ma_result result = ma_context_get_devices(&p->context, &infos, &count, NULL, NULL);
		if (result != MA_SUCCESS) {
			rb_raise(cError, "Could not list audio devices: %s", ma_result_description(result));
		}
		if ((ma_uint32)device_index >= count) {
			rb_raise(cError, "Audio device %ld does not exist (%u playback devices)", device_index, count);
		}
		device_id = &infos[device_index].id;
	}

	ma_device_config config = ma_device_config_init(ma_device_type_playback);
	config.playback.pDeviceID = device_id;
	config.playback.format = ma_format_f32;
	config.playback.channels = p->out_channels;
	config.sampleRate = sample_rate;
	config.periodSizeInFrames = period;
	config.performanceProfile = ma_performance_profile_low_latency;
	config.dataCallback = playback_callback;
	config.notificationCallback = playback_notification;
	config.pUserData = p;
	config.coreaudio.allowNominalSampleRateChange = allow_rate_change ? MA_TRUE : MA_FALSE;

	ma_result result = ma_device_init(&p->context, &config, &p->device);
	if (result != MA_SUCCESS) {
		rb_raise(cError, "Could not open audio device: %s", ma_result_description(result));
	}
	p->device_ready = 1;

	// Run the device at its own rate instead of letting miniaudio resample
	// (its resampler is linear); the writer resamples with libsamplerate.
	ma_uint32 device_rate = p->device.playback.internalSampleRate;
	if (sample_rate != 0 && device_rate != 0 && device_rate != sample_rate) {
		ma_device_uninit(&p->device);
		p->device_ready = 0;

		config.sampleRate = device_rate;
		result = ma_device_init(&p->context, &config, &p->device);
		if (result != MA_SUCCESS) {
			rb_raise(cError, "Could not open audio device at %u Hz: %s", device_rate, ma_result_description(result));
		}
		p->device_ready = 1;
	}
}

struct open_args {
	struct playback *p;
	VALUE backends;
	long device_index;
	const char *client_name;
	ma_uint32 sample_rate;
	ma_uint32 device_rate;
	ma_uint32 period;
	int resample_quality;
	int allow_rate_change;
};

static VALUE playback_open_body(VALUE arg)
{
	struct open_args *a = (struct open_args *)arg;

	struct playback *p = a->p;

	init_context(&p->context, a->backends, a->client_name);
	p->context_ready = 1;

	ma_uint32 ask = a->device_rate ? a->device_rate : a->sample_rate;
	playback_open_device(p, a->device_index, ask, a->period, a->allow_rate_change);

	// Resample from the writer's rate to the device's, unless told not to
	// (then the writer must use the device's rate; see #sample_rate).
	ma_uint32 device_rate = p->device.sampleRate;
	p->input_rate = device_rate;
	if (a->sample_rate != 0 && device_rate != a->sample_rate && a->resample_quality >= 0) {
		int error = 0;
		p->src = src_new(a->resample_quality, p->out_channels, &error);
		if (p->src == NULL) {
			rb_raise(cError, "Could not start resampling from %u to %u Hz: %s", a->sample_rate, device_rate, src_strerror(error));
		}
		p->src_ratio = (double)device_rate / a->sample_rate;
		p->input_rate = a->sample_rate;

		// The queue limits were given at the writer's rate
		p->queue_limit = (size_t)ceil(p->queue_limit * p->src_ratio);
		p->max_queue = (size_t)ceil(p->max_queue * p->src_ratio);
	}

	// The queue must hold at least two device periods, or the device runs
	// dry on every callback.  The ring is allocated now that the period is
	// known (the callback only runs after ma_device_start).
	size_t min_queue = 2 * (size_t)p->device.playback.internalPeriodSizeInFrames;
	if (p->queue_limit < min_queue) {
		p->queue_limit = min_queue;
	}
	if (p->max_queue < p->queue_limit) {
		p->max_queue = p->queue_limit;
	}

	size_t capacity = 16;
	while (capacity < p->max_queue) {
		capacity <<= 1;
	}

	p->data = calloc(capacity * p->out_channels, sizeof(float));
	if (p->data == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate the audio queue");
	}
	p->capacity = capacity;

	atomic_store(&p->open, 1);
	ma_result result = ma_device_start(&a->p->device);
	if (result != MA_SUCCESS) {
		atomic_store(&p->open, 0);
		rb_raise(cError, "Could not start audio device: %s", ma_result_description(result));
	}

	return Qnil;
}

static VALUE playback_open_rescue(VALUE arg, VALUE exception)
{
	playback_release_device(((struct open_args *)arg)->p);
	rb_exc_raise(exception);
	return Qnil;
}

/*
 * call-seq:
 *   Playback.new(backends, device_index, client_name, in_channels, out_channels,
 *                sample_rate, device_rate, period, queue_frames, capture_frames,
 *                resample_quality, allow_rate_change, max_queue_frames)
 *
 * Opens and starts a playback device.  +backends+ is an Array of backend
 * Symbols in order of preference, or nil.  +device_index+ is an index into
 * FastAudio.devices' playback list for the same backends, or -1 for the
 * default device.  +client_name+ names the JACK client.  +in_channels+ must
 * be 1 (fanned out to every device channel) or +out_channels+.
 *
 * +sample_rate+ is the rate #write's audio is at (0 for the device's rate).
 * +device_rate+ is the rate to open the device at (0 for +sample_rate+); a
 * device that can't run at it is reopened at its own rate (see
 * #device_rate).  When the device's rate differs from +sample_rate+, #write
 * resamples with libsamplerate converter +resample_quality+ (0 best sinc, 1
 * medium sinc, 2 fastest sinc, 3 zero-order hold, 4 linear), or with -1 it
 * doesn't, and #sample_rate is the device's rate.  +allow_rate_change+ lets
 * CoreAudio change the device's system-wide rate to the one asked for.
 *
 * +period+ is the device period in frames (0 for miniaudio's low-latency
 * default).  +queue_frames+ (at +sample_rate+) is the most audio #write
 * queues ahead of the device, which sets the output latency, and
 * +max_queue_frames+ (also at +sample_rate+; 0 for +queue_frames+) the most
 * #queue_limit= may raise it to later (the ring is sized for it).
 * +capture_frames+ records that many played frames for #captured (0 for
 * none; for specs).
 */
static VALUE playback_initialize(VALUE self, VALUE backends, VALUE device_index, VALUE client_name,
		VALUE in_channels, VALUE out_channels, VALUE sample_rate, VALUE device_rate, VALUE period,
		VALUE queue_frames, VALUE capture_frames, VALUE resample_quality, VALUE allow_rate_change,
		VALUE max_queue_frames)
{
	struct playback *p;
	TypedData_Get_Struct(self, struct playback, &playback_type, p);
	if (p->data != NULL) {
		rb_raise(cError, "Playback is already initialized");
	}

	int in_ch = NUM2INT(in_channels);
	int out_ch = NUM2INT(out_channels);
	if (out_ch < 1 || out_ch > MAX_CHANNELS) {
		rb_raise(rb_eArgError, "Output channels must be 1..%d (got %d)", MAX_CHANNELS, out_ch);
	}
	if (in_ch != 1 && in_ch != out_ch) {
		rb_raise(rb_eArgError, "Input channels must be 1 or %d (got %d)", out_ch, in_ch);
	}

	long queue = NUM2LONG(queue_frames);
	if (queue < 16 || queue > (1L << 24)) {
		rb_raise(rb_eArgError, "Queue size must be 16..%ld frames (got %ld)", 1L << 24, queue);
	}

	long max_queue = NUM2LONG(max_queue_frames);
	if (max_queue < 0 || max_queue > (1L << 24)) {
		rb_raise(rb_eArgError, "Maximum queue size must be 0..%ld frames (got %ld)", 1L << 24, max_queue);
	}

	long capture = NUM2LONG(capture_frames);
	if (capture < 0 || capture > (1L << 26)) {
		rb_raise(rb_eArgError, "Capture length must be 0..%ld frames (got %ld)", 1L << 26, capture);
	}

	int quality = NUM2INT(resample_quality);
	if (quality < -1 || quality > SRC_LINEAR) {
		rb_raise(rb_eArgError, "Resample quality must be -1..%d (got %d)", SRC_LINEAR, quality);
	}

	struct open_args args = {
		.p = p,
		.backends = backends,
		.device_index = NUM2LONG(device_index),
		.client_name = StringValueCStr(client_name),
		.sample_rate = NUM2UINT(sample_rate),
		.device_rate = NUM2UINT(device_rate),
		.period = NUM2UINT(period),
		.resample_quality = quality,
		.allow_rate_change = RTEST(allow_rate_change),
	};

	p->in_channels = in_ch;
	p->out_channels = out_ch;
	p->queue_limit = queue;
	p->max_queue = max_queue;
	p->starving = 1; // silence before the first write isn't an underrun

	if (capture > 0) {
		p->capture = calloc(capture * out_ch, sizeof(float));
		if (p->capture == NULL) {
			rb_raise(rb_eNoMemError, "Could not allocate the capture buffer");
		}
		p->capture_frames = capture;
	}

	rb_rescue2(playback_open_body, (VALUE)&args, playback_open_rescue, (VALUE)&args, rb_eException, (VALUE)0);

	RB_GC_GUARD(client_name);

	return self;
}

static void check_open(struct playback *p)
{
	if (p->pid != getpid()) {
		rb_raise(rb_eIOError, "This audio output was opened by another process (pid %d)", (int)p->pid);
	}
	if (!atomic_load(&p->open)) {
		rb_raise(rb_eIOError, "This output is closed");
	}
	if (atomic_load(&p->stopped)) {
		rb_raise(cError, "The audio device stopped");
	}
}

static size_t queued_frames(struct playback *p)
{
	return atomic_load_explicit(&p->write_pos, memory_order_relaxed) -
		atomic_load_explicit(&p->read_pos, memory_order_acquire);
}

struct wait_args {
	struct playback *p;
	size_t want;
};

// Waits (without the GVL) until +want+ frames fit in the queue, the output
// closes or stops, or Ruby interrupts the thread.
static void *wait_for_space(void *arg)
{
	struct wait_args *a = arg;
	struct playback *p = a->p;

	pthread_mutex_lock(&p->lock);
	while (!p->interrupted && atomic_load(&p->open) && !atomic_load(&p->stopped)) {
		size_t queued = queued_frames(p);
		if (queued <= p->queue_limit && p->queue_limit - queued >= a->want) {
			break;
		}

		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += WAIT_TIMEOUT_NS;
		if (ts.tv_nsec >= 1000000000) {
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000;
		}
		pthread_cond_timedwait(&p->space, &p->lock, &ts);
	}
	pthread_mutex_unlock(&p->lock);

	return NULL;
}

static void unblock_wait(void *arg)
{
	playback_wake_writer(arg);
}

// Grows *buf to hold at least +frames+ frames of +channels+ floats.
static void grow_buffer(float **buf, size_t *cap, size_t frames, size_t channels)
{
	if (*cap >= frames) {
		return;
	}

	float *bigger = realloc(*buf, frames * channels * sizeof(float));
	if (bigger == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate %zu audio frames", frames);
	}
	*buf = bigger;
	*cap = frames;
}

// Copies +count+ interleaved device-rate frames into the ring, waiting
// without the GVL while the queue is full (see #write).
static void push_frames(struct playback *p, const float *frames, size_t count)
{
	size_t mask = p->capacity - 1;
	size_t out_ch = p->out_channels;
	size_t done = 0;

	while (done < count) {
		size_t queued = queued_frames(p);
		size_t room = queued < p->queue_limit ? p->queue_limit - queued : 0;

		if (room == 0) {
			// Wait for the queue to drain halfway, so one GVL round trip
			// covers many buffers.
			size_t want = count - done;
			if (want > p->queue_limit / 2) {
				want = p->queue_limit / 2;
			}

			struct wait_args args = { p, want };
			p->interrupted = 0;
			rb_thread_call_without_gvl(wait_for_space, &args, unblock_wait, p);
			rb_thread_check_ints();
			check_open(p);
			continue;
		}

		size_t n = count - done;
		if (n > room) {
			n = room;
		}

		// Copy in up to two pieces, around the end of the ring
		size_t wp = atomic_load_explicit(&p->write_pos, memory_order_relaxed);
		size_t start = wp & mask;
		size_t first = p->capacity - start;
		if (first > n) {
			first = n;
		}
		memcpy(p->data + start * out_ch, frames + done * out_ch, first * out_ch * sizeof(float));
		memcpy(p->data, frames + (done + first) * out_ch, (n - first) * out_ch * sizeof(float));
		atomic_store_explicit(&p->write_pos, wp + n, memory_order_release);

		done += n;
	}
}

// Casts +value+ to a contiguous 1D SFloat (copying only if needed).
static VALUE to_contiguous_sfloat(VALUE value)
{
	value = rb_funcall(numo_cSFloat, rb_intern("cast"), 1, value);

	if (RNARRAY_NDIM(value) != 1) {
		rb_raise(rb_eArgError, "Each channel must be a 1D NArray (got %d dimensions)", RNARRAY_NDIM(value));
	}

	if (!RTEST(nary_check_contiguous(value))) {
		value = nary_dup(value);
	}

	return value;
}

/*
 * call-seq:
 *   playback.write([channel_narray, ...]) -> frames
 *
 * Queues one NArray per input channel (all the same length) for playback,
 * waiting without the GVL while the queue is full.  Raises IOError if the
 * output is closed, or FastAudio::Error if the device stopped.
 */
static VALUE playback_write(VALUE self, VALUE channels)
{
	struct playback *p = get_playback(self);
	check_open(p);

	Check_Type(channels, T_ARRAY);
	long count = RARRAY_LEN(channels);
	if (count != p->in_channels) {
		rb_raise(rb_eArgError, "Expected %d channels, got %ld", p->in_channels, count);
	}

	// Keeps the cast arrays alive while the GVL is released
	VALUE keep = rb_ary_new_capa(count);
	const float *src[MAX_CHANNELS];
	size_t frames = 0;

	for (long c = 0; c < count; c++) {
		VALUE v = to_contiguous_sfloat(rb_ary_entry(channels, c));
		rb_ary_push(keep, v);

		size_t length = RNARRAY_SHAPE(v)[0];
		if (c == 0) {
			frames = length;
		} else if (length != frames) {
			rb_raise(rb_eArgError, "Channel %ld has %zu samples; channel 0 has %zu", c, length, frames);
		}

		src[c] = (const float *)(nary_get_pointer_for_read(v) + nary_get_offset(v));
	}

	// Interleave (fanning out mono) into the writer's scratch buffer
	size_t out_ch = p->out_channels;
	grow_buffer(&p->in_buf, &p->in_cap, frames, out_ch);
	for (size_t i = 0; i < frames; i++) {
		float *dst = p->in_buf + i * out_ch;
		for (size_t c = 0; c < out_ch; c++) {
			dst[c] = src[p->in_channels == 1 ? 0 : c][i];
		}
	}

	RB_GC_GUARD(keep);

	if (p->src == NULL) {
		push_frames(p, p->in_buf, frames);
		return SIZET2NUM(frames);
	}

	// Resample to the device's rate, a chunk of output at a time
	size_t out_cap = (size_t)ceil(frames * p->src_ratio) + 64;
	grow_buffer(&p->out_buf, &p->out_cap, out_cap, out_ch);

	size_t used = 0;
	while (used < frames) {
		SRC_DATA data = {
			.data_in = p->in_buf + used * out_ch,
			.input_frames = frames - used,
			.data_out = p->out_buf,
			.output_frames = p->out_cap,
			.src_ratio = p->src_ratio,
			.end_of_input = 0,
		};

		int error = src_process(p->src, &data);
		if (error) {
			rb_raise(cError, "Resampling failed: %s", src_strerror(error));
		}

		used += data.input_frames_used;
		push_frames(p, p->out_buf, data.output_frames_gen);

		if (data.input_frames_used == 0 && data.output_frames_gen == 0) {
			break; // libsamplerate wants more input than it has
		}
	}

	return SIZET2NUM(frames);
}

/*
 * call-seq:
 *   playback.close -> nil
 *
 * Stops and closes the device.  A writer waiting in another thread raises
 * IOError.  Safe to call more than once.
 */
static VALUE playback_close(VALUE self)
{
	struct playback *p = get_playback(self);

	if (atomic_exchange(&p->open, 0) || p->device_ready || p->context_ready) {
		playback_release_device(p);

		if (p->pid == getpid()) {
			playback_wake_writer(p);
		}
	}

	return Qnil;
}

static VALUE playback_closed(VALUE self)
{
	return atomic_load(&get_playback(self)->open) ? Qfalse : Qtrue;
}

// Returns a device property, raising if the device is closed.
static ma_device *open_device(VALUE self)
{
	struct playback *p = get_playback(self);
	if (!p->device_ready) {
		rb_raise(rb_eIOError, "This output is closed");
	}
	return &p->device;
}

/* The sample rate #write's audio is at (resampled to #device_rate if they differ). */
static VALUE playback_sample_rate(VALUE self)
{
	open_device(self);
	return UINT2NUM(get_playback(self)->input_rate);
}

/* The sample rate the device runs at. */
static VALUE playback_device_rate(VALUE self)
{
	return UINT2NUM(open_device(self)->sampleRate);
}

/* True if #write resamples to the device's rate. */
static VALUE playback_resampling(VALUE self)
{
	return get_playback(self)->src ? Qtrue : Qfalse;
}

/* The device's period (callback size) in frames. */
static VALUE playback_period(VALUE self)
{
	return UINT2NUM(open_device(self)->playback.internalPeriodSizeInFrames);
}

/* The number of periods in the device's own buffer. */
static VALUE playback_periods(VALUE self)
{
	return UINT2NUM(open_device(self)->playback.internalPeriods);
}

/* The name of the device. */
static VALUE playback_device_name(VALUE self)
{
	return rb_utf8_str_new_cstr(open_device(self)->playback.name);
}

/* The backend in use, as a Symbol (e.g. :coreaudio, :jack). */
static VALUE playback_backend(VALUE self)
{
	return backend_to_sym(open_device(self)->pContext->backend);
}

/* The number of channels sent to the device. */
static VALUE playback_device_channels(VALUE self)
{
	return INT2NUM(get_playback(self)->out_channels);
}

/* The most frames #write queues ahead of the device. */
static VALUE playback_queue_limit(VALUE self)
{
	return SIZET2NUM(get_playback(self)->queue_limit);
}

/* The largest queue limit #queue_limit= accepts (in device frames). */
static VALUE playback_max_queue(VALUE self)
{
	return SIZET2NUM(get_playback(self)->max_queue);
}

/*
 * call-seq:
 *   playback.queue_limit = frames
 *
 * Changes how many frames (at the device's rate) #write queues ahead of
 * the device, from two device periods up to #max_queue (e.g. to add
 * latency after underruns).  Call from the writing thread.
 */
static VALUE playback_set_queue_limit(VALUE self, VALUE frames)
{
	struct playback *p = get_playback(self);
	size_t n = NUM2SIZET(frames);
	size_t min = 2 * (size_t)open_device(self)->playback.internalPeriodSizeInFrames;

	if (n < min) {
		n = min;
	}
	if (n > p->max_queue) {
		n = p->max_queue;
	}

	pthread_mutex_lock(&p->lock);
	p->queue_limit = n;
	pthread_mutex_unlock(&p->lock);

	return SIZET2NUM(n);
}

/*
 * call-seq:
 *   playback.stats -> { queued:, frames_written:, frames_played:, underruns: }
 *
 * :queued frames are waiting to play; :frames_played counts every frame the
 * device has played since opening, including silence (the device clock);
 * :underruns counts the times the queue ran out while the device needed
 * audio (once per gap, so a pause between sounds counts once).
 */
static VALUE playback_stats(VALUE self)
{
	struct playback *p = get_playback(self);
	size_t wp = atomic_load(&p->write_pos);
	size_t rp = atomic_load(&p->read_pos);

	VALUE h = rb_hash_new();
	rb_hash_aset(h, ID2SYM(rb_intern("queued")), SIZET2NUM(wp - rp));
	rb_hash_aset(h, ID2SYM(rb_intern("frames_written")), SIZET2NUM(wp));
	rb_hash_aset(h, ID2SYM(rb_intern("frames_played")), SIZET2NUM(atomic_load(&p->frames_played)));
	rb_hash_aset(h, ID2SYM(rb_intern("underruns")), SIZET2NUM(atomic_load(&p->underruns)));
	rb_hash_aset(h, ID2SYM(rb_intern("max_callback")), SIZET2NUM(atomic_load(&p->max_callback)));

	return h;
}

/*
 * call-seq:
 *   playback.captured -> String or nil
 *
 * The interleaved 32-bit float frames played so far, up to the
 * +capture_frames+ given to new (nil if 0).  For specs.
 */
static VALUE playback_captured(VALUE self)
{
	struct playback *p = get_playback(self);
	if (p->capture == NULL) {
		return Qnil;
	}

	size_t length = atomic_load_explicit(&p->capture_length, memory_order_acquire);
	return rb_str_new((const char *)p->capture, length * p->out_channels * sizeof(float));
}

/* Capture ------------------------------------------------------------------ */

// The capture side mirrors playback: miniaudio's device thread copies
// captured frames into a ring (the producer), and Ruby's #read waits
// without the GVL until enough have arrived (the consumer), resampling
// from the device's rate if it differs from the rate Ruby asked for.
struct capture {
	float *data; // interleaved device frames
	size_t capacity; // frames, a power of two
	size_t queue_limit; // most frames kept waiting; older ones are skipped
	int channels;
	_Atomic size_t write_pos; // owned by the callback
	_Atomic size_t read_pos; // owned by the reader

	_Atomic size_t frames_captured; // device clock in frames
	_Atomic size_t overruns; // callbacks that found the ring full (frames lost)
	size_t skipped; // frames the reader skipped to keep the latency down
	int test_pattern; // write a counting pattern instead of the device's audio
	size_t pattern_frame;

	_Atomic int open;
	_Atomic int stopped;
	pid_t pid;

	pthread_mutex_t lock;
	pthread_cond_t ready;
	int interrupted;

	ma_context context;
	ma_device device;
	int context_ready;
	int device_ready;

	ma_uint32 output_rate; // the rate #read returns
	SRC_STATE *src;
	double src_ratio; // output rate / device rate

	// Reader scratch: device frames taken from the ring, and frames ready
	// to return (resampled if needed)
	float *in_buf;
	size_t in_cap;
	float *pending;
	size_t pending_cap;
	size_t pending_count;
};

static void capture_release_device(struct capture *c)
{
	if (c->pid != getpid()) {
		c->device_ready = 0;
		c->context_ready = 0;
		return;
	}

	if (c->device_ready) {
		ma_device_uninit(&c->device);
		c->device_ready = 0;
	}

	if (c->context_ready) {
		ma_context_uninit(&c->context);
		c->context_ready = 0;
	}
}

static void capture_wake_reader(struct capture *c)
{
	pthread_mutex_lock(&c->lock);
	c->interrupted = 1;
	pthread_cond_broadcast(&c->ready);
	pthread_mutex_unlock(&c->lock);
}

static void capture_free(void *ptr)
{
	struct capture *c = ptr;

	atomic_store(&c->open, 0);
	capture_release_device(c);

	free(c->data);
	free(c->in_buf);
	free(c->pending);
	if (c->src != NULL) {
		src_delete(c->src);
	}

	if (c->pid == getpid()) {
		pthread_cond_destroy(&c->ready);
		pthread_mutex_destroy(&c->lock);
	}

	free(c);
}

static size_t capture_memsize(const void *ptr)
{
	const struct capture *c = ptr;
	return sizeof(*c) + (c->capacity + c->in_cap + c->pending_cap) * c->channels * sizeof(float);
}

static const rb_data_type_t capture_type = {
	.wrap_struct_name = "MB::Sound::FastAudio::Capture",
	.function = {
		.dmark = NULL,
		.dfree = capture_free,
		.dsize = capture_memsize,
	},
	.flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static struct capture *get_capture(VALUE self)
{
	struct capture *c;
	TypedData_Get_Struct(self, struct capture, &capture_type, c);
	if (c->data == NULL) {
		rb_raise(cError, "Capture was not initialized");
	}
	return c;
}

// miniaudio's device thread.  Realtime safe: no Ruby, no allocation, no
// blocking locks.
static void capture_callback(ma_device *device, void *output, const void *input, ma_uint32 frames)
{
	struct capture *c = device->pUserData;
	size_t ch = c->channels;
	size_t mask = c->capacity - 1;

	size_t wp = atomic_load_explicit(&c->write_pos, memory_order_relaxed);
	size_t rp = atomic_load_explicit(&c->read_pos, memory_order_acquire);
	size_t room = c->capacity - (wp - rp);
	size_t count = frames;
	if (count > room) {
		// The reader fell far behind; drop what doesn't fit
		atomic_fetch_add_explicit(&c->overruns, 1, memory_order_relaxed);
		count = room;
	}

	const float *in = input;
	for (size_t i = 0; i < count; i++) {
		float *dst = c->data + ((wp + i) & mask) * ch;
		if (c->test_pattern) {
			// Frame number modulo 4096, scaled to -1..1, plus a channel offset
			float v = (float)((c->pattern_frame + i) % 4096) / 2048.0f - 1.0f;
			for (size_t k = 0; k < ch; k++) {
				dst[k] = v + 0.001f * k;
			}
		} else {
			memcpy(dst, in + i * ch, ch * sizeof(float));
		}
	}
	c->pattern_frame += frames;

	atomic_store_explicit(&c->write_pos, wp + count, memory_order_release);
	atomic_fetch_add_explicit(&c->frames_captured, frames, memory_order_relaxed);

	if (pthread_mutex_trylock(&c->lock) == 0) {
		pthread_cond_signal(&c->ready);
		pthread_mutex_unlock(&c->lock);
	}
}

static void capture_notification(const ma_device_notification *notification)
{
	struct capture *c = notification->pDevice->pUserData;

	if (notification->type == ma_device_notification_type_stopped) {
		atomic_store(&c->stopped, 1);

		if (pthread_mutex_trylock(&c->lock) == 0) {
			pthread_cond_broadcast(&c->ready);
			pthread_mutex_unlock(&c->lock);
		}
	}
}

static VALUE capture_alloc(VALUE klass)
{
	struct capture *c = calloc(1, sizeof(struct capture));
	if (c == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate audio capture");
	}

	c->pid = getpid();
	pthread_mutex_init(&c->lock, NULL);
	pthread_cond_init(&c->ready, NULL);

	return TypedData_Wrap_Struct(klass, &capture_type, c);
}

struct capture_args {
	struct capture *c;
	VALUE backends;
	long device_index;
	const char *client_name;
	ma_uint32 sample_rate;
	ma_uint32 device_rate;
	ma_uint32 period;
	size_t queue;
	int resample_quality;
};

static VALUE capture_open_body(VALUE arg)
{
	struct capture_args *a = (struct capture_args *)arg;
	struct capture *c = a->c;

	init_context(&c->context, a->backends, a->client_name);
	c->context_ready = 1;

	ma_device_id *device_id = NULL;
	if (a->device_index >= 0) {
		ma_device_info *infos;
		ma_uint32 count;
		ma_result result = ma_context_get_devices(&c->context, NULL, NULL, &infos, &count);
		if (result != MA_SUCCESS) {
			rb_raise(cError, "Could not list audio devices: %s", ma_result_description(result));
		}
		if ((ma_uint32)a->device_index >= count) {
			rb_raise(cError, "Audio input device %ld does not exist (%u capture devices)", a->device_index, count);
		}
		device_id = &infos[a->device_index].id;
	}

	ma_uint32 ask = a->device_rate ? a->device_rate : a->sample_rate;

	ma_device_config config = ma_device_config_init(ma_device_type_capture);
	config.capture.pDeviceID = device_id;
	config.capture.format = ma_format_f32;
	config.capture.channels = c->channels;
	config.sampleRate = ask;
	config.periodSizeInFrames = a->period;
	config.performanceProfile = ma_performance_profile_low_latency;
	config.dataCallback = capture_callback;
	config.notificationCallback = capture_notification;
	config.pUserData = c;

	ma_result result = ma_device_init(&c->context, &config, &c->device);
	if (result != MA_SUCCESS) {
		rb_raise(cError, "Could not open audio input device: %s", ma_result_description(result));
	}
	c->device_ready = 1;

	// Capture at the device's own rate and resample with libsamplerate
	ma_uint32 native = c->device.capture.internalSampleRate;
	if (ask != 0 && native != 0 && native != ask) {
		ma_device_uninit(&c->device);
		c->device_ready = 0;
		config.sampleRate = native;
		result = ma_device_init(&c->context, &config, &c->device);
		if (result != MA_SUCCESS) {
			rb_raise(cError, "Could not open audio input device at %u Hz: %s", native, ma_result_description(result));
		}
		c->device_ready = 1;
	}

	ma_uint32 device_rate = c->device.sampleRate;
	c->output_rate = device_rate;
	double ratio = 1.0;
	if (a->sample_rate != 0 && device_rate != a->sample_rate && a->resample_quality >= 0) {
		int error = 0;
		c->src = src_new(a->resample_quality, c->channels, &error);
		if (c->src == NULL) {
			rb_raise(cError, "Could not start resampling from %u to %u Hz: %s", device_rate, a->sample_rate, src_strerror(error));
		}
		c->src_ratio = (double)a->sample_rate / device_rate;
		c->output_rate = a->sample_rate;
		ratio = 1.0 / c->src_ratio;
	}

	// The queue limit was given at the output rate; keep at least two
	// device periods, and room in the ring for the callback beyond it
	size_t period = c->device.capture.internalPeriodSizeInFrames;
	c->queue_limit = (size_t)ceil(a->queue * ratio);
	if (c->queue_limit < 2 * period) {
		c->queue_limit = 2 * period;
	}

	size_t capacity = 16;
	while (capacity < c->queue_limit * 2 + period * 4) {
		capacity <<= 1;
	}
	c->data = calloc(capacity * c->channels, sizeof(float));
	if (c->data == NULL) {
		rb_raise(rb_eNoMemError, "Could not allocate the audio input queue");
	}
	c->capacity = capacity;

	atomic_store(&c->open, 1);
	result = ma_device_start(&c->device);
	if (result != MA_SUCCESS) {
		atomic_store(&c->open, 0);
		rb_raise(cError, "Could not start audio input device: %s", ma_result_description(result));
	}

	return Qnil;
}

static VALUE capture_open_rescue(VALUE arg, VALUE exception)
{
	capture_release_device(((struct capture_args *)arg)->c);
	rb_exc_raise(exception);
	return Qnil;
}

/*
 * call-seq:
 *   Capture.new(backends, device_index, client_name, channels, sample_rate,
 *               device_rate, period, queue_frames, resample_quality, test_pattern)
 *
 * Opens and starts a capture device.  +backends+, +device_index+ (into
 * FastAudio.devices' capture list, or -1 for the default), +client_name+,
 * +device_rate+, +period+, and +resample_quality+ work as for Playback.new.
 * +sample_rate+ is the rate #read returns (resampled from the device's rate
 * if it differs, unless +resample_quality+ is -1; see #sample_rate).
 * +queue_frames+ (at +sample_rate+) is the most audio kept waiting for
 * #read; when more has arrived, #read skips the oldest so live input stays
 * close to real time.  +test_pattern+ replaces the device's audio with a
 * counting pattern (frame number modulo 4096, scaled to -1..1, plus 0.001
 * per channel), for specs.
 */
static VALUE capture_initialize(VALUE self, VALUE backends, VALUE device_index, VALUE client_name,
		VALUE channels, VALUE sample_rate, VALUE device_rate, VALUE period, VALUE queue_frames,
		VALUE resample_quality, VALUE test_pattern)
{
	struct capture *c;
	TypedData_Get_Struct(self, struct capture, &capture_type, c);
	if (c->data != NULL) {
		rb_raise(cError, "Capture is already initialized");
	}

	int ch = NUM2INT(channels);
	if (ch < 1 || ch > MAX_CHANNELS) {
		rb_raise(rb_eArgError, "Channels must be 1..%d (got %d)", MAX_CHANNELS, ch);
	}

	long queue = NUM2LONG(queue_frames);
	if (queue < 16 || queue > (1L << 24)) {
		rb_raise(rb_eArgError, "Queue size must be 16..%ld frames (got %ld)", 1L << 24, queue);
	}

	int quality = NUM2INT(resample_quality);
	if (quality < -1 || quality > SRC_LINEAR) {
		rb_raise(rb_eArgError, "Resample quality must be -1..%d (got %d)", SRC_LINEAR, quality);
	}

	c->channels = ch;
	c->test_pattern = RTEST(test_pattern);

	struct capture_args args = {
		.c = c,
		.backends = backends,
		.device_index = NUM2LONG(device_index),
		.client_name = StringValueCStr(client_name),
		.sample_rate = NUM2UINT(sample_rate),
		.device_rate = NUM2UINT(device_rate),
		.period = NUM2UINT(period),
		.queue = (size_t)queue,
		.resample_quality = quality,
	};

	rb_rescue2(capture_open_body, (VALUE)&args, capture_open_rescue, (VALUE)&args, rb_eException, (VALUE)0);

	RB_GC_GUARD(client_name);

	return self;
}

static void capture_check_open(struct capture *c)
{
	if (c->pid != getpid()) {
		rb_raise(rb_eIOError, "This audio input was opened by another process (pid %d)", (int)c->pid);
	}
	if (!atomic_load(&c->open)) {
		rb_raise(rb_eIOError, "This input is closed");
	}
	if (atomic_load(&c->stopped)) {
		rb_raise(cError, "The audio input device stopped");
	}
}

static size_t captured_frames(struct capture *c)
{
	return atomic_load_explicit(&c->write_pos, memory_order_acquire) -
		atomic_load_explicit(&c->read_pos, memory_order_relaxed);
}

struct capture_wait_args {
	struct capture *c;
	size_t want;
};

// Waits (without the GVL) until +want+ frames have arrived, the input
// closes or stops, or Ruby interrupts the thread.
static void *wait_for_frames(void *arg)
{
	struct capture_wait_args *a = arg;
	struct capture *c = a->c;

	pthread_mutex_lock(&c->lock);
	while (!c->interrupted && atomic_load(&c->open) && !atomic_load(&c->stopped)) {
		if (captured_frames(c) >= a->want) {
			break;
		}

		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += WAIT_TIMEOUT_NS;
		if (ts.tv_nsec >= 1000000000) {
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000;
		}
		pthread_cond_timedwait(&c->ready, &c->lock, &ts);
	}
	pthread_mutex_unlock(&c->lock);

	return NULL;
}

static void unblock_capture_wait(void *arg)
{
	capture_wake_reader(arg);
}

// Takes up to +max+ device frames from the ring (waiting for at least one
// period's worth, or +max+ if smaller), skipping the oldest frames beyond the
// queue limit.  Returns the number of frames copied into c->in_buf.
static size_t take_frames(struct capture *c, size_t max)
{
	size_t period = c->device.capture.internalPeriodSizeInFrames;
	size_t want = max < period ? max : period;
	if (want < 1) {
		want = 1;
	}

	while (captured_frames(c) < want) {
		struct capture_wait_args args = { c, want };
		c->interrupted = 0;
		rb_thread_call_without_gvl(wait_for_frames, &args, unblock_capture_wait, c);
		rb_thread_check_ints();
		capture_check_open(c);
	}

	size_t rp = atomic_load_explicit(&c->read_pos, memory_order_relaxed);
	size_t available = captured_frames(c);

	// Keep live input near real time: skip what's beyond the queue limit
	if (available > c->queue_limit) {
		size_t skip = available - c->queue_limit;
		rp += skip;
		available -= skip;
		c->skipped += skip;
	}

	size_t n = available < max ? available : max;
	size_t ch = c->channels;
	size_t mask = c->capacity - 1;
	grow_buffer(&c->in_buf, &c->in_cap, n, ch);

	size_t start = rp & mask;
	size_t first = c->capacity - start;
	if (first > n) {
		first = n;
	}
	memcpy(c->in_buf, c->data + start * ch, first * ch * sizeof(float));
	memcpy(c->in_buf + first * ch, c->data, (n - first) * ch * sizeof(float));

	atomic_store_explicit(&c->read_pos, rp + n, memory_order_release);

	return n;
}

/*
 * call-seq:
 *   capture.read(frames) -> [channel_sfloat, ...]
 *
 * Returns +frames+ frames of captured audio at #sample_rate, one
 * Numo::SFloat per channel, waiting without the GVL until enough has
 * arrived.  Raises IOError if the input is closed, or FastAudio::Error if
 * the device stopped.
 */
static VALUE capture_read(VALUE self, VALUE frames_value)
{
	struct capture *c = get_capture(self);
	capture_check_open(c);

	size_t frames = NUM2SIZET(frames_value);
	size_t ch = c->channels;

	while (c->pending_count < frames) {
		size_t need = frames - c->pending_count;

		if (c->src == NULL) {
			size_t n = take_frames(c, need);
			grow_buffer(&c->pending, &c->pending_cap, c->pending_count + n, ch);
			memcpy(c->pending + c->pending_count * ch, c->in_buf, n * ch * sizeof(float));
			c->pending_count += n;
			continue;
		}

		// Device frames needed for +need+ output frames (plus a little for
		// the converter's delay)
		size_t in_need = (size_t)ceil(need / c->src_ratio) + 1;
		size_t n = take_frames(c, in_need);

		size_t out_cap = c->pending_count + (size_t)ceil(n * c->src_ratio) + 64;
		grow_buffer(&c->pending, &c->pending_cap, out_cap, ch);

		size_t used = 0;
		while (used < n) {
			SRC_DATA data = {
				.data_in = c->in_buf + used * ch,
				.input_frames = n - used,
				.data_out = c->pending + c->pending_count * ch,
				.output_frames = c->pending_cap - c->pending_count,
				.src_ratio = c->src_ratio,
				.end_of_input = 0,
			};

			int error = src_process(c->src, &data);
			if (error) {
				rb_raise(cError, "Resampling failed: %s", src_strerror(error));
			}

			used += data.input_frames_used;
			c->pending_count += data.output_frames_gen;

			if (data.input_frames_used == 0) {
				if (c->pending_cap - c->pending_count == 0) {
					grow_buffer(&c->pending, &c->pending_cap, c->pending_cap * 2, ch);
				} else {
					break; // libsamplerate keeps the rest internally
				}
			}
		}
	}

	// Deinterleave the first +frames+ pending frames into new SFloats
	VALUE result = rb_ary_new_capa(ch);
	for (size_t k = 0; k < ch; k++) {
		VALUE v = rb_funcall(numo_cSFloat, rb_intern("zeros"), 1, SIZET2NUM(frames));
		float *dst = (float *)(nary_get_pointer_for_write(v) + nary_get_offset(v));
		for (size_t i = 0; i < frames; i++) {
			dst[i] = c->pending[i * ch + k];
		}
		rb_ary_push(result, v);
	}

	c->pending_count -= frames;
	memmove(c->pending, c->pending + frames * ch, c->pending_count * ch * sizeof(float));

	return result;
}

/*
 * call-seq:
 *   capture.close -> nil
 *
 * Stops and closes the device.  A reader waiting in another thread raises
 * IOError.  Safe to call more than once.
 */
static VALUE capture_close(VALUE self)
{
	struct capture *c = get_capture(self);

	if (atomic_exchange(&c->open, 0) || c->device_ready || c->context_ready) {
		capture_release_device(c);

		if (c->pid == getpid()) {
			capture_wake_reader(c);
		}
	}

	return Qnil;
}

static VALUE capture_closed(VALUE self)
{
	return atomic_load(&get_capture(self)->open) ? Qfalse : Qtrue;
}

static ma_device *open_capture_device(VALUE self)
{
	struct capture *c = get_capture(self);
	if (!c->device_ready) {
		rb_raise(rb_eIOError, "This input is closed");
	}
	return &c->device;
}

/* The sample rate #read returns. */
static VALUE capture_sample_rate(VALUE self)
{
	open_capture_device(self);
	return UINT2NUM(get_capture(self)->output_rate);
}

/* The sample rate the device captures at. */
static VALUE capture_device_rate(VALUE self)
{
	return UINT2NUM(open_capture_device(self)->sampleRate);
}

/* True if #read resamples from the device's rate. */
static VALUE capture_resampling(VALUE self)
{
	return get_capture(self)->src ? Qtrue : Qfalse;
}

/* The device's period (callback size) in frames. */
static VALUE capture_period(VALUE self)
{
	return UINT2NUM(open_capture_device(self)->capture.internalPeriodSizeInFrames);
}

/* The number of periods in the device's own buffer. */
static VALUE capture_periods(VALUE self)
{
	return UINT2NUM(open_capture_device(self)->capture.internalPeriods);
}

/* The name of the device. */
static VALUE capture_device_name(VALUE self)
{
	return rb_utf8_str_new_cstr(open_capture_device(self)->capture.name);
}

/* The backend in use, as a Symbol. */
static VALUE capture_backend(VALUE self)
{
	return backend_to_sym(open_capture_device(self)->pContext->backend);
}

/* The number of channels. */
static VALUE capture_channels(VALUE self)
{
	return INT2NUM(get_capture(self)->channels);
}

/* The most device frames kept waiting for #read. */
static VALUE capture_queue_limit(VALUE self)
{
	return SIZET2NUM(get_capture(self)->queue_limit);
}

/*
 * call-seq:
 *   capture.stats -> { queued:, frames_captured:, overruns:, skipped: }
 *
 * :queued device frames are waiting for #read (plus resampled frames
 * pending); :frames_captured counts every frame the device captured (its
 * clock); :overruns counts callbacks that found the ring full (audio
 * lost); :skipped counts frames #read skipped to stay near real time.
 */
static VALUE capture_stats(VALUE self)
{
	struct capture *c = get_capture(self);

	VALUE h = rb_hash_new();
	rb_hash_aset(h, ID2SYM(rb_intern("queued")), SIZET2NUM(captured_frames(c)));
	rb_hash_aset(h, ID2SYM(rb_intern("pending")), SIZET2NUM(c->pending_count));
	rb_hash_aset(h, ID2SYM(rb_intern("frames_captured")), SIZET2NUM(atomic_load(&c->frames_captured)));
	rb_hash_aset(h, ID2SYM(rb_intern("overruns")), SIZET2NUM(atomic_load(&c->overruns)));
	rb_hash_aset(h, ID2SYM(rb_intern("skipped")), SIZET2NUM(c->skipped));

	return h;
}

void Init_fast_audio(void)
{
	VALUE mb = rb_define_module("MB");
	VALUE sound = rb_define_module_under(mb, "Sound");
	VALUE fast_audio = rb_define_module_under(sound, "FastAudio");

	cError = rb_define_class_under(fast_audio, "Error", rb_eRuntimeError);

	rb_define_const(fast_audio, "MINIAUDIO_VERSION", rb_str_freeze(rb_str_new_cstr(MA_VERSION_STRING)));
	rb_define_module_function(fast_audio, "enabled_backends", ruby_enabled_backends, 0);
	rb_define_module_function(fast_audio, "devices", ruby_devices, 2);

	VALUE playback = rb_define_class_under(fast_audio, "Playback", rb_cObject);
	rb_define_alloc_func(playback, playback_alloc);
	rb_define_method(playback, "initialize", playback_initialize, 13);
	rb_define_method(playback, "max_queue", playback_max_queue, 0);
	rb_define_method(playback, "queue_limit=", playback_set_queue_limit, 1);
	rb_define_method(playback, "write", playback_write, 1);
	rb_define_method(playback, "close", playback_close, 0);
	rb_define_method(playback, "closed?", playback_closed, 0);
	rb_define_method(playback, "sample_rate", playback_sample_rate, 0);
	rb_define_method(playback, "device_rate", playback_device_rate, 0);
	rb_define_method(playback, "resampling?", playback_resampling, 0);
	rb_define_method(playback, "period", playback_period, 0);
	rb_define_method(playback, "periods", playback_periods, 0);
	rb_define_method(playback, "device_name", playback_device_name, 0);
	rb_define_method(playback, "backend", playback_backend, 0);
	rb_define_method(playback, "device_channels", playback_device_channels, 0);
	rb_define_method(playback, "queue_limit", playback_queue_limit, 0);
	rb_define_method(playback, "stats", playback_stats, 0);
	rb_define_method(playback, "captured", playback_captured, 0);

	VALUE capture = rb_define_class_under(fast_audio, "Capture", rb_cObject);
	rb_define_alloc_func(capture, capture_alloc);
	rb_define_method(capture, "initialize", capture_initialize, 10);
	rb_define_method(capture, "read", capture_read, 1);
	rb_define_method(capture, "close", capture_close, 0);
	rb_define_method(capture, "closed?", capture_closed, 0);
	rb_define_method(capture, "sample_rate", capture_sample_rate, 0);
	rb_define_method(capture, "device_rate", capture_device_rate, 0);
	rb_define_method(capture, "resampling?", capture_resampling, 0);
	rb_define_method(capture, "period", capture_period, 0);
	rb_define_method(capture, "periods", capture_periods, 0);
	rb_define_method(capture, "device_name", capture_device_name, 0);
	rb_define_method(capture, "backend", capture_backend, 0);
	rb_define_method(capture, "channels", capture_channels, 0);
	rb_define_method(capture, "queue_limit", capture_queue_limit, 0);
	rb_define_method(capture, "stats", capture_stats, 0);
}
