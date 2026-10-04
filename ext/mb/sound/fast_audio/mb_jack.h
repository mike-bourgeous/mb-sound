/*
 * One JACK client per process for MB::Sound's JACK audio and MIDI, with
 * ports added and removed at any time (like the old JackFFI), so every
 * output, input, and MIDI port of a script is on one JACK (and PipeWire)
 * node.  libjack is loaded at run time, so no JACK headers are needed to
 * build, and the system's libjack is used (e.g. PipeWire's through
 * pipewire-jack's ld.so config).
 *
 * Users attach "units": a set of ports plus a process function that the
 * client's process callback runs every cycle on JACK's realtime thread.  The
 * list of attached units is an immutable snapshot swapped atomically; after
 * a swap, mb_jack_detach waits until no process cycle can still be using the
 * old list, so a detached unit may be freed.
 *
 * (C)2026 Mike Bourgeous
 */
#ifndef MB_JACK_H
#define MB_JACK_H

#include <stdint.h>
#include <stddef.h>

#define MB_JACK_MAX_PORTS 64
#define MB_JACK_MAX_UNITS 128

// Port flags (as in JACK's types.h)
#define MB_JACK_PORT_IS_INPUT 0x1
#define MB_JACK_PORT_IS_OUTPUT 0x2
#define MB_JACK_PORT_IS_PHYSICAL 0x4

#define MB_JACK_AUDIO_TYPE "32 bit float mono audio"
#define MB_JACK_MIDI_TYPE "8 bit raw midi"

struct mb_jack_unit;

// Called on JACK's realtime thread for every cycle while attached: no
// allocation, no blocking, no Ruby.
typedef void (*mb_jack_process_fn)(struct mb_jack_unit *unit, uint32_t nframes);

// Called (from a JACK thread) if the server shuts down or drops the client.
typedef void (*mb_jack_shutdown_fn)(struct mb_jack_unit *unit);

struct mb_jack_unit {
	mb_jack_process_fn process;
	mb_jack_shutdown_fn shutdown;
	void *user;

	void *ports[MB_JACK_MAX_PORTS];
	int port_count;
	int attached;
};

// Loads libjack; returns 0 on success.
int mb_jack_load(void);

// True if a JACK server accepts a client (opens and closes one without
// starting a server, with libjack's messages silenced).
int mb_jack_probe(void);

// Opens the shared client named +name+ if it isn't open yet (in this
// process).  Returns NULL on success, else a static error message.
const char *mb_jack_open(const char *name);

// True if the shared client is open in this process and the server hasn't
// dropped it.
int mb_jack_is_open(void);

// Detaches every unit and closes the client.
void mb_jack_close(void);

const char *mb_jack_client_name(void);
uint32_t mb_jack_sample_rate(void);
uint32_t mb_jack_buffer_size(void);
size_t mb_jack_cycles(void);

// Registers +count+ ports named +names+ on the shared client for +unit+
// (audio or MIDI, +output+ or input).  Returns NULL or an error message;
// on error no ports stay registered.
const char *mb_jack_register(struct mb_jack_unit *unit, const char **names, int count, int midi, int output);

// Starts and stops calling +unit+'s process function.  mb_jack_detach waits
// until the process thread is done with the unit, and unregisters its ports.
void mb_jack_attach(struct mb_jack_unit *unit);
void mb_jack_detach(struct mb_jack_unit *unit);

// For process functions
void *mb_jack_port_buffer(void *port, uint32_t nframes);
uint32_t mb_jack_last_frame_time(void);
uint32_t mb_jack_midi_count(void *buffer);
int mb_jack_midi_get(void *buffer, uint32_t index, uint32_t *time, const uint8_t **data, size_t *size);
void mb_jack_midi_clear(void *buffer);
int mb_jack_midi_write(void *buffer, uint32_t time, const uint8_t *data, size_t size);

// Port names and connections (not for the process thread).  Lists are
// NULL-terminated and freed with mb_jack_free_list.
const char *mb_jack_port_name(void *port);
const char **mb_jack_get_ports(const char *pattern, const char *type, unsigned long flags);
const char **mb_jack_port_connections(void *port);
const char **mb_jack_connections_by_name(const char *name);
void mb_jack_free_list(const char **list);
int mb_jack_connect(const char *source, const char *destination);
int mb_jack_disconnect(const char *source, const char *destination);

#endif
