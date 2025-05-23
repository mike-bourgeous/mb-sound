#!/usr/bin/env ruby
# A filtered multi-tap delay effect.
# (C)2022 Mike Bourgeous
#
# This is inspired by a module I saw on Andrew Huang's YouTube channel.
#
# Usage: $0 [base_delay_seconds] [filename]
#
# Examples:
#     Resonant widener: $0 0.001 sounds/transient_synth.flac
#     Pinged filter drums: $0 0.2 sounds/drums.flac

require 'bundler/setup'

require 'mb/sound'

if ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

# TODO: Abstract filename and numeric parameter handling and .flac vs. JACK switching?

numerics, others = ARGV.partition { |arg| arg.strip =~ /\A[+-]?[0-9]+(\.[0-9]+)?\z/ }

base_delay_s, _ = numerics.map(&:to_f)
base_delay_s ||= 0.1

filename = others[0]
if filename && File.readable?(filename)
  input = MB::Sound.file_input(filename)
  inputs = input.split.map { |d| d.and_then(0.constant.for(base_delay_s * 4)) }
else
  MB::Sound.input(channels: ENV['CHANNELS']&.to_i || 2)
  inputs = input.split
end

output = MB::Sound.output(channels: inputs.length)

# TODO: dedupe some kind of init code or shell or wrapper for effect processing with flanger.rb
if defined?(MB::Sound::JackFFI) && output.is_a?(MB::Sound::JackFFI::Output)
  # MIDI control is possible since Jack is running
  puts "\e[1mMIDI control enabled (jackd detected)\e[0m"
  manager = MB::Sound::MIDI::Manager.new(jack: output.jack_ffi)
else
  puts "\e[38;5;243mMIDI disabled (jackd not detected)\e[0m"
end

oversample = ENV['OVERSAMPLE']&.to_f || 2
processing_sample_rate = output.sample_rate.to_f * oversample

internal_buffer = 128
buftime = internal_buffer.to_f / processing_sample_rate

puts MB::U.highlight({
  delay: base_delay_s,
  internal_buffer: internal_buffer,
  buftime: buftime,
  processing_rate: processing_sample_rate,
})

NUM_TAPS = 6

begin
  # TODO: Abstract construction of a filter graph per channel
  # TODO: Add a speed option for playing input files faster or slower (some
  # files sound cool at 0.5x)
  paths = inputs.map.with_index { |inp, idx|
    inp = inp.with_buffer(input.buffer_size).resample(mode: :libsamplerate_fastest)

    base = (base_delay_s.constant.named('Delay') - buftime).clip_rate(2, sample_rate: processing_sample_rate)
    offset = base_delay_s.constant.named('Tap Offset').clip_rate(2, sample_rate: processing_sample_rate)

    offsets = offset.tee(NUM_TAPS)
    delays = base.tee(NUM_TAPS).map.with_index { |d, i|
      d + offsets[i] * (i + (idx.odd? ? 0.5 : 0))
    }

    taps = inp.multitap(*delays).shuffle
    # XXX taps = taps.reverse if idx.odd?

    filter_freqs = 250.constant.named('Filter Frequency').tee(NUM_TAPS)
    filtered_taps = taps.map.with_index { |t, i|
      freq = (i + 1 + (idx.odd? ? 0.5 : 0)) * filter_freqs[i]
      t.filter(:peak, cutoff: freq, quality: 3, gain: 40.db) * -40.db
    }

    mix = MB::Sound::GraphNode::Mixer.new(filtered_taps)

    final = mix.with_buffer(internal_buffer).oversample(oversample, mode: :libsamplerate_fastest)

    # GraphVoice provides on_cc to generate a cc map for the MIDI manager
    # (TODO: probably a better way to do this, also need on_bend, on_pitch, etc)
    MB::Sound::MIDI::GraphVoice.new(final)
      .on_cc(1, ['Delay', 'Tap Offset', 'Filter Frequency'], range: 0.0..2.0)
      #.on_cc(1, 'Delay', range: 0.1..4.0)
      #.on_cc(1, 'Wet level', range: 0.0..1.0, relative: false)
  }

  if manager
    manager.on_cc_map(paths.map(&:cc_map))
    puts MB::U.syntax(manager.to_acid_xml, :xml)
  end

  loop do
    manager&.update
    data = paths.map { |p|
      d = p.sample(output.buffer_size)
      d && MB::M.zpad(d, output.buffer_size)
    }
    break if data.any?(&:nil?)
    output.write(data)
  end

rescue => e
  puts MB::U.highlight(e)
  exit 1
end

