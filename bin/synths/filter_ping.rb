#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A simple filter pinging synthesizer.
#
# Each note-on sends an impulse (stronger for higher velocities) into a
# resonant lowpass tuned to the note, so the filter rings at the note's
# pitch.  -M resonator rings a GraphNode::Resonator (`trigger.ping`)
# instead: a pure decaying sine at the velocity's level, whose pitch can
# bend without the level pumping, with no per-note gain table.  CC 1 (the mod wheel) raises the filter's quality (longer rings),
# and CC 71 (resonance) scales it.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# Examples:
#     $0                                    # live MIDI
#     $0 spec/test_data/c_major.mid ping.flac
#     $0 -M resonator spec/test_data/c_major.mid ping.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.synth_script(
  mode: [:lowpass, Symbol, '-M', 'lowpass (a resonant filter, the original) or resonator (GraphNode::Resonator)', [:lowpass, :resonator]],
) { |midi, p|
  synth = midi.synth(voices: 4) { |v|
    quality = v.quality(v.cc(1, range: 50..150, name: 'Ping quality'))

    if p.mode == :resonator
      # The resonator rings at the trigger's height (the velocity) for
      # every note, so it needs no per-note gain; a filter's Q falls 60 dB
      # in about Q × ln(1000) / (pi f) seconds
      decay = quality * (Math.log(1000) / Math::PI) / v.freq
      v.trigger.ping(v.freq, decay: decay) * 0.8
    else
      # Low notes ring louder for longer, so they get less gain: +48 dB at
      # note 0 down to -44 dB at note 127
      gain = 10 ** ((48 - v.number * (92 / 127.0)) / 20)

      # The voice has no envelope: the synth keeps its lane (and its
      # trigger, after a MIDI file ends) going until the ping has rung out
      ping = v.trigger * 25

      (ping.filter(:lowpass, cutoff: v.freq, quality: quality) * gain).softclip
    end
  }

  # The resonator doesn't alias, so it skips the oversampled clipper
  p.mode == :resonator ? synth.softclip(0.8, 0.95) : synth.softclip(0.8, 0.95).oversample(3)
}
