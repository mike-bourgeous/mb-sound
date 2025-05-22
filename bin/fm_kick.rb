#!/usr/bin/env ruby
# Trying to synthesize a kick inspired by a YouTube tutorial:
# https://www.youtube.com/watch?v=ndG-6-vONNc

require 'bundler/setup'

require 'mb-sound'

pry_next = false
MB::U.sigquit_backtrace do
  pry_next = true
end

# Generates a node graph and GraphVoice to synthesize a kick
def kicker
  pitch_decay = 0.13
  decay_time = 0.18

  # TODO: the node graph and GraphVoice really need some concept of i/o ports
  # and configurable parameters.
  #
  # Also the envelope generator needs to be smarter about dynamic parameter
  # changes.
  base = 440.constant
  freq_constants = []
  bfreq = -> { 2 ** base.dup.tap { |z| freq_constants << z }.log2.smooth(seconds: 0.0001) }

  attack_hz = 100.constant.named('Attack Hz')
  attack_env = attack_hz.adsr(0.0005, pitch_decay, 0, pitch_decay, log: 60) # fast click at start
  pitch_env = MB::Sound.adsr(0.0005, decay_time, 0, decay_time) # semitone fall over full decay

  noise_cutoff = 1500.constant.named('Noise cutoff')
  noise_source = 1000.hz.gauss.noise.at(0.4).filter(:lowpass, cutoff: noise_cutoff).adsr(0.0001, 0.04, 0, 0.04, log: 60)

  falling_sine = (attack_env + bfreq.call * (0.06 * pitch_env + 0.97)).tone.at(1).pm(noise_source)
  falling_sine_amp = falling_sine.adsr(0.0001, decay_time, 0, decay_time, log: 60)

  sub = falling_sine_amp.peq({
    30.hz => 9.db,
    95.hz => [6.db, 0.5],
    600.hz => [-20.db, 1.5],
    9000.hz => [25.db, 1.5],
  })

  ################################################

  boom_sine_decay = 0.4
  boom_noise_decay = 0.7

  boom_noise_cutoff = 10000.constant.named('Noise cutoff')
  boom_noise_gain = 2500.constant.named('Noise gain')
  boom_noise = 10000.hz.ramp.noise
    .at(1)
    .filter(:lowpass, cutoff: boom_noise_cutoff)
    .adsr(0.0001, boom_noise_decay, 0.0, boom_noise_decay, log: 40)

  boom_sine = 143.hz.at(1).fm(boom_noise * boom_noise_gain)
    .adsr(0.008, boom_sine_decay, 0.0, boom_sine_decay, log: 50)
    .adsr(0.008, boom_sine_decay, 0.0, boom_sine_decay)

  boom = boom_sine.peq({
    20.hz => [-20.db, 1],
    60.hz => [11.db, 0.6],
    100.hz => [6.db, 0.6],
    133.hz => [-9.db, 0.3],
    180.hz => [3.db, 2],
    350.hz => 4.db,
    950.hz => [-12.db, 3],
    6000.hz => [-4.db, 3],
    12000.hz => [-1.db, 1],
    45.hz => [3.db, 0.1],
    95.hz => [2.db, 0.1],
  })

  ################################################


  final = sub * 1 + boom * 0.1

  MB::Sound::MIDI::GraphVoice.new(
    final,
    freq_constants: freq_constants
  ).named('Kick').tap { |v|
    #v.on_cc(1, 'Attack Hz', range: 0..2000, relative: false)
    #v.on_cc(1, 'Noise cutoff', range: 0..10000, relative: false)
    #v.on_cc(1, 'Noise gain', range: 0..10000, relative: false)
  }
end

OSC_COUNT = ENV['OSC_COUNT']&.to_i || 2

voices = Array.new(OSC_COUNT) { kicker }

# TODO: Build an abstraction around switching between Jack and MIDI files for
# input, and FLAC files for output, for use by all synthesizers
jack = MB::Sound::JackFFI[]
output = jack.output(channels: 1, connect: [['system:playback_1', 'system:playback_2']])
midi = MB::Sound::MIDI::MIDIFile.new(ARGV[0]) if ARGV[0]&.end_with?('.mid') # TODO: Add a clock source based on jackd frames
manager = MB::Sound::MIDI::Manager.new(jack: jack, input: midi, connect: ARGV[0])
pool = MB::Sound::MIDI::VoicePool.new(
  manager,
  voices
)

output_chain = (pool * -15.db).softclip(0.6, 0.99)

if ENV['DEBUG'] == '1'
  puts 'saving before graph'
  File.write('/tmp/fm_kick_before.dot', output_chain.graphviz)
  `dot -Tpng /tmp/fm_kick_before.dot -o /tmp/fm_kick_before.png`
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
    areak if midi&.empty? && !pool.active? && !repeat

    #puts pool.find_by_name('Noise gain').constant

    if pry_next
      require 'pry-byebug'
      binding.pry
      pry_next = false
    end
  end
ensure
  if ENV['DEBUG'] == '1'
    puts 'saving after graph'
    File.write('/tmp/fm_kick_after.dot', output_chain.graphviz)
    `dot -Tpng /tmp/fm_kick_after.dot -o /tmp/fm_kick_after.png`
  end
end

