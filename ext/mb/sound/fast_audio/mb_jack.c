/*
 * The shared JACK client (see mb_jack.h).
 *
 * (C)2026 Mike Bourgeous
 */
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <dlfcn.h>

#include "mb_jack.h"

// libjack's types, declared here so no JACK headers are needed
typedef struct jack_client_t jack_client_t;
typedef struct jack_port_t jack_port_t;
typedef uint32_t jack_nframes_t;
typedef struct {
	jack_nframes_t time;
	size_t size;
	uint8_t *buffer;
} jack_midi_event_t;

#define JACK_NO_START_SERVER 0x01

static struct {
	void *lib;

	jack_client_t *(*client_open)(const char *name, int options, int *status, ...);
	int (*client_close)(jack_client_t *client);
	int (*activate)(jack_client_t *client);
	int (*set_process_callback)(jack_client_t *client, int (*callback)(jack_nframes_t, void *), void *arg);
	void (*on_shutdown)(jack_client_t *client, void (*callback)(void *), void *arg);
	jack_nframes_t (*get_sample_rate)(jack_client_t *client);
	jack_nframes_t (*get_buffer_size)(jack_client_t *client);
	char *(*get_client_name)(jack_client_t *client);
	jack_port_t *(*port_register)(jack_client_t *client, const char *name, const char *type, unsigned long flags, unsigned long buffer_size);
	int (*port_unregister)(jack_client_t *client, jack_port_t *port);
	void *(*port_get_buffer)(jack_port_t *port, jack_nframes_t nframes);
	const char *(*port_name)(const jack_port_t *port);
	const char **(*port_get_connections)(const jack_port_t *port);
	jack_port_t *(*port_by_name)(jack_client_t *client, const char *name);
	const char **(*port_get_all_connections)(const jack_client_t *client, const jack_port_t *port);
	const char **(*get_ports)(jack_client_t *client, const char *pattern, const char *type, unsigned long flags);
	void (*free)(void *ptr);
	int (*connect)(jack_client_t *client, const char *source, const char *destination);
	int (*disconnect)(jack_client_t *client, const char *source, const char *destination);
	jack_nframes_t (*last_frame_time)(const jack_client_t *client);
	uint32_t (*midi_get_event_count)(void *buffer);
	int (*midi_event_get)(jack_midi_event_t *event, void *buffer, uint32_t index);
	void (*midi_clear_buffer)(void *buffer);
	int (*midi_event_write)(void *buffer, jack_nframes_t time, const uint8_t *data, size_t size);
	void (*set_error_function)(void (*func)(const char *));
	void (*set_info_function)(void (*func)(const char *));
} jack;

// The attached units, swapped as a whole (see mb_jack.h)
struct unit_list {
	int count;
	struct mb_jack_unit *units[MB_JACK_MAX_UNITS];
};

static jack_client_t *client;
static pid_t client_pid;
static _Atomic int client_lost; // the server shut down or dropped us
static _Atomic(struct unit_list *) active;
static _Atomic size_t cycles_started;
static _Atomic size_t cycles_done;
static pthread_mutex_t change_lock = PTHREAD_MUTEX_INITIALIZER;

static void jack_silent(const char *msg)
{
	(void)msg;
}

static void jack_stderr(const char *msg)
{
	fprintf(stderr, "%s\n", msg);
}

#define LOAD(field, symbol) \
	do { \
		*(void **)&jack.field = dlsym(jack.lib, symbol); \
		if (jack.field == NULL) { \
			return -1; \
		} \
	} while (0)

int mb_jack_load(void)
{
	static int loaded = 0;
	static const char *names[] = { "libjack.so.0", "libjack.so", "libjack.0.dylib", "libjack.dylib" };

	if (loaded) {
		return loaded > 0 ? 0 : -1;
	}

	for (size_t i = 0; jack.lib == NULL && i < sizeof(names) / sizeof(names[0]); i++) {
		// Kept open: RtMidi may also use libjack, and unloading it isn't safe
		jack.lib = dlopen(names[i], RTLD_NOW | RTLD_GLOBAL);
	}

	loaded = -1;
	if (jack.lib == NULL) {
		return -1;
	}

	LOAD(client_open, "jack_client_open");
	LOAD(client_close, "jack_client_close");
	LOAD(activate, "jack_activate");
	LOAD(set_process_callback, "jack_set_process_callback");
	LOAD(on_shutdown, "jack_on_shutdown");
	LOAD(get_sample_rate, "jack_get_sample_rate");
	LOAD(get_buffer_size, "jack_get_buffer_size");
	LOAD(get_client_name, "jack_get_client_name");
	LOAD(port_register, "jack_port_register");
	LOAD(port_unregister, "jack_port_unregister");
	LOAD(port_get_buffer, "jack_port_get_buffer");
	LOAD(port_name, "jack_port_name");
	LOAD(port_get_connections, "jack_port_get_connections");
	LOAD(port_by_name, "jack_port_by_name");
	LOAD(port_get_all_connections, "jack_port_get_all_connections");
	LOAD(get_ports, "jack_get_ports");
	LOAD(free, "jack_free");
	LOAD(connect, "jack_connect");
	LOAD(disconnect, "jack_disconnect");
	LOAD(last_frame_time, "jack_last_frame_time");
	LOAD(midi_get_event_count, "jack_midi_get_event_count");
	LOAD(midi_event_get, "jack_midi_event_get");
	LOAD(midi_clear_buffer, "jack_midi_clear_buffer");
	LOAD(midi_event_write, "jack_midi_event_write");
	LOAD(set_error_function, "jack_set_error_function");
	LOAD(set_info_function, "jack_set_info_function");

	loaded = 1;
	return 0;
}

static void quiet(int on)
{
	jack.set_error_function(on ? jack_silent : jack_stderr);
	jack.set_info_function(on ? jack_silent : jack_stderr);
}

int mb_jack_probe(void)
{
	if (mb_jack_load()) {
		return 0;
	}
	if (mb_jack_is_open()) {
		return 1;
	}

	quiet(1);
	int status = 0;
	jack_client_t *probe = jack.client_open("mb_sound_probe", JACK_NO_START_SERVER, &status);
	if (probe != NULL) {
		jack.client_close(probe);
	}
	quiet(0);

	return probe != NULL;
}

// JACK's realtime thread
static int process(jack_nframes_t nframes, void *arg)
{
	(void)arg;

	atomic_fetch_add(&cycles_started, 1);
	struct unit_list *list = atomic_load(&active);
	if (list != NULL) {
		for (int i = 0; i < list->count; i++) {
			list->units[i]->process(list->units[i], nframes);
		}
	}
	atomic_fetch_add(&cycles_done, 1);

	return 0;
}

// Tells every attached unit that the client is gone
static void notify_shutdown(struct unit_list *list)
{
	if (list != NULL) {
		for (int i = 0; i < list->count; i++) {
			if (list->units[i]->shutdown) {
				list->units[i]->shutdown(list->units[i]);
			}
		}
	}
}

static void on_shutdown(void *arg)
{
	(void)arg;

	atomic_store(&client_lost, 1);
	notify_shutdown(atomic_load(&active));
}

int mb_jack_is_open(void)
{
	return client != NULL && client_pid == getpid() && !atomic_load(&client_lost);
}

const char *mb_jack_open(const char *name)
{
	if (mb_jack_load()) {
		return "Could not load libjack";
	}
	if (client != NULL && client_pid != getpid()) {
		// Opened before a fork; the child has no JACK connection
		client = NULL;
		atomic_store(&active, NULL);
	}
	if (client != NULL) {
		return atomic_load(&client_lost) ? "The JACK server closed the connection" : NULL;
	}

	quiet(1);
	int status = 0;
	jack_client_t *c = jack.client_open(name, JACK_NO_START_SERVER, &status);
	quiet(0);
	if (c == NULL) {
		return "Could not connect to a JACK server (is jackd or PipeWire running?)";
	}

	atomic_store(&client_lost, 0);
	atomic_store(&active, NULL);
	if (jack.set_process_callback(c, process, NULL) != 0) {
		jack.client_close(c);
		return "Could not set the JACK process callback";
	}
	jack.on_shutdown(c, on_shutdown, NULL);
	if (jack.activate(c) != 0) {
		jack.client_close(c);
		return "Could not activate the JACK client";
	}

	client = c;
	client_pid = getpid();
	return NULL;
}

// Waits (up to a second) until every process cycle that might have seen the
// old unit list has finished.  Call after swapping the list.
static void wait_for_cycles(void)
{
	size_t started = atomic_load(&cycles_started);
	for (int i = 0; i < 2000 && atomic_load(&cycles_done) < started; i++) {
		struct timespec ts = { 0, 500000 };
		nanosleep(&ts, NULL);
	}
}

// Replaces the unit list with a copy that adds +add+ or removes +remove+.
static void change_units(struct mb_jack_unit *add, struct mb_jack_unit *remove)
{
	struct unit_list *old = atomic_load(&active);
	struct unit_list *list = calloc(1, sizeof(*list));
	if (list == NULL) {
		return;
	}

	if (old != NULL) {
		for (int i = 0; i < old->count; i++) {
			if (old->units[i] != remove) {
				list->units[list->count++] = old->units[i];
			}
		}
	}
	if (add != NULL && list->count < MB_JACK_MAX_UNITS) {
		list->units[list->count++] = add;
	}

	atomic_store(&active, list);
	if (old != NULL) {
		if (!atomic_load(&client_lost)) {
			wait_for_cycles();
		}
		free(old);
	}
}

void mb_jack_close(void)
{
	if (client == NULL || client_pid != getpid()) {
		client = NULL;
		return;
	}

	pthread_mutex_lock(&change_lock);
	jack_client_t *c = client;
	client = NULL;
	jack.client_close(c); // stops the process thread
	struct unit_list *list = atomic_exchange(&active, NULL);
	notify_shutdown(list);
	if (list != NULL) {
		for (int i = 0; i < list->count; i++) {
			list->units[i]->attached = 0;
			list->units[i]->port_count = 0;
		}
		free(list);
	}
	pthread_mutex_unlock(&change_lock);
}

const char *mb_jack_client_name(void)
{
	return mb_jack_is_open() ? jack.get_client_name(client) : NULL;
}

uint32_t mb_jack_sample_rate(void)
{
	return mb_jack_is_open() ? jack.get_sample_rate(client) : 0;
}

uint32_t mb_jack_buffer_size(void)
{
	return mb_jack_is_open() ? jack.get_buffer_size(client) : 0;
}

size_t mb_jack_cycles(void)
{
	return atomic_load(&cycles_done);
}

const char *mb_jack_register(struct mb_jack_unit *unit, const char **names, int count, int midi, int output)
{
	if (!mb_jack_is_open()) {
		return "The JACK client is not open";
	}
	if (count < 0 || unit->port_count + count > MB_JACK_MAX_PORTS) {
		return "Too many JACK ports";
	}

	pthread_mutex_lock(&change_lock);
	int first = unit->port_count;
	for (int i = 0; i < count; i++) {
		jack_port_t *port = jack.port_register(client, names[i], midi ? MB_JACK_MIDI_TYPE : MB_JACK_AUDIO_TYPE,
				output ? MB_JACK_PORT_IS_OUTPUT : MB_JACK_PORT_IS_INPUT, 0);
		if (port == NULL) {
			for (int k = first; k < unit->port_count; k++) {
				jack.port_unregister(client, unit->ports[k]);
			}
			unit->port_count = first;
			pthread_mutex_unlock(&change_lock);
			return "Could not register a JACK port (is the name taken?)";
		}
		unit->ports[unit->port_count++] = port;
	}
	pthread_mutex_unlock(&change_lock);

	return NULL;
}

void mb_jack_attach(struct mb_jack_unit *unit)
{
	pthread_mutex_lock(&change_lock);
	if (!unit->attached && mb_jack_is_open()) {
		change_units(unit, NULL);
		unit->attached = 1;
	}
	pthread_mutex_unlock(&change_lock);
}

void mb_jack_detach(struct mb_jack_unit *unit)
{
	pthread_mutex_lock(&change_lock);
	if (client != NULL && client_pid == getpid()) {
		if (unit->attached) {
			change_units(NULL, unit);
		}
		if (!atomic_load(&client_lost)) {
			for (int i = 0; i < unit->port_count; i++) {
				jack.port_unregister(client, unit->ports[i]);
			}
		}
	}
	unit->attached = 0;
	unit->port_count = 0;
	pthread_mutex_unlock(&change_lock);
}

void *mb_jack_port_buffer(void *port, uint32_t nframes)
{
	return jack.port_get_buffer(port, nframes);
}

uint32_t mb_jack_last_frame_time(void)
{
	return jack.last_frame_time(client);
}

uint32_t mb_jack_midi_count(void *buffer)
{
	return jack.midi_get_event_count(buffer);
}

int mb_jack_midi_get(void *buffer, uint32_t index, uint32_t *time, const uint8_t **data, size_t *size)
{
	jack_midi_event_t event;
	int result = jack.midi_event_get(&event, buffer, index);
	if (result == 0) {
		*time = event.time;
		*data = event.buffer;
		*size = event.size;
	}
	return result;
}

void mb_jack_midi_clear(void *buffer)
{
	jack.midi_clear_buffer(buffer);
}

int mb_jack_midi_write(void *buffer, uint32_t time, const uint8_t *data, size_t size)
{
	return jack.midi_event_write(buffer, time, data, size);
}

const char *mb_jack_port_name(void *port)
{
	return jack.port_name(port);
}

const char **mb_jack_get_ports(const char *pattern, const char *type, unsigned long flags)
{
	return mb_jack_is_open() ? jack.get_ports(client, pattern, type, flags) : NULL;
}

const char **mb_jack_port_connections(void *port)
{
	return jack.port_get_connections(port);
}

const char **mb_jack_connections_by_name(const char *name)
{
	if (!mb_jack_is_open()) {
		return NULL;
	}
	jack_port_t *port = jack.port_by_name(client, name);
	return port == NULL ? NULL : jack.port_get_all_connections(client, port);
}

void mb_jack_free_list(const char **list)
{
	if (list != NULL) {
		jack.free((void *)list);
	}
}

int mb_jack_connect(const char *source, const char *destination)
{
	return mb_jack_is_open() ? jack.connect(client, source, destination) : -1;
}

int mb_jack_disconnect(const char *source, const char *destination)
{
	return mb_jack_is_open() ? jack.disconnect(client, source, destination) : -1;
}
