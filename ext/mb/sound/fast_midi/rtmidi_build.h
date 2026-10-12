/*
 * Helpers built with the vendored RtMidi (see rtmidi_build.cpp).
 *
 * (C)2026 Mike Bourgeous
 */
#ifndef MB_RTMIDI_BUILD_H
#define MB_RTMIDI_BUILD_H

#include "rtmidi_c.h"

#ifdef __cplusplus
extern "C" {
#endif

// If +device+ (an RtMidiIn if +input+, else an RtMidiOut) uses RtMidi's
// JACK API: deactivates its client and unregisters its port, so freeing it
// next can't race libjack's notification thread.  Call only right before
// rtmidi_in_free/rtmidi_out_free.
void mb_rtmidi_jack_release(RtMidiPtr device, int input);

#ifdef __cplusplus
}
#endif

#endif
