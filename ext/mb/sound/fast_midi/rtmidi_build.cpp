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
 * (C)2026 Mike Bourgeous
 */
#include "RtMidi.cpp"
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
