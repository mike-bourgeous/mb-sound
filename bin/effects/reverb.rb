#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A standalone reverb effect: one reverb for every input channel.
#
# Input and output file can be specified using flags or positional arguments.
#
# Presets are a good way to get good sounds quickly.  You can override preset
# defaults by passing options like -w and --feedback-gain.  Without a preset,
# --room-size, --decay, and --damping build a reverb from a room-size layout
# (the friendly form of GraphNode#reverb).
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
#     $0 --room-size 0.8 --decay 4 --damping 0.6 sounds/piano0.flac
#     $0 -p hall --mod lush --shimmer 0.5 sounds/piano0.flac    # shimmering hall
#     $0 --decay 6 --drive 4 --drive-mode fold sounds/drums.flac  # gritty decay
#     $0 -p plate sounds/drums.flac

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

# A modulation preset name, or a depth in milliseconds.
modulation = ->(str) {
  str.match?(/\A[a-z_]+\z/) ? str.to_sym : Float(str).ms
}

MB::Sound.effect_script(
  input_channels: 2,
  preset: [nil, Symbol, '-p', "A named preset (#{MB::Sound::GraphNode::Reverb::PRESETS.keys.join(', ')})"],
  room_size: [nil, Float, 'Room size for the friendly form (0..1; default 0.5 when --decay or --damping is given)'],
  decay: [nil, Float, 'Reverb time (RT60) in seconds, instead of --feedback-gain'],
  damping: [nil, Float, 'How much faster high frequencies decay (0..1)'],
  output_channels: [nil, Integer, 'The number of output channels (default: the number of input channels, at least 2)'],
  channels: [nil, Integer, 'The number of parallel diffusion and feedback channels (powers of two: 1, 2, 4, 8, ...)'],
  stages: [nil, Integer, '-s', 'The number of diffusion stages (default 4, range 1..N)'],
  diffusion_time: [nil, float_or_range, '-t', 'The maximum diffusion delay in seconds; controls smearing (default 0.01, range 0..)'],
  feedback_time: [nil, float_or_range, '-b', 'The maximum feedback delay in seconds; controls room size (default 0.1, range 0..)'],
  feedback_gain: [nil, Float, 'The feedback gain in decibels (default -6dB, range -120..0)'],
  disable_feedback: [false, '-x', 'Bypass the feedback stage of the reverb'],
  predelay: [nil, Float, 'Pre-delay for the reverb in seconds'],
  wet: [nil, Float, '-w', 'The wet gain in decibels (default 0dB, range -120..)'],
  dry: [nil, Float, '-d', 'The dry gain in decibels (default 0dB, range -120..)'],
  mix: [nil, Float, 'Dry/wet mix (0 dry .. 1 wet), instead of --wet/--dry'],
  mod: [nil, modulation, 'Feedback line modulation: subtle, lush, chorus, seasick, off, or a depth in ms'],
  mod_rate: [nil, Float, 'Feedback line modulation rate in Hz'],
  diffusion_mod: [nil, modulation, 'Diffusion modulation: subtle, lush, chorus, seasick, off, or a depth in ms'],
  lowpass: [nil, Float, 'A lowpass cutoff in the feedback loop (Hz)'],
  highpass: [nil, Float, 'A highpass cutoff in the feedback loop (Hz)'],
  drive: [nil, Float, 'Saturation inside the feedback loop (level; 0 off)'],
  drive_mode: [nil, Symbol, 'Saturation shape: soft, hard, or fold'],
  crush: [nil, Float, 'Bit depth inside the feedback loop (0 off)'],
  shimmer: [nil, Float, 'Shimmer amount (0..1): pitch-shifted feedback'],
  shimmer_pitch: [nil, Float, 'Shimmer pitch shift in semitones (default 12)'],
  seed: [nil, Integer, 'Random seed for the reverb generator (default varies by preset, often 0)'],
  extra_time: [nil, Float, 'Seconds of silence to add after an input file'],
  show_internals: [false, 'Show the insides of the reverb object in --graphviz'],
) { |input, p|
  mod = p.mod == :off ? false : p.mod
  mod = { preset: mod.is_a?(Symbol) ? mod : :subtle, **(mod.is_a?(Symbol) ? {} : { depth: mod }), rate: p.mod_rate } if p.mod_rate && mod
  diffusion_mod = p.diffusion_mod == :off ? false : p.diffusion_mod

  input.reverb(
    p.preset,
    output_channels: p.output_channels || MB::M.max(2, input.channel_count),
    room_size: p.room_size,
    decay: p.decay,
    damping: p.damping,
    channels: p.channels,
    stages: p.stages,
    diffusion_range: p.diffusion_time,
    feedback_range: p.feedback_time,
    feedback_gain: p.feedback_gain&.db,
    feedback_enabled: p.disable_feedback ? false : nil,
    predelay: p.predelay,
    wet: p.wet&.db,
    dry: p.dry&.db,
    mix: p.mix,
    modulation: mod,
    diffusion_modulation: diffusion_mod,
    lowpass: p.lowpass,
    highpass: p.highpass,
    drive: p.drive,
    drive_mode: p.drive_mode,
    crush: p.crush,
    shimmer: p.shimmer,
    shimmer_pitch: p.shimmer_pitch,
    seed: p.seed,
    extra_time: p.extra_time,
    show_internals: p.show_internals,
  )
}
