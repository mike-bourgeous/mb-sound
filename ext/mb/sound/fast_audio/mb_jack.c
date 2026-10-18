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
	int (*deactivate)(jack_client_t *client);
	int (*set_process_callback)(jack_client_t *client, int (*callback)(jack_nframes_t, void *), void *arg);
	void (*on_shutdown)(jack_client_t *client, void (*callback)(void *), void *arg);
	jack_nframes_t (*get_sample_rate)(jack_client_t *client);
	jack_nframes_t (*get_buffer_size)(jack_client_t *client);
	char *(*get_client_name)(jack_client_t *client);
	jack_port_t *(*port_register)(jack_client_t *client, const char *name, const char *type, unsigned long flags, unsigned long buffer_size);
	int (*port_unregister)(jack_client_t *client, jack_port_t *port);
	int (*port_disconnect)(jack_client_t *client, jack_port_t *port);
	int (*port_rename)(jack_client_t *client, jack_port_t *port, const char *name); // optional
	int (*port_set_name)(jack_port_t *port, const char *name); // optional, older
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

// Cycles the server ran this client late, in asynchronous mode (jackd's
// default without --sync): a client still busy when a cycle starts misses
// it (skipped: the frame time jumps by more than a period, and what other
// clients' outputs held in it is gone), or gets two callbacks for one cycle
// (repeated: the frame time didn't move; see midi_in_process).  Counted
// for MB::Sound::Jack.info; the process thread owns prev_frame.
static _Atomic size_t cycles_skipped;
static _Atomic size_t cycles_repeated;
static uint32_t prev_frame;
static int have_prev_frame;

// mb_jack_stall (specs): sleep stall_us at the start of every
// stall_every-th callback, before anything reads the frame time, like a
// process thread the system didn't schedule in time
static _Atomic unsigned stall_us;
static _Atomic unsigned stall_every;
static unsigned stall_count; // process thread only

// mb_jack_frame_log (specs): for each callback, the frame time it read
// and the frame time once its units ran (later if the server started the
// next cycle meanwhile), so a spec can tell which server cycles this client
// ran, and in which its port reads and writes may have mixed with the next
// cycle's.  The process thread fills pairs below MB_JACK_FRAME_LOG_MAX and
// publishes the count; readers copy only that many.
static uint32_t frame_log[MB_JACK_FRAME_LOG_MAX][2];
static _Atomic size_t frame_log_len;
static _Atomic int frame_log_on;

static pthread_mutex_t change_lock = PTHREAD_MUTEX_INITIALIZER;

// Released ports, kept registered for reuse (see mb_jack.h: libjack can't
// unregister a port of an active client safely).  Guarded by change_lock.
struct spare {
	jack_port_t *port;
	int midi;
	int output;
};
static struct spare *spares;
static int spare_count;
static int spare_capacity;
static unsigned long spare_serial; // numbers the spare names
static int held_ports; // ports registered for units (not spares)

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
	LOAD(deactivate, "jack_deactivate");
	LOAD(set_process_callback, "jack_set_process_callback");
	LOAD(on_shutdown, "jack_on_shutdown");
	LOAD(get_sample_rate, "jack_get_sample_rate");
	LOAD(get_buffer_size, "jack_get_buffer_size");
	LOAD(get_client_name, "jack_get_client_name");
	LOAD(port_register, "jack_port_register");
	LOAD(port_unregister, "jack_port_unregister");
	LOAD(port_disconnect, "jack_port_disconnect");
	*(void **)&jack.port_rename = dlsym(jack.lib, "jack_port_rename");
	if (jack.port_rename == NULL) {
		*(void **)&jack.port_set_name = dlsym(jack.lib, "jack_port_set_name");
	}
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

/*
 * Ports are added at any time, but libjack (jackd2 1.9.22) can't remove a
 * port of an active client safely: jack_port_unregister erases the port
 * from the client's port list on the caller's thread while the client's
 * notification thread may be walking that list in HandleLatencyCallback
 * (sent after any graph change anywhere on the server), which then reads
 * the freed list node and crashes (a spec process segfaulted in that
 * thread, 2026-10-12; JACK2 issue #216, where JACK's maintainer says to
 * deactivate a client before unregistering ports).  So a released port is
 * disconnected, renamed to a spare name, and kept for the next port of its
 * kind; spares are unregistered only while the client is deactivated: here
 * once no unit holds a port (deactivating then interrupts nothing), and by
 * jack_client_close, which deactivates first.
 */

// Forgets the spare list (the client that owned the ports is gone).
static void forget_spares(void)
{
	free(spares);
	spares = NULL;
	spare_count = 0;
	spare_capacity = 0;
	held_ports = 0;
}

// Renames +port+ (without its client prefix); returns 0 on success.
static int rename_port(jack_port_t *port, const char *name)
{
	if (jack.port_rename != NULL) {
		return jack.port_rename(client, port, name);
	}
	if (jack.port_set_name != NULL) {
		return jack.port_set_name(port, name);
	}
	return -1;
}

// Disconnects +port+ and keeps it as a spare (unregistering it only if the
// spare list can't grow, which never happens in practice).
static void release_port(jack_port_t *port, int midi, int output)
{
	jack.port_disconnect(client, port);

	if (spare_count == spare_capacity) {
		int capacity = spare_capacity ? spare_capacity * 2 : 16;
		struct spare *grown = realloc(spares, sizeof(*spares) * capacity);
		if (grown == NULL) {
			jack.port_unregister(client, port);
			return;
		}
		spares = grown;
		spare_capacity = capacity;
	}

	char name[64];
	snprintf(name, sizeof(name), "spare_%s_%s_%lu", midi ? "midi" : "audio", output ? "out" : "in", ++spare_serial);
	rename_port(port, name);
	spares[spare_count++] = (struct spare){ .port = port, .midi = midi, .output = output };
}

// Unregisters every spare behind a deactivation, if nothing uses the client
// (no unit holds a port or is attached).  Call with change_lock held.
static void free_spares_while_idle(void)
{
	struct unit_list *list = atomic_load(&active);
	if (spare_count == 0 || held_ports > 0 || (list != NULL && list->count > 0)) {
		return;
	}

	// jack_deactivate returns after any notification the client was handling
	// (the server waits for its reply before taking the request), and an
	// inactive client skips latency notifications, so nothing walks the
	// port list while the ports go.
	if (jack.deactivate(client) != 0) {
		return;
	}
	for (int i = 0; i < spare_count; i++) {
		jack.port_unregister(client, spares[i].port);
	}
	spare_count = 0;
	if (jack.activate(client) != 0) {
		// Reported like a lost server; the next mb_jack_open after
		// mb_jack_close opens a new client
		atomic_store(&client_lost, 1);
	}
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

	unsigned stall = atomic_load_explicit(&stall_us, memory_order_relaxed);
	if (stall != 0 && ++stall_count % atomic_load_explicit(&stall_every, memory_order_relaxed) == 0) {
		struct timespec ts = { stall / 1000000, (stall % 1000000) * 1000L };
		nanosleep(&ts, NULL);
	}

	uint32_t frame = jack.last_frame_time(client);
	if (have_prev_frame && nframes > 0) {
		uint32_t delta = frame - prev_frame;
		if (delta == 0) {
			atomic_fetch_add_explicit(&cycles_repeated, 1, memory_order_relaxed);
		} else if (delta > nframes) {
			atomic_fetch_add_explicit(&cycles_skipped, delta / nframes - 1, memory_order_relaxed);
		}
	}
	prev_frame = frame;
	have_prev_frame = 1;

	struct unit_list *list = atomic_load(&active);
	if (list != NULL) {
		for (int i = 0; i < list->count; i++) {
			list->units[i]->process(list->units[i], nframes);
		}
	}

	if (atomic_load_explicit(&frame_log_on, memory_order_relaxed)) {
		size_t n = atomic_load_explicit(&frame_log_len, memory_order_relaxed);
		if (n < MB_JACK_FRAME_LOG_MAX) {
			frame_log[n][0] = frame;
			frame_log[n][1] = jack.last_frame_time(client);
			atomic_store_explicit(&frame_log_len, n + 1, memory_order_release);
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

// How long mb_jack_open keeps trying (ns) when a server it reached before
// doesn't answer or a new client can't activate: a starved machine
// stalls the server for a moment (live_source_spec's JACK group under
// parallel specs, 2026-10-18: "Could not activate the JACK client" on the
// reopen after a starved attempt; reproduced by stopping jackd for 0.3 s
// during a reopen).
#define MB_JACK_OPEN_RETRY_NS 3000000000LL

// Set once a client opened in this process (a server answered).
static int ever_opened;

static long long open_now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// One attempt of mb_jack_open: the client, or NULL with *error set.
static jack_client_t *open_attempt(const char *name, const char **error)
{
	quiet(1);
	int status = 0;
	jack_client_t *c = jack.client_open(name, JACK_NO_START_SERVER, &status);
	quiet(0);
	if (c == NULL) {
		*error = "Could not connect to a JACK server (is jackd or PipeWire running?)";
		return NULL;
	}

	atomic_store(&client_lost, 0);
	atomic_store(&active, NULL);
	atomic_store(&cycles_skipped, 0);
	atomic_store(&cycles_repeated, 0);
	have_prev_frame = 0; // no process thread yet
	atomic_store(&stall_us, 0); // a new client starts unstalled
	stall_count = 0;
	atomic_store(&frame_log_on, 0); // and unlogged
	atomic_store(&frame_log_len, 0);
	if (jack.set_process_callback(c, process, NULL) != 0) {
		jack.client_close(c);
		*error = "Could not set the JACK process callback";
		return NULL;
	}
	jack.on_shutdown(c, on_shutdown, NULL);
	if (jack.activate(c) != 0) {
		jack.client_close(c);
		*error = "Could not activate the JACK client";
		return NULL;
	}

	return c;
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
		forget_spares();
	}
	if (client != NULL) {
		return atomic_load(&client_lost) ? "The JACK server closed the connection" : NULL;
	}

	// A server that answered before (or one that answers but can't
	// activate the client yet) gets MB_JACK_OPEN_RETRY_NS to recover, with
	// growing pauses; without one, a missing server fails at once (so
	// backends without JACK fall through quickly)
	const char *error = NULL;
	long long deadline = open_now_ns() + MB_JACK_OPEN_RETRY_NS;
	long pause_ns = 20000000L;
	jack_client_t *c;
	while ((c = open_attempt(name, &error)) == NULL) {
		int reachable = ever_opened || strcmp(error, "Could not activate the JACK client") == 0;
		if (!reachable || open_now_ns() + pause_ns > deadline) {
			return error;
		}
		struct timespec ts = { 0, pause_ns };
		nanosleep(&ts, NULL);
		pause_ns = pause_ns * 2 > 250000000L ? 250000000L : pause_ns * 2;
	}

	client = c;
	client_pid = getpid();
	ever_opened = 1;
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
		forget_spares();
		return;
	}

	pthread_mutex_lock(&change_lock);
	jack_client_t *c = client;
	client = NULL;
	jack.client_close(c); // deactivates first, then stops the process thread and frees every port
	forget_spares();
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

void mb_jack_stall(unsigned microseconds, unsigned every)
{
	atomic_store(&stall_every, every);
	atomic_store(&stall_us, microseconds);
}

void mb_jack_frame_log_start(void)
{
	atomic_store(&frame_log_on, 0);
	atomic_store(&frame_log_len, 0);
	atomic_store(&frame_log_on, 1);
}

size_t mb_jack_frame_log_stop(const uint32_t (**frames)[2])
{
	atomic_store(&frame_log_on, 0);
	*frames = frame_log;
	return atomic_load_explicit(&frame_log_len, memory_order_acquire);
}

size_t mb_jack_cycles_skipped(void)
{
	return atomic_load(&cycles_skipped);
}

size_t mb_jack_cycles_repeated(void)
{
	return atomic_load(&cycles_repeated);
}

// Takes a spare port of the given kind for +name+: one already named +name+,
// else any renamed to +name+.  Returns NULL if there is none.
static jack_port_t *take_spare(const char *name, int midi, int output)
{
	int found = -1;
	for (int i = 0; i < spare_count && found < 0; i++) {
		if (spares[i].midi == midi && spares[i].output == output) {
			const char *full = jack.port_name(spares[i].port);
			const char *short_name = full ? strchr(full, ':') : NULL;
			if (short_name != NULL && strcmp(short_name + 1, name) == 0) {
				found = i;
			}
		}
	}
	for (int i = 0; i < spare_count && found < 0; i++) {
		if (spares[i].midi == midi && spares[i].output == output && rename_port(spares[i].port, name) == 0) {
			found = i;
		}
	}
	if (found < 0) {
		return NULL;
	}

	jack_port_t *port = spares[found].port;
	spares[found] = spares[--spare_count];
	return port;
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
		jack_port_t *port = take_spare(names[i], midi, output);
		if (port == NULL) {
			port = jack.port_register(client, names[i], midi ? MB_JACK_MIDI_TYPE : MB_JACK_AUDIO_TYPE,
					output ? MB_JACK_PORT_IS_OUTPUT : MB_JACK_PORT_IS_INPUT, 0);
		}
		if (port == NULL) {
			for (int k = first; k < unit->port_count; k++) {
				release_port(unit->ports[k], midi, output);
			}
			held_ports -= unit->port_count - first;
			unit->port_count = first;
			free_spares_while_idle();
			pthread_mutex_unlock(&change_lock);
			return "Could not register a JACK port (is the name taken?)";
		}
		unit->port_kinds[unit->port_count] = (midi ? MB_JACK_KIND_MIDI : 0) | (output ? MB_JACK_KIND_OUTPUT : 0);
		unit->ports[unit->port_count++] = port;
		held_ports++;
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
				int kind = unit->port_kinds[i];
				release_port(unit->ports[i], !!(kind & MB_JACK_KIND_MIDI), !!(kind & MB_JACK_KIND_OUTPUT));
			}
			held_ports -= unit->port_count;
			if (held_ports <= 0) {
				held_ports = 0;
				free_spares_while_idle();
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

// How long mb_jack_connect/mb_jack_disconnect wait for the graph to change.
#define CONNECT_WAIT_NS 200000000L

// True if +source+ is connected to +destination+ in JACK's current graph
// (also true if either port can't be found, so callers don't wait for it).
static int connected(const char *source, const char *destination)
{
	jack_port_t *src = jack.port_by_name(client, source);
	jack_port_t *dst = jack.port_by_name(client, destination);
	if (src == NULL || dst == NULL) {
		return 1;
	}

	const char *dst_name = jack.port_name(dst); // the full name, not an alias
	const char **list = jack.port_get_all_connections(client, src);
	int found = 0;
	for (int i = 0; list != NULL && list[i] != NULL && !found; i++) {
		found = strcmp(list[i], dst_name) == 0;
	}
	mb_jack_free_list(list);
	return found;
}

// jack_connect and jack_disconnect return once the server has queued the
// change, which takes effect (and shows in the port's connections) at the
// start of a later cycle: under load, 2 of 200 connections on the dummy
// server weren't listed yet right after jack_connect (up to 19 ms), and a
// message sent at once could miss the new connection.  So wait (up to
// CONNECT_WAIT_NS) until the graph shows the change.
static void wait_for_graph(const char *source, const char *destination, int want_connected)
{
	struct timespec start, now, pause = { 0, 1000000 };
	clock_gettime(CLOCK_MONOTONIC, &start);
	while (connected(source, destination) != want_connected) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		if ((now.tv_sec - start.tv_sec) * 1000000000L + (now.tv_nsec - start.tv_nsec) > CONNECT_WAIT_NS) {
			return;
		}
		nanosleep(&pause, NULL);
	}
}

int mb_jack_connect(const char *source, const char *destination)
{
	if (!mb_jack_is_open()) {
		return -1;
	}
	int result = jack.connect(client, source, destination);
	if (result == 0) {
		wait_for_graph(source, destination, 1);
	}
	return result;
}

int mb_jack_disconnect(const char *source, const char *destination)
{
	if (!mb_jack_is_open()) {
		return -1;
	}
	int result = jack.disconnect(client, source, destination);
	if (result == 0) {
		wait_for_graph(source, destination, 0);
	}
	return result;
}
