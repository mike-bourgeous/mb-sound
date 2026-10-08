#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A Juno-60-style stereo chorus (GraphNode#chorus): a mono delay line read
# at two taps swept by a triangle LFO, the right tap's sweep inverted.
# (C)2026 Mike Bourgeous
#
# Usage: $0 [--mode juno1|juno2|juno12] [options] [input_filename [output_filename]]
#
# Plays a sound file (or live input) through the chorus.  Like the Juno, the
# delay line takes the input's channels mixed to mono; the dry signal keeps
# its sides.  With live MIDI (-m), CC 1 (the mod wheel) widens the sweep.
# Run with --help for all options.
#
# Examples:
#     $0 spec/test_data/arp_a7.flac                    # chorus I (0.513 Hz, 1.66-5.35 ms)
#     $0 --mode juno2 spec/test_data/arp_a7.flac       # chorus II (0.863 Hz)
#     $0 --mode juno12 spec/test_data/arp_a7.flac      # I+II (9.75 Hz, 3.3-3.7 ms)
#     $0 --mode juno2 --bbd spec/test_data/arp_a7.flac # lowpassed wet plus hiss
#     $0 --rate 3 --depth 0.5 --dry 0 sounds/synth0.flac   # wet only: vibrato-ish
#
# Console equivalents (bin/sound.rb):
#     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno2)
#     bg :pad, 110.hz.ramp.at(-12.db).chorus(:juno12, bbd: true)

require 'bundler/setup'
require 'mb-sound'

MB::Sound.effect_script(
  mode: [:juno1, 'Chorus mode (Juno-60 buttons: I, II, I+II)', MB::Sound::GraphNode::Chorus::MODES.keys],
  rate: [nil, Float, "LFO rate in Hz (default: the mode's)"],
  depth: [1.0, "Sweep width as a fraction of the mode's"],
  dry: [1.0, 'Dry (input) level'],
  wet: [1.0, 'Wet (chorused) level'],
  bbd: [false, 'Add the bucket-brigade flavour (lowpassed wet, hiss)'],
  cutoff: [nil, Float, 'BBD lowpass cutoff in Hz (turns the filters on)'],
  hiss: [nil, Float, 'Hiss level in dBFS (turns hiss on)'],
) { |input, p|
  max_depth = p.mode == :juno12 ? 17.0 : 1.8
  depth = p.midi_cc(1, :depth, range: 0.0..[p.depth * 2, max_depth].min)

  input.chorus(
    p.mode,
    rate: p.rate,
    depth: depth,
    dry: p.dry,
    wet: p.wet,
    bbd: p.bbd,
    cutoff: p.cutoff,
    hiss: p.hiss
  ).softclip(0.9)
}
