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

# RtMidi's own C++ shows -Wall -Wextra warnings but isn't held to -Werror,
# so new compiler or SDK warnings in vendored code never break the build;
# only the wrapper (fast_midi.c) is held to -Werror.
$CXXFLAGS = "#{$CXXFLAGS} -std=c++11 -O2 -Wall -Wextra"

# RtMidi's CoreMIDI send uses a variable-length array (a clang extension in
# C++; harmless), which clang 18+ warns about.  Older compilers don't know
# the flag, so add it only if it compiles.
vla_flag = '-Wno-vla-cxx-extension'
$CXXFLAGS << " #{vla_flag}" if try_compile('int main(void) { return 0; }', "-Werror #{vla_flag}")

with_cflags("#{$CFLAGS} -O2 -ggdb3 -Wall -Wextra -Werror -Wno-unused-parameter #{ENV['EXTRACFLAGS']} -std=gnu11") do
  create_makefile('mb/sound/fast_midi')
end
