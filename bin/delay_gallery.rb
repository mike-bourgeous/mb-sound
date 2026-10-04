#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Renders a gallery of delay test sounds, one file per case, for null tests
# of delay changes (see bin/null_test.rb): constant integer and fractional
# delays, smoothing, feedback (long and shorter than a buffer), modulated
# delays (slow and fast enough to pitch up), tempo delays, buffer growth,
# complex input, multitap delays, and the reverbs built on delays.
#
# When the delay API changes, each case is rewritten in the new API to
# describe the same sound, and the null test compares the renders.
#
# Usage: $0 [options] output_directory
#
# Examples:
#     $0 /tmp/delays                      # every case
#     $0 --only multitap /tmp/delays      # cases whose names contain multitap
#     $0 --list                           # case names

require 'bundler/setup'
require 'mb-sound'

# A bright, steady input: a sawtooth plus a high triangle.
def source
  220.hz.ramp.at(0.3) + 1830.hz.triangle.at(0.2)
end

# Delay times in seconds for a number of samples at 48 kHz.
def samples(n)
  n / 48000.0
end

# Case name => lambda returning a node (mono) or [left, right] (stereo)
CASES = {
  const_int: -> { source.delay(samples(480), smoothing: false, dry: 0.5, wet: 0.5) },
  const_frac_node: -> { source.delay(seconds: samples(480.4).constant(smoothing: false), smoothing: false) },
  const_smoothed: -> { source.delay(0.01, dry: 0.5, wet: 0.5) },
  smoothing_jumps: -> { source.delay(seconds: 2.hz.square.lfo.at(0.004..0.02), dry: 0.5, wet: 0.5) },
  feedback_long: -> { source.delay(0.05, feedback: 0.6, dry: 1) * 0.3 },
  feedback_short: -> { source.delay(samples(96), feedback: 0.7, dry: 1, smoothing: false) },
  feedback_negative: -> { source.delay(samples(250), feedback: -0.8, dry: 1, smoothing: false) * 0.3 },
  modulated_slow: -> { source.delay(seconds: 0.5.hz.lfo.at(0.001..0.008), smoothing: false, dry: 1) },
  modulated_fast: -> { source.delay(seconds: 8.hz.lfo.at(0.001..0.02), smoothing: false) },
  modulated_feedback: -> { source.delay(seconds: 0.7.hz.lfo.at(0.002..0.006), feedback: 0.6, smoothing: false, dry: 1) * 0.3 },
  modulated_smoothed: -> { source.delay(seconds: 3.hz.lfo.at(0.001..0.03), dry: 0.5, wet: 0.5) },
  tempo_delay: -> { source.delay(3.n32, feedback: 0.5, dry: 1) },
  growth: -> { source.delay(seconds: 0.7.hz.ramp.lfo.with_phase(Math::PI).at(0.01..0.3), max_delay: 0.05, smoothing: false) },
  complex: -> {
    d = 330.hz.complex_ramp.at(0.15).delay(samples(300.5).constant(smoothing: false), smoothing: false, feedback: 0.5, dry: 1)
    [d.real, d.imag]
  },
  multitap_int: -> { source.multitap(0.01, 0.02, 0.03).to_a.sum * 0.5 },
  multitap_frac: -> { source.multitap(samples(480.25), samples(960.5), samples(1440.75)).to_a.sum * 0.5 },
  multitap_modulated: -> { source.multitap(0.5.hz.lfo.at(0.001..0.005), 0.7.hz.lfo.at(0.002..0.006)).to_a.sum * 0.5 },
  multitap_stereo: -> { source.multitap(0.01, samples(733.3)).to_a },
  reverb_hall: -> { source.reverb(:hall) },
  fdn_reverb: -> { source.fdn_reverb(seed: 1) },
}

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
    sound = sound.outputs if sound.respond_to?(:outputs) && sound.channel_count > 1
    channels = sound.is_a?(Array) ? sound.length : 1
    path = File.join(outdir, "#{name}.flac")
    MB::Sound.render(path, sound, seconds: p.seconds, bpm: 120, channels: channels, gain: 1, overwrite: true)
    puts "#{name}: #{path}"
  end
}
