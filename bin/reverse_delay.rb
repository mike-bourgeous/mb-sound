#!/usr/bin/env ruby
# A reverse delay effect.  This works by playing a delay buffer in reverse.
# (C)2022 Mike Bourgeous
#
# Usage: $0 [delay_s [feedback]] [filename]
#
# Examples:
#     DRY=0 $0 0.2 0 sounds/drums.flac

require 'bundler/setup'

require 'mb/sound'

if ARGV.include?('--help')
  MB::U.print_header_help
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
buftime = bufsize.to_f / output.sample_rate

puts MB::U.highlight({
  delay: delay,
  bufsize: bufsize,
  buftime: buftime,
})

begin
  # TODO: Abstract construction of a filter graph per channel
  paths = inputs.map.with_index { |inp, idx|
    # Feedback buffers, overwritten by later calls to #spy
    a = Numo::SFloat.zeros(bufsize)

    # TODO: Allow base delay and loop length? or mindelay and maxdelay?
    # TODO: Smooth delay over longer than one frame
    # TODO: It would be cool to be able to crossfade the delay time jump; this
    # could be possible with a multi-tap delay
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
    amp1, amp2 = amp_lfo.tee
    amp1.named('amp1')
    amp2.named('amp2')

    # The delay LFO controls the position in the delay buffer
    delay_lfo = freq_del.tone.ramp.at(0..2).with_phase(idx * 2.0 * Math::PI / inputs.length).named('Delay LFO') * delay_delay
    d1, d2 = delay_lfo.tee(2)
    d1.named('d1')
    d2.named('d2')

    s1, s2 = inp.tee(2)
    s1.named('s1')
    s2.named('s2')

    delayed = s1.multitap(d1)[0] * amp1

    # TODO: create a better way to do feedback in node graphs, ideally while
    # automatically compensating for buffer size
    # TODO: implement cross-channel feedback
    d_fb1, d_fb2 = (d2 - bufsize.to_f / output.sample_rate).clip(0, nil).named('d_fb').tee
    d_fb_amp = amp2.multitap(d_fb1)[0] # delay the amp lfo to match the feedback delay (FIXME: this seems to be off; it lets through some aliasing noise on each cycle; or maybe it's in both LFOs)
    fb_return = 0.constant.proc { a }.multitap(d_fb2)[0] * d_fb_amp
    wet = (feedback * fb_return + delayed).softclip(0.85, 0.95).spy { |z| a[] = z if z }

    dryconst = dry_level.constant.named('Dry level')
    wetconst = wet_level.constant.named('Wet level')
    final = (s2 * dryconst + wet * wetconst).softclip(0.85, 0.95)

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

