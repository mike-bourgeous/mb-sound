# fast_midi: live MIDI through RtMidi

`fast_midi.c` wraps [RtMidi](https://github.com/thestk/rtmidi) through its C
API for `MB::Sound::MIDI::Input` and `MB::Sound::MIDI::Output`.  RtMidi is
vendored here, unmodified, at version 6.0.0:

| File | From the RtMidi release |
| --- | --- |
| `RtMidi.cpp`, `RtMidi.h` | the library |
| `rtmidi_c.cpp`, `rtmidi_c.h` | the C API that `fast_midi.c` calls |
| `RtMidi-LICENSE` | `LICENSE` |

Keep the vendored files unmodified so updates stay a plain copy; work around
problems in `fast_midi.c` or `extconf.rb` instead (e.g. the
`-Wno-vla-cxx-extension` flag for clang).

## Updating RtMidi manually

1. Download the release from <https://github.com/thestk/rtmidi/releases> (or
   check out its tag) and read its release notes for C API changes.
2. Copy the five files above over the ones here (`LICENSE` becomes
   `RtMidi-LICENSE`).  `git diff --stat` should show only those files.
3. Check the C API that `fast_midi.c` uses: compare the old and new
   `rtmidi_c.h` (`git diff ext/mb/sound/fast_midi/rtmidi_c.h`) for changes
   to these functions: `rtmidi_get_compiled_api`, `rtmidi_api_name`,
   `rtmidi_compiled_api_by_name`, `rtmidi_get_version`, `rtmidi_in_create`,
   `rtmidi_out_create`, `rtmidi_in_free`, `rtmidi_out_free`,
   `rtmidi_open_port`, `rtmidi_open_virtual_port`, `rtmidi_close_port`,
   `rtmidi_get_port_count`, `rtmidi_get_port_name`,
   `rtmidi_in_get_current_api`, `rtmidi_out_get_current_api`,
   `rtmidi_in_ignore_types`, `rtmidi_in_get_message`, and
   `rtmidi_out_send_message`.  Also check whether the `RtMidiWrapper` `msg`
   field still dangles after an error (see the comment at the top of
   `fast_midi.c`); if it's fixed, the wrapper could include it in errors.
4. Update the version in `spec/ext/mb/sound/fast_midi_spec.rb` (`RTMIDI_VERSION`
   comes from `rtmidi_get_version()`), the comments in `fast_midi.c` and
   `extconf.rb`, and CLAUDE.md's MIDI section.
5. Rebuild from scratch, so the Makefile picks up the new sources:

   ```sh
   rm -rf tmp/*/fast_midi
   bundle exec rake compile 2>&1 | grep -A3 -E "warning|error"
   ```

   RtMidi builds with `-Wall -Wextra` but not `-Werror`, so new warnings in
   its code print without failing the build.  Check whether the
   `-Wno-vla-cxx-extension` flag in `extconf.rb` is still needed (the
   variable-length array in `MidiOutCore::sendMessage`).
6. Test:
   - `bundle exec rspec spec/ext/mb/sound/fast_midi_spec.rb spec/lib/mb/sound/midi`
     (needs `jackd` for the specs that send real messages through a dummy
     JACK server; they skip without it).
   - `bundle exec rake memcheck`, then check whether the
     `rtmidi-6.0.0-MidiOutJack-connect-...` suppression in
     `spec/valgrind/ruby.supp` is still needed; rename it for the new version
     if so.
   - Build on macOS too (CoreMIDI code only compiles there, with clang), and
     play a synth or run `bin/midi/midi_events.rb` with a real MIDI device
     on each platform.
