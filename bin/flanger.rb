#!/usr/bin/env ruby
# A simple flanger effect, to demonstrate using a signal node as a delay time.
# (C)2022 Mike Bourgeous
#
# Usage: $0 [delay_s [feedback [hz [depth0..1]]]] [filename]
#    Or: $0 [filename]
#
# Environment variables:
#    WAVE_TYPE - oscillator waveform name (e.g. sine, ramp, triangle, square)
#    SMOOTHING - max delay change rate in seconds per second
#    DRY - dry output level (default 1)
#    WET - wet output level (default 1)
#    SPREAD - LFO phase spread across channels (default 180)
#
# Cool effects (omit filename for realtime processing from Jack):
#    Arpeggio: SMOOTHING=0.5 $0 sounds/transient_synth.flac 0.035 0 3 2
#    Slow arp: SMOOTHING=1.5 $0 sounds/transient_synth.flac 0.15 0 3 2
#    Metal drums: SMOOTHING=12.1 WET=1 DRY=0 $0 sounds/drums.flac 0.02 -0.3 343 -6
#    Water drums: SMOOTHING=4 WET=1 DRY=0 $0 sounds/drums.flac 0.02 -0.3 46 6
#    Space warp: SMOOTHING=10 WET=1 DRY=0 $0 sounds/drums.flac 0.2 -0.8 15 6
#    Time warp: WET=1 DRY=0 $0 sounds/drums.flac 0.2 -0.8 0.3 6

require 'bundler/setup'

require 'mb/sound'

if ARGV.include?('--help')
  puts MB::U.read_header_comment.join.gsub('$0', "\e[1m#{$0}\e[0m")
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

filename = others[0]

if filename && File.readable?(filename)
  inputs = MB::Sound.file_input(filename).split.map { |d| d.and_then(0.hz.at(0).for(delay * 4)) }
else
  inputs = MB::Sound.input(channels: ENV['CHANNELS']&.to_i || 2).split
end

output = MB::Sound.output(channels: inputs.length)

if defined?(MB::Sound::JackFFI) && output.is_a?(MB::Sound::JackFFI::Output)
  # MIDI control is possible since Jack is running
  puts "\e[1mMIDI control enabled (jackd detected)\e[0m"
  manager = MB::Sound::MIDI::Manager.new(jack: output.jack_ffi)
else
  puts "\e[38;5;243mMIDI disabled (jackd not detected)\e[0m"
end

bufsize = output.buffer_size
internal_bufsize = 48
internal_bufsize -= 1 until bufsize % internal_bufsize == 0

delay_samples = delay * output.rate
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

puts MB::U.highlight(
  wave_type: wave_type,
  delay: delay,
  feedback: feedback,
  lfo_hz: hz,
  depth: depth,
  inputs: inputs.map(&:graph_node_name),
  rate: output.rate,
  buffer: bufsize,
  internal_buffer: internal_bufsize,
)

# TODO: Maybe want a graph-wide spy function that either prints stats, draws
# meters, or plots graphs of multiple nodes by name or reference

begin
  # FIXME: feedback delay includes buffer size
  # TODO: Abstract construction of a filter graph per channel
  paths = inputs.map.with_index { |inp, idx|
    inp = inp.with_buffer(bufsize)

    # Feedback buffers, overwritten by later calls to #spy
    a = Numo::SFloat.zeros(internal_bufsize)

    lfo_freq = hz.constant.named('LFO Hz')

    lfo = lfo_freq.tone.with_phase(idx * phase_spread * Math::PI / (180.0 * (inputs.length - 1))).send(wave_type).forever.at(0..1)

    # Set up LFO depth control
    depthconst = depth.constant.named('Depth')
    delayconst = delay.constant.named('Delay')
    # Need to tee samp (delay in samples) so it doesn't skip when changing the delay via MIDI
    samp1, samp2 = (delayconst * output.rate).clip(0, nil).named('Delay in samples').tee
    samp1.named('Delay in samples (branch 1)')
    samp2.named('Delay in samples (branch 2)')

    lfo_scale1, lfo_scale2 = (depthconst * samp1).tee
    lfo_base = samp2 - lfo_scale1 * 0.5
    lfo_mod = (lfo * lfo_scale2 + lfo_base).clip(0, nil)

    # Split delay LFO for first-tap and feedback
    d1, d2 = lfo_mod.tee

    # Split input into original and first delay
    s1, s2 = inp.tee(2)
    s1.named('s1')
    s2.named('s2')
    s2 = s2.delay(samples: d1, smoothing: delay_smoothing)

    # Feedback injector and feedback delay (compensating for buffer size)
    d_fb = (d2 - internal_bufsize).clip(0, nil)
    b = 0.hz.forever.proc { a }.delay(samples: d_fb, smoothing: delay_smoothing2)

    # Effected output, with a spy to save feedback buffer
    wet = (feedback * b - s2).softclip(0.85, 0.95).spy { |z| a[] = z if z }

    dryconst = dry_level.constant.named('Dry level')
    wetconst = wet_level.constant.named('Wet level')
    final = (s1 * dryconst + wet * wetconst).softclip(0.85, 0.95).with_buffer(internal_bufsize).named('final_buf')

    # GraphVoice provides on_cc to generate a cc map for the MIDI manager
    # (TODO: probably a better way to do this, also need on_bend, on_pitch, etc)
    MB::Sound::MIDI::GraphVoice.new(final)
      .on_cc(1, 'LFO Hz', range: 0.0..6.0)
      .on_cc(1, 'Depth', range: 0.0..2.0)
      .on_cc(1, 'Dry level', range: 1.0..0.0)
      #.on_cc(1, 'Delay', range: 0.1..4.0)
      #.on_cc(1, 'Wet level', range: 0.0..1.0, relative: false)
  }

  if manager
    manager.on_cc_map(paths.map(&:cc_map))
    puts MB::U.syntax(manager.to_acid_xml, :xml)
  end

  loop do
    manager&.update
    data = paths.map { |p| p.sample(output.buffer_size) }
    break if data.any?(&:nil?)
    output.write(data)
  end

rescue => e
  puts MB::U.highlight(e)
  exit 1
end
