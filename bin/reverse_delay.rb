#!/usr/bin/env ruby
# A reverse delay effect.  This works by playing a delay buffer in reverse.
# (C)2022 Mike Bourgeous

require 'bundler/setup'

require 'mb/sound'

if ARGV.include?('--help')
  puts "Usage: \e[1m#{$0}\e[0m [delay_s [feedback]] [filename]"
  exit 1
end

# TODO: Abstract filename and numeric parameter handling and .flac vs. JACK switching?

numerics, others = ARGV.partition { |arg| arg.strip =~ /\A[+-]?[0-9]+(\.[0-9]+)?\z/ }

delay, feedback = numerics.map(&:to_f)
delay ||= 0.6
feedback ||= -0.25

dry_level = ENV['DRY']&.to_f || 0.25
wet_level = ENV['WET']&.to_f || 0.75

filename = others[0]
if filename && File.readable?(filename)
  inputs = MB::Sound.file_input(filename).split.map { |d| d.and_then(0.hz.at(0).for(delay * 4)) }
else
  inputs = MB::Sound.input(channels: ENV['CHANNELS']&.to_i || 2).split
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

bufsize = output.buffer_size
buftime = bufsize.to_f / output.rate

puts MB::U.highlight(
  delay: delay,
  bufsize: bufsize,
  buftime: buftime,
)

begin
  # TODO: Abstract construction of a filter graph per channel
  paths = inputs.map.with_index { |inp, idx|
    # Feedback buffers, overwritten by later calls to #spy
    a = Numo::SFloat.zeros(bufsize)

    # TODO: Allow base delay and loop length? or mindelay and maxdelay?
    # TODO: Smooth delay over longer than one frame
    delayconst = (delay.constant.named('Delay')).clip(buftime, nil)
    lfo_period, delay_delay = delayconst.tee
    lfo_period.named('LFO period')
    delay_delay.named('Delay time')
    
    lfo_freq = 1.0 / lfo_period
    freq_amp, freq_del = lfo_freq.tee
    freq_amp.named('Amp LFO Frequency')
    freq_del.named('Delay LFO Frequency')

    # The amplitude LFO mutes the sound while the delay buffer jumps back to the present
    amp_lfo = freq_amp.tone.sine.at(0..1000).with_phase((idx + 0.5) * 2.0 * Math::PI / inputs.length).clip(0, 1).named('Amp LFO')

    # The delay LFO controls the position in the delay buffer
    delay_lfo = freq_del.tone.ramp.at(0..2).with_phase(idx * 2.0 * Math::PI / inputs.length).named('Delay LFO') * delay_delay

    final = inp.delay(seconds: delay_lfo, smoothing: false) * amp_lfo

    # TODO: dry signal and feedback
#    # Split delay LFO for first-tap and feedback
#    d1, d2 = delay_lfo.tee
#
#    # Split input into original and first delay
#    s1, s2 = inp.tee(2)
#    s1.named('s1')
#    s2.named('s2')
#    s2 = s2.delay(samples: d1, smoothing: false)
#
#    # Feedback injector and feedback delay (compensating for buffer size)
#    d_fb = (d2 - bufsize).clip(0, nil)
#    b = 0.hz.forever.proc { a }.delay(samples: d_fb, smoothing: false)
#
#    # Effected output, with a spy to save feedback buffer
#    wet = (feedback * b - s2).softclip(0.85, 0.95).spy { |z| a[] = z if z }
#
#    dryconst = dry_level.constant.named('Dry level')
#    wetconst = wet_level.constant.named('Wet level')
#    final = (s1 * dryconst + wet * wetconst).softclip(0.85, 0.95)
#
    # GraphVoice provides on_cc to generate a cc map for the MIDI manager
    # (TODO: probably a better way to do this, also need on_bend, on_pitch, etc)
    MB::Sound::MIDI::GraphVoice.new(final)
      .on_cc(1, 'Delay', range: 0.0..2.0)
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

