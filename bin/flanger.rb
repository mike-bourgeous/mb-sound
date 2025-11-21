#!/usr/bin/env ruby
# A simple flanger effect, to demonstrate using a signal node as a delay time.
# (C)2022 Mike Bourgeous
#
# Usage: $0 [delay_s [feedback [hz [depth0..1]]]] [filename [output_filename]] [--silent]
#    Or: $0 [filename [output_filename]] [--silent]
#
# Environment variables:
#    WAVE_TYPE - oscillator waveform name (e.g. sine, ramp, triangle, square)
#    SMOOTHING - max delay change rate in seconds per second
#    DRY - dry output level (default 1)
#    WET - wet output level (default 1)
#    SPREAD - LFO phase spread across channels (default 180)
#
# Examples:
#    DRY=0.5 $0 sounds/drums.flac 0.002 0.85 0.2 0.5
#
# Cool effects (omit filename for realtime processing from Jack):
#    Arpeggio: SMOOTHING=0.5 $0 sounds/transient_synth.flac 0.035 0 3 2
#    Slow arp: SMOOTHING=1.5 $0 sounds/transient_synth.flac 0.15 0 3 2
#    Metal drums: SMOOTHING=12.1 WET=1 DRY=0 $0 sounds/drums.flac 0.02 -0.3 343 -6
#    Water drums: SMOOTHING=4 WET=1 DRY=0 $0 sounds/drums.flac 0.02 -0.3 46 6
#    Space warp: SMOOTHING=10 WET=1 DRY=0 $0 sounds/drums.flac 0.2 -0.8 15 6
#    Time warp: WET=1 DRY=0 $0 sounds/drums.flac 0.2 -0.8 0.3 6
#    Bass comb: SMOOTHING=0.7 DRY=0 $0 sounds/drums.flac 0.04 0.95 150 1
#    Bass beat: SPREAD=10 $0 sounds/drums.flac 0.006 -0.98 0.4 2
#    Gritty overtone: DRY=0.5 $0 sounds/synth0.flac 0.0029 0.85 60 0.1
#    Decimation: DRY=0 $0 sounds/synth0.flac 0.0058 -0.85 3300 0.2

require 'bundler/setup'

require 'mb/sound'

MB::U.sigquit_backtrace

if ARGV.include?('--help')
  MB::U.print_header_help
  exit 1
end

numerics, others = ARGV.partition { |arg| arg.strip =~ /\A[+-]?[0-9]+(\.[0-9]+)?\z/ }

delay, feedback, hz, depth = numerics.map(&:to_f)
delay ||= 0.02193
feedback ||= -0.3
hz ||= -0.7
depth ||= 0.35

wave_type = ENV['WAVE_TYPE']&.to_sym || :sine
raise 'Invalid wave type' unless MB::Sound::Oscillator::WAVE_TYPES.include?(wave_type)

# Optionally read from a file
filename = others[0]
if filename && File.readable?(filename)
  input = MB::Sound.file_input(filename)

  # Can't use 0.hz.for(...) because GraphVoice changes all Tones to play forever.  FIXME: make GraphVoice smarter?
  # Feedback will decay by N dB after |log_[|feedback|](-N dB)| max delay periods
  # Always extend by at least one delay period, or at least one second
  # TODO: detect actual decay by monitoring audio level; that might be a useful graph node to add
  max_delay = delay.abs * (1 + depth.abs)
  decay_periods = 1 + Math.log(-36.dB, MB::M.clamp(feedback.abs, 0.1, 0.99))
  delay_time = MB::M.max(max_delay * decay_periods, 1)
  final_tone = 0.constant.for(max_delay * decay_periods)
  inputs = input.split.map { |d| d.and_then(final_tone) }
else
  input = MB::Sound.input(channels: ENV['CHANNELS']&.to_i || 2)
  inputs = input.split
end

if others.delete('--silent')
  puts "\e[1;34mNot playing realtime output\e[0m"
else
  output = MB::Sound.output(channels: inputs.length)
end

# Optionally write to a file
output_filename = others[1]
if output_filename && !output_filename.start_with?('-') && !MB::U.prevent_overwrite(output_filename, prompt: true)
  puts "\e[33mWriting to \e[1m#{output_filename}\e[0m"
  output = MB::Sound::MultiWriter.new([
    output,
    MB::Sound.file_output(
      output_filename,
      channels: inputs.count,
      buffer_size: output&.buffer_size || input.buffer_size,
      overwrite: true
    )
  ].compact)
end

if defined?(MB::Sound::JackFFI) && output.is_a?(MB::Sound::JackFFI::Output)
  # MIDI control is possible since Jack is running
  puts "\e[1mMIDI control enabled (jackd detected)\e[0m"
  manager = MB::Sound::MIDI::Manager.new(jack: output.jack_ffi)
else
  puts "\e[38;5;243mMIDI disabled (jackd not detected)\e[0m"
end

oversample = ENV['OVERSAMPLE']&.to_f || 2

bufsize = output.buffer_size
internal_bufsize = (24 * oversample).ceil

delay_samples = delay * output.sample_rate * oversample
delay_samples = 0 if delay_samples < 0
range = depth * delay_samples
min_delay = delay_samples - range * 0.5
max_delay = delay_samples + range * 0.5

# FIXME: This doesn't work with a filter like 1000.hz.lowpass1p; maybe there's overshoot or something?
delay_smoothing = ENV['SMOOTHING']&.to_f
delay_smoothing2 = delay_smoothing

dry_level = ENV['DRY']&.to_f || 1
wet_level = ENV['WET']&.to_f || 1

phase_spread = ENV['SPREAD']&.to_f || 180.0

puts MB::U.highlight({
  args: ARGV,
  other_args: others,
  wave_type: wave_type,
  delay: delay,
  feedback: feedback,
  lfo_hz: hz,
  depth: depth,
  inputs: inputs.map(&:graph_node_name),
  sample_rate: output.sample_rate,
  oversample: oversample,
  buffer: bufsize,
  internal_buffer: internal_bufsize,
})

# TODO: Maybe want a graph-wide spy function that either prints stats, draws
# meters, or plots graphs of multiple nodes by name or reference

begin
  # FIXME: feedback delay includes buffer size
  # TODO: Abstract construction of a filter graph per channel
  paths = inputs.map.with_index { |inp, idx|
    inp = inp.with_buffer(bufsize).resample(mode: :libsamplerate_fastest)

    # Feedback buffers, overwritten by later calls to #spy
    a = Numo::SFloat.zeros(internal_bufsize)

    lfo_freq = hz.constant.named('LFO Hz')

    lfo = lfo_freq.tone.with_phase(idx * phase_spread * Math::PI / (180.0 * (inputs.length - 1))).send(wave_type).forever.at(0..1)

    # Set up LFO depth control
    depthconst = depth.constant.named('Depth')
    delayconst = delay.constant.named('Delay')

    # Delay in samples
    samples = (delayconst * (output.sample_rate * oversample)).clip(0, nil).named('Delay in samples')

    # Delay LFO
    lfo_scale = depthconst * samples
    lfo_base = samples - lfo_scale * 0.5
    lfo_mod = (lfo * lfo_scale + lfo_base).clip(0, nil)

    # Split input into original and first delay
    inp_delayed = inp.delay(samples: lfo_mod, smoothing: delay_smoothing, sample_rate: input.sample_rate * oversample)

    # Feedback injector and feedback delay (compensating for buffer size)
    # TODO: better way of injecting an NArray into a node chain than
    # constant.proc; e.g. maybe a node that takes a pointer to a buffer and
    # always returns the buffer; or better way of just doing feedback
    d_fb = (lfo_mod - internal_bufsize).clip(0, nil)
    b = 0.constant.proc { a }.delay(samples: d_fb, smoothing: delay_smoothing2, sample_rate: input.sample_rate * oversample)

    # Effected output, with a spy to save feedback buffer
    wet = (feedback * b - inp_delayed).softclip(0.85, 0.95).spy { |z| a[] = z if z }

    dryconst = dry_level.constant.named('Dry level')
    wetconst = wet_level.constant.named('Wet level')
    final = (inp * dryconst + wet * wetconst)
      .softclip(0.85, 0.95).named('final_softclip')
      .with_buffer(internal_bufsize).named('final_bufsize')
      .filter(15000.hz.lowpass)
      .oversample(oversample, mode: :libsamplerate_fastest).named('final_oversample')

    # GraphVoice provides on_cc to generate a cc map for the MIDI manager
    # (TODO: probably a better way to do this, also need on_bend, on_pitch, etc)
    MB::Sound::MIDI::GraphVoice.new(final)
      .on_cc(1, 'LFO Hz', range: 0.0..6.0)
      .on_cc(1, 'Depth', range: 0.0..2.0)
      .on_cc(1, 'Dry level', range: 1.0..0.0)
      #.on_cc(1, 'Delay', range: 0.1..4.0)
      #.on_cc(1, 'Wet level', range: 0.0..1.0, relative: false)
  }

  paths[0].open_graphviz

  if manager
    manager.on_cc_map(paths.map(&:cc_map))
    puts MB::U.syntax(manager.to_acid_xml, :xml)
  end

  loop do
    manager&.update
    data = paths.map { |p| p.sample(output.buffer_size) }
    break if data.any?(&:nil?) || data.any?(&:empty?) || input.closed?

    output.write(data.map { |c| MB::M.zpad(c, output.buffer_size) })
  end

rescue => e
  puts MB::U.highlight(e)
  exit 1
end
