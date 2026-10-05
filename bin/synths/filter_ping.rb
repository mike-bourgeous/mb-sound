#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A simple filter pinging synthesizer.
#
# Each note-on sends an impulse (stronger for higher velocities) into a
# resonant lowpass tuned to the note, so the filter rings at the note's
# pitch.  CC 1 (the mod wheel) raises the filter's quality (longer rings),
# and CC 71 (resonance) scales it.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid ping.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script { |midi|
  midi.synth(voices: 4) { |v|
    quality = v.quality(v.cc(1, range: 50..150, name: 'Ping quality'))

    # Low notes ring louder for longer, so they get less gain: +48 dB at
    # note 0 down to -44 dB at note 127
    gain = 10 ** ((48 - v.number * (92 / 127.0)) / 20)

    # The voice has no envelope, so its trigger ends with a MIDI file, and
    # ringdown keeps feeding the filter silence after that so it rings out
    ping = v.trigger.ringdown * 25

    (ping.filter(:lowpass, cutoff: v.freq, quality: quality) * gain).softclip
  }.softclip(0.8, 0.95).oversample(3)
}
