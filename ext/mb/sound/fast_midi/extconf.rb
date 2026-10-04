require 'mkmf'

# RtMidi 6.0.0 (vendored C++: RtMidi.cpp, rtmidi_c.cpp) with the MIDI
# backends available at build time: CoreMIDI on macOS (system frameworks,
# nothing to install); the ALSA sequencer on Linux (libasound2-dev), plus
# JACK MIDI when libjack is available (RtMidi never starts a JACK server).
if RUBY_PLATFORM =~ /darwin/
  $defs << '-D__MACOSX_CORE__'
  $LDFLAGS << ' -framework CoreMIDI -framework CoreAudio -framework CoreFoundation'
  $libs << ' -lc++'
else
  unless have_header('alsa/asoundlib.h') && have_library('asound', 'snd_seq_open')
    raise 'ALSA headers not found; please install libasound2-dev'
  end
  $defs << '-D__LINUX_ALSA__'

  if have_header('jack/jack.h') && have_library('jack', 'jack_client_open')
    $defs << '-D__UNIX_JACK__'
    $defs << '-DJACK_HAS_PORT_RENAME' if have_func('jack_port_rename', 'jack/jack.h')
  end

  $libs << ' -lstdc++'
end

have_library('pthread')

$CXXFLAGS = "#{$CXXFLAGS} -std=c++11 -O2"

# Only the wrapper (fast_midi.c) is held to -Werror; RtMidi's own C++ is
# compiled with the default C++ flags, unmodified.
with_cflags("#{$CFLAGS} -O2 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -std=gnu11") do
  create_makefile('mb/sound/fast_midi')
end
