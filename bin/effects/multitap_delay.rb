#!/usr/bin/env ruby
# A filtered multi-tap delay effect.
# (C)2022 Mike Bourgeous
#
# This is inspired by a module I saw on Andrew Huang's YouTube channel.
#
# Usage: $0 [options] [input_filename [output_filename]]
#
# Plays a sound file (or live input, stereo unless -c says otherwise) through
# the delay, letting it ring out after the file ends.  With live MIDI (JACK),
# CC 1 (the mod wheel) scales the delay, tap offset, and filter frequency
# together (0 to 2 times).  Run with --help for all options.
#
# Examples:
#     # Resonant widener
#     $0 --delay 0.001 sounds/transient_synth.flac
#     # Pinged filter drums
#     $0 --delay 0.2 sounds/drums.flac
#     # Filter pinging
#     $0 --delay 0.5 --cutoff 150 --quality 30 --reverse-odd-taps sounds/drums.flac

require 'bundler/setup'
require 'mb-sound'

NUM_TAPS = 6

MB::Sound.effect_script(
  delay: [0.1, 'Base delay and tap spacing in seconds'],
  cutoff: [250.0, 'Base filter frequency in Hz (tap N gets N times this)'],
  quality: [3.0, 'Filter quality (resonance)'],
  reverse_odd_taps: [false, 'Reverse the tap order on odd channels'],
  oversample: [2.0, 'Oversampling factor'],
) { |input, p|
  processing_sample_rate = 48000.0 * p.oversample

  internal_buffer = 128
  buftime = internal_buffer.to_f / processing_sample_rate

  # CC 1 scales the delay, tap offset, and filter frequency together
  delay = p.midi_cc(1, :delay, range: 0.0..2.0)
  filter_freq = p.midi_cc(1, :cutoff, range: 0.0..2.0)

  # TODO: Add a speed option for playing input files faster or slower (some
  # files sound cool at 0.5x)
  input.outputs.map.with_index { |inp, idx|
    inp = inp.with_buffer(800).resample(mode: :libsamplerate_fastest)

    base = (delay - buftime).clip_rate(2, sample_rate: processing_sample_rate)
    offset = delay.clip_rate(2, sample_rate: processing_sample_rate)

    delays = Array.new(NUM_TAPS) { |i|
      base + offset * (i + (idx.odd? ? 0.5 : 0))
    }

    taps = inp.multitap(*delays).to_a.shuffle
    taps = taps.reverse if idx.odd? && p.reverse_odd_taps

    filtered_taps = taps.map.with_index { |t, i|
      freq = (i + 1 + (idx.odd? ? 0.5 : 0)) * filter_freq
      t.filter(:peak, cutoff: freq, quality: p.quality, gain: 40.db) * -40.db
    }

    MB::Sound::GraphNode::Mixer.new(filtered_taps)
      .with_buffer(internal_buffer)
      .oversample(p.oversample, mode: :libsamplerate_fastest)
  }.channels
}
