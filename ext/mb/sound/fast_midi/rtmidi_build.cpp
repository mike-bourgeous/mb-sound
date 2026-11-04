/*
 * Builds the vendored RtMidi.cpp (unmodified; see README.md) in this
 * translation unit, plus a helper that needs RtMidi's private JACK data.
 *
 * RtMidi's JACK closePort unregisters its port while the client is still
 * active, which races libjack's notification thread: jack_port_unregister
 * erases the port from the client's port list while that thread may be
 * walking the list in HandleLatencyCallback after a graph change anywhere on
 * the server, and the thread then reads the freed node and crashes (a spec
 * process segfaulted that way, 2026-10-12; JACK2 issue #216: deactivate a
 * client before unregistering its ports).  fast_midi.c calls
 * mb_rtmidi_jack_release before closing a JACK port and freeing the device.
 *
 * A client the server dropped (the server exited, or a stalled server closed
 * its connection) must never be touched again: once any client of a process
 * loses its server, libjack's next jack_client_open in that process ("Jack
 * server was closed but clients are still allocated, cleanup...") closes and
 * deletes every client the process still has, so a later jack_deactivate or
 * jack_client_close reads a deleted client (a spec process segfaulted in
 * jack_deactivate that way, batch 13, 2026-11-04: its dummy server stalled
 * under load and dropped the output's client, the next input's open cleaned
 * it up, and the output's close crashed; fix-flaky-1104).  RtMidi registers
 * no shutdown callback, so jack_activate and jack_client_close are wrapped
 * for RtMidi.cpp alone (macros around the #include, the vendored file
 * unchanged): the activation registers a jack_on_info_shutdown callback that
 * marks the client lost, mb_rtmidi_jack_release skips a lost client's
 * deactivation and port, and the close skips a lost client (libjack frees it
 * at the process's next jack_client_open; until then it stays allocated
 * there).  Not covered: a client that libjack's cleanup deletes after another
 * client of the process lost the server while its own connection stayed up
 * (not seen; nothing public tells when libjack does that).
 *
 * (C)2026 Mike Bourgeous
 */
#if defined(__UNIX_JACK__)
#include <pthread.h>
#include <jack/jack.h>

namespace {
	// The JACK clients RtMidi activated, and whether their server dropped
	// them (written from libjack's thread by on_info_shutdown).
	struct WatchedClient {
		jack_client_t *client;
		int lost;
		WatchedClient *next;
	};

	pthread_mutex_t watched_lock = PTHREAD_MUTEX_INITIALIZER;
	WatchedClient *watched = NULL;

	// (under watched_lock)
	WatchedClient *find_watched(jack_client_t *client)
	{
		for (WatchedClient *w = watched; w != NULL; w = w->next) {
			if (w->client == client) {
				return w;
			}
		}
		return NULL;
	}

	void on_info_shutdown(jack_status_t code, const char *reason, void *arg)
	{
		(void)code;
		(void)reason;
		pthread_mutex_lock(&watched_lock);
		WatchedClient *w = find_watched(static_cast<jack_client_t *>(arg));
		if (w != NULL) {
			w->lost = 1;
		}
		pthread_mutex_unlock(&watched_lock);
	}

	// True if the server dropped +client+ (or nothing watches it: a client
	// RtMidi didn't activate is used as RtMidi uses it).
	int client_lost(jack_client_t *client)
	{
		pthread_mutex_lock(&watched_lock);
		WatchedClient *w = find_watched(client);
		int lost = w != NULL && w->lost;
		pthread_mutex_unlock(&watched_lock);
		return lost;
	}

	// Stops watching +client+.  Returns whether it was lost.
	int forget_client(jack_client_t *client)
	{
		int lost = 0;
		pthread_mutex_lock(&watched_lock);
		for (WatchedClient **p = &watched; *p != NULL; p = &(*p)->next) {
			if ((*p)->client == client) {
				WatchedClient *w = *p;
				lost = w->lost;
				*p = w->next;
				delete w;
				break;
			}
		}
		pthread_mutex_unlock(&watched_lock);
		return lost;
	}

	// RtMidi's jack_activate: watches the client for a shutdown first
	// (callbacks can only be set on an inactive client).
	int watched_activate(jack_client_t *client)
	{
		pthread_mutex_lock(&watched_lock);
		WatchedClient *w = find_watched(client);
		if (w == NULL) {
			w = new WatchedClient{ client, 0, watched };
			watched = w;
		}
		w->lost = 0; // (an address libjack reused for a new client)
		pthread_mutex_unlock(&watched_lock);
		jack_on_info_shutdown(client, on_info_shutdown, client);
		return jack_activate(client);
	}

	// RtMidi's jack_client_close: skips a lost client (see the top).
	int watched_client_close(jack_client_t *client)
	{
		if (forget_client(client)) {
			return 0;
		}
		return jack_client_close(client);
	}
}

#define jack_activate watched_activate
#define jack_client_close watched_client_close
#endif

#include "RtMidi.cpp"

#if defined(__UNIX_JACK__)
#undef jack_activate
#undef jack_client_close
#endif

#include "rtmidi_c.h"

#include "rtmidi_build.h"

namespace {
	// Pointers to protected members, formed in derived classes (the
	// standard way to read them without changing RtMidi's headers)
	struct RtMidiPeek : RtMidi {
		static MidiApi *api(RtMidi *midi) { return midi->*(&RtMidiPeek::rtapi_); }
	};
	struct MidiApiPeek : MidiApi {
		static void *data(MidiApi *api) { return api->*(&MidiApiPeek::apiData_); }
	};
}

extern "C" void mb_rtmidi_jack_release(RtMidiPtr device, int input)
{
#if defined(__UNIX_JACK__)
	if (device == NULL || device->ptr == NULL) {
		return;
	}

	RtMidi *midi = input ? static_cast<RtMidi *>(static_cast<RtMidiIn *>(device->ptr)) :
		static_cast<RtMidi *>(static_cast<RtMidiOut *>(device->ptr));
	MidiApi *api = RtMidiPeek::api(midi);
	if (api == NULL || api->getCurrentApi() != RtMidi::UNIX_JACK) {
		return;
	}

	JackMidiData *data = static_cast<JackMidiData *>(MidiApiPeek::data(api));
	if (data == NULL || data->client == NULL) {
		return;
	}
	if (client_lost(data->client)) {
		// (the server dropped it: its port went with it, and libjack may
		// have deleted the client; RtMidi's closePort then finds no port,
		// and its jack_client_close skips the client)
		data->port = NULL;
		return;
	}

	// Deactivating returns after any notification the client was handling
	// and stops its process thread, so unregistering is safe and RtMidi's
	// closePort (which would wait up to 1 s for a process cycle that no
	// longer comes) finds no port.  The device is freed right after this.
	jack_deactivate(data->client);
	if (data->port != NULL) {
		jack_port_unregister(data->client, data->port);
		data->port = NULL;
	}
#else
	(void)device;
	(void)input;
#endif
}
