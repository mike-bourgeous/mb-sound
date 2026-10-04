#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Renders a gallery of oscillator test sounds, one file per case, for null
# tests of oscillator changes (see bin/null_test.rb): every wave type, complex
# waves, phase, ranges, FM/PM, noise, notes, tuning, tempo LFOs, and a clip.
#
# When the oscillator API changes, each case is rewritten in the new API to
# describe the same sound, and the null test compares the renders.
#
# Usage: $0 [options] output_directory
#
# Examples:
#     $0 /tmp/gallery                 # every case
#     $0 --only fm,pm /tmp/gallery    # cases whose names contain fm or pm
#     $0 --list                       # case names

require 'bundler/setup'
require 'mb-sound'

# Case name => lambda returning a node (mono) or [left, right] (stereo)
CASES = {}

[:sine, :triangle, :square, :ramp, :gauss, :parabola].each do |wave|
  [110, 1760].each do |f|
    CASES[:"#{wave}_#{f}"] = -> { f.hz.send(wave).at(0.5) }
  end
end

# Naive (aliased) versions of the band-limited shapes
[:atriangle, :asquare, :aramp].each do |wave|
  CASES[:"#{wave}_1760"] = -> { 1760.hz.send(wave).at(0.5) }
end

# Phase warp (pulse width modulation for every shape)
CASES.merge!(
  pulse_1760: -> { 1760.hz.pulse(0.25).at(0.5) },
  apulse_1760: -> { 1760.hz.apulse(0.25).at(0.5) },
  pulse_keep_dc: -> { 220.hz.pulse(0.1, dc: true).at(0.5) },
  pwm_sweep: -> { 220.hz.pwm(0.5.hz.lfo.at(0.05..0.95)).square.at(0.5) },
  skew_triangle: -> { 440.hz.triangle.skew(0.1).at(0.5) },
  sine_pwm: -> { 220.hz.sine.pwm(0.2).at(0.5) },
  ramp_pwm: -> { 330.hz.ramp.pwm(0.7).at(0.5) },
)

# Hard and soft sync
CASES.merge!(
  sync_ramp: -> { 110.hz.ramp.sync(ratio: 2.37).at(0.5) },
  sync_sweep: -> { 110.hz.ramp.sync(ratio: 0.5.hz.lfo.at(1..5)).at(0.5) },
  async_ramp: -> { 110.hz.aramp.sync(ratio: 2.37).at(0.5) },
  softsync_triangle: -> { 110.hz.triangle.softsync(ratio: 1.7).at(0.5) },
  sync_pulse_master: -> { 220.hz.pulse(0.3).sync(110.hz.square).at(0.5) },
)

[:complex_sine, :complex_square, :complex_triangle, :complex_ramp].each do |wave|
  CASES[:"#{wave}_220"] = -> {
    osc = 220.hz.send(wave).at(0.5)
    [osc.real, osc.imag]
  }
end

CASES.merge!(
  phase_60deg: -> { 220.hz.sine.with_phase(Math::PI / 3).at(0.5) },
  range_lfo: -> { 3.hz.triangle.at(-0.2..0.7) },
  slow_ramp: -> { 0.3.hz.ramp.at(0.5) },
  fm: -> { 220.hz.sine.fm(110.hz.sine.at(300)).at(0.5) },
  log_fm: -> { 220.hz.sine.log_fm(55.hz.sine.at(2)).at(0.5) },
  pm: -> { 220.hz.sine.pm(330.hz.sine.at(2)).at(0.5) },
  pm_chain: -> { 110.hz.triangle.pm(220.hz.sine.pm(440.hz.sine.at(1)).at(2)).at(0.5) },
  noise: -> { 1.hz.noise.at(0.3) },
  noisy_sine: -> { 440.hz.sine.noise(false).at(0.3) },
  note_a4: -> { MB::Sound::A4.triangle.at(0.5) },
  note_cs5_square: -> { MB::Sound::Cs5.square.at(0.3) },
  tuning_b4_480: -> {
    MB::Sound.tuning b4: 480 # reset after each case
    MB::Sound::B4.sine.at(0.5)
  },
  oscillator_direct: -> { MB::Sound::Oscillator.new(:triangle, frequency: 330, range: -0.5..0.5) },
  tone_lowpass: -> { 440.hz.ramp.at(0.5).filter(880.hz.lowpass(quality: 2)) },
  tempo_lfo: -> { 220.hz.sine.at(0.5) * 1.beat.lfo.at(0..1) },
  tempo_lfo_square: -> { 330.hz.triangle.at(0.5) * 2.beats.lfo.square.at(0.2..1) },
  freewheel_lfo: -> { 220.hz.ramp.at(0.5) * 1.beat.lfo.freewheel.at(0..1) },
  clip_bass: -> {
    bass = MB::Sound.seq(MB::Sound::C2, MB::Sound::G1, MB::Sound.rest, MB::Sound::C3).n8.loop
    bass.tone.ramp.at(0.5) * bass.env
  },
)

MB::Sound.script(
  args: 0..1,
  seconds: [1.0, '-s', 'Length of each case in seconds', 0.01..],
  only: [nil, String, 'Comma-separated substrings; render only matching cases'],
  list: [false, '-l', 'List case names and exit'],
) { |(outdir), p|
  if p.list
    puts CASES.keys
    next
  end
  abort 'Give an output directory (see --help)' unless outdir

  names = CASES.keys
  names = names.select { |n| p.only.split(',').any? { |o| n.to_s.include?(o) } } if p.only

  FileUtils.mkdir_p(outdir)
  names.each do |name|
    MB::Sound.rewind
    sound = CASES.fetch(name).call
    channels = sound.is_a?(Array) ? sound.length : 1
    path = File.join(outdir, "#{name}.flac")
    MB::Sound.render(path, sound, seconds: p.seconds, bpm: 120, channels: channels, overwrite: true)
    MB::Sound.tuning.reset
    puts "#{name}: #{path}"
  end
}
