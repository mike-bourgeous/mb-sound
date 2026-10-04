#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# A standalone reverb effect: one reverb for every input channel.
#
# Input and output file can be specified using flags or positional arguments.
#
# Presets are a good way to get good sounds quickly.  You can override preset
# defaults by passing options like -w and --feedback-gain.
#
# Note: the --diffusion-time and --feedback-time options also accept ranges
# like "0.2..0.5".
#
# Usage: $0 [options] [input_file [output_file]]
#
# Examples:
#     $0 -p space sounds/piano0.flac
#     $0 --preset hall --repeat sounds/drums.flac              # loops until Ctrl-C
#     $0 --output-channels 5 sounds/piano0.flac surround.flac  # upmixes to 5 channels
#     $0 --preset hall spec/test_data/arp_a7.flac   # a 0.4 s Am7/Amaj7 arp, ~7 s of hall

require 'bundler/setup'
require 'mb-sound'

# Parses a number, or a range of numbers like "0.2..0.5".
float_or_range = ->(str) {
  if str.include?('..')
    range_start, _, range_end = str.partition('..')
    Float(range_start)..Float(range_end)
  else
    Float(str)
  end
}

MB::Sound.effect_script(
  input_channels: 2,
  preset: [nil, Symbol, '-p', 'A named preset to change default parameters (room, hall, stadium, space, or default)'],
  output_channels: [nil, Integer, 'The number of output channels (default: the number of input channels, at least 2)'],
  channels: [nil, Integer, 'The number of parallel diffusion and feedback channels (default 4; powers of two: 1, 2, 4, 8, ...)'],
  stages: [nil, Integer, '-s', 'The number of diffusion stages (default 4, range 1..N)'],
  diffusion_time: [nil, float_or_range, '-t', 'The maximum diffusion delay in seconds; controls smearing (default 0.01, range 0..)'],
  feedback_time: [nil, float_or_range, '-b', 'The maximum feedback delay in seconds; controls room size (default 0.1, range 0..)'],
  feedback_gain: [nil, Float, 'The feedback gain in decibels (default -6dB, range -120..0)'],
  disable_feedback: [false, '-x', 'Bypass the feedback stage of the reverb'],
  predelay: [nil, Float, 'Pre-delay for the reverb in seconds'],
  wet: [nil, Float, '-w', 'The wet gain in decibels (default 0dB, range -120..)'],
  dry: [nil, Float, '-d', 'The dry gain in decibels (default 0dB, range -120..)'],
  seed: [nil, Integer, 'Random seed for the reverb generator (default varies by preset, often 0)'],
  extra_time: [nil, Float, 'Seconds of silence to add after an input file'],
  show_internals: [false, 'Show the insides of the reverb object in --graphviz'],
) { |input, p|
  input.reverb(
    p.preset,
    output_channels: p.output_channels || MB::M.max(2, input.channel_count),
    channels: p.channels,
    stages: p.stages,
    diffusion_range: p.diffusion_time,
    feedback_range: p.feedback_time,
    feedback_gain: p.feedback_gain&.db,
    feedback_enabled: p.disable_feedback ? false : nil,
    predelay: p.predelay,
    wet: p.wet&.db,
    dry: p.dry&.db,
    seed: p.seed,
    extra_time: p.extra_time,
    show_internals: p.show_internals,
  )
}
