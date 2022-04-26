#!/usr/bin/env ruby
# A metallic bell pad sound.

require 'bundler/setup'
require 'mb-sound'

repeat = !!ARGV.delete('--loop')

# TODO: Build an abstraction around switching between Jack and MIDI files for
# input, and FLAC files for output, for use by all synthesizers
jack = MB::Sound::JackFFI[]
output = jack.output(channels: 1, connect: [['system:playback_1', 'system:playback_2']])
midi = MB::Sound::MIDI::MIDIFile.new(ARGV[0]) if ARGV[0]&.end_with?('.mid') # TODO: Add a clock source based on jackd frames
manager = MB::Sound::MIDI::Manager.new(jack: jack, input: midi, connect: ARGV[0])

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 9
voices = OSC_COUNT.times.map { |i|
  freq_constants = []

  # TODO: Use Tee instead of .dup for base frequencies in synths?
  base = 440.constant(smoothing: false)
  bfreq = -> { 2 ** base.dup.tap { |z| freq_constants << z }.log2 } # smooth after log2 for portamento

  noise_lfo = -> { 1.hz.ramp.noise.at(48.db).filter(0.05.hz.highpass).filter(0.15.hz.lowpass(quality: 0.4)).softclip(0.1, 1) }

  b_ratio = 3.5.constant.named('B Ratio')
  b_osc = (bfreq.call * b_ratio * (2 ** (7.0 / 1000.0))).tone.noise(0.000007).at(1).named('B')
  b_env = MB::Sound.adsr(0.4, 3.1, 0.8, 6).named('B Envelope').db(20)
  b_out = (b_osc * b_env).named('B Out')

  # 7 mils up
  ba_const = 1.3.constant.named('B into A')
  ba_lfo = noise_lfo.call * -30.dB + 1
  a_osc = (bfreq.call * (2 ** (7.0 / 1000.0))).tone.at(1).pm(b_out * ba_const * ba_lfo).named('A')
  a_env = MB::Sound.adsr(0.9, 3.2, 0.9, 6.1).named('A Envelope').db(30)
  a_out = (a_osc * a_env).named('A Out')

  d_ratio = 6.constant.named('D Ratio')
  d_osc = (bfreq.call * d_ratio * (2 ** (5.0 / 1000.0))).tone.noise(0.000005).at(1).named('D')
  d_env = MB::Sound.adsr(0.6, 3.2, 0.83, 6.4).named('D Envelope').db(20)
  d_out = (d_osc * d_env).named('D Out')

  # 2 mils up
  dc_const = 1.25.constant.named('D into C')
  dc_lfo = noise_lfo.call * -30.dB + 1
  c_osc = (bfreq.call * (2 ** (2.0 / 1000.0))).tone.at(1).pm(d_out * dc_const * dc_lfo).named('C')
  c_env = MB::Sound.adsr(1.1, 3.1, 0.85, 6.8).named('C Envelope').db(30)
  c_out = (c_osc * c_env).named('C Out')

  sum = a_out + c_out

  filt_freq = (bfreq.call * 15).clip(5000, 12000)
  g = sum.filter(:lowpass, gain: 1, cutoff: filt_freq) # Try to cut down on aliasing chalkboard noise

  final = g * 0.5

  MB::Sound::MIDI::GraphVoice.new(
    final,
    update_rate: manager.update_rate,
    amp_envelopes: ['A Envelope', 'C Envelope'],
    freq_constants: freq_constants
  ).named('FM Tubular Bell').tap { |v|
    v.on_velocity(['B into A', 'D into C'], range: 0.5..1.5, relative: true)
    v.on_velocity(['A Out', 'C Out'], range: 0.5..1.0, relative: true)
    #v.on_cc(1, ['B Ratio', 'D Ratio'], range: 5.0..7.0, relative: false)
  }
}

pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  voices
)
output_chain = pool.softclip(0.8, 0.95)

if ENV['DEBUG'] == '1'
  puts 'saving before graph'
  File.write('/tmp/pm_bass_before.dot', output_chain.graphviz)
  `dot -Tpng /tmp/pm_bass_before.dot -o /tmp/pm_bass_before.png`
end

puts MB::U.syntax(manager.to_acid_xml, :xml)

begin
  puts 'starting loop'
  loop do
    manager.update
    output.write([output_chain.sample(output.buffer_size)])

    if midi&.empty?
      pool.all_off
      midi.seek(0) if repeat
    end
    break if midi&.empty? && !pool.active? && !repeat
  end
ensure
  if ENV['DEBUG'] == '1'
    puts 'saving after graph'
    File.write('/tmp/pm_bass_after.dot', output_chain.graphviz)
    `dot -Tpng /tmp/pm_bass_after.dot -o /tmp/pm_bass_after.png`
  end
end
