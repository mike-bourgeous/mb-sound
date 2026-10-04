#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Adds reverb to an audio file or real-time input using diffusion stages
# and a feedback delay network (FDN).
# (C)2025 Mike Bourgeous
#
# Usage: $0 [options] [input_file [output_file]]
#
# Note: this reverb was an experiment; bin/effects/reverb.rb is usually a
# better choice (and lighter on the CPU).
#
# Examples:
#     # Real-time mic input (mono by default; -c 2 for stereo)
#     $0
#
#     # File input to speaker output
#     $0 sounds/piano0.flac
#
#     # File input to file output (preserves channel count)
#     $0 sounds/piano0.flac tmp/fdn_reverb_out.flac
#
#     # A 0.4 s Am7/Amaj7 arp (the specs' test sound); rings ~4.5 s
#     $0 spec/test_data/arp_a7.flac
#
#     # Large room with long decay
#     $0 --room-size 0.8 --decay 4.0 sounds/piano0.flac
#
#     # Force stereo output from mono input
#     $0 --output-channels 2 sounds/mono.flac tmp/stereo_fdn_reverb.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.effect_script(
  live_channels: 1,
  room_size: [0.5, 'Room size', 0.0..1.0],
  decay: [2.0, 'Decay time in seconds'],
  damping: [0.5, 'High frequency damping', 0.0..1.0],
  wet: [0.3, 'Wet signal gain'],
  dry: [0.7, 'Dry signal gain'],
  diffusion_steps: [4, 'Number of diffusion steps', 1..],
  channels: [8, 'Parallel delay channels (a power of 2)'],
  output_channels: [nil, Integer, 'Number of output channels (default: match input)'],
  seed: [0, 'Random seed for delay times'],
) { |input, p|
  reverb = input.fdn_reverb(
    room_size: p.room_size,
    decay: p.decay,
    damping: p.damping,
    diffusion_steps: p.diffusion_steps,
    channels: p.channels,
    output_channels: p.output_channels || input.channel_count,
    wet: p.wet,
    dry: p.dry,
    seed: p.seed,
    tail: false # the script runner lets the effect ring out
  )

  reverb.outputs.map { |out|
    out.softclip(0.85, 0.95).named('reverb output').with_buffer(800)
  }.channels
}
