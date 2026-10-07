#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A simple sine wave synthesizer.  Velocity sets the level over a 20 dB range
# (a sine has no brightness to change).
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid sine.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  s = midi.synth(voices: 4) { |v|
    v.hz * v.amp_env(0.002, 0.05, -10.db, 0.1, sensitivity: -20.db..0.db)
  }

  # Makeup gain after the saturation: velocity 96 at about -24 dB RMS, like
  # the other synth scripts
  s.softclip(0.8, 0.95).oversample(2) * 3.3.db
}
