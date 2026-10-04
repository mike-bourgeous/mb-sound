#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures delay workloads as a percentage of realtime (CPU time per second
# of audio), for comparing delay implementations: constant delays (integer,
# fractional, smoothed, tempo-synced), feedback (longer and shorter than a
# buffer), modulated delays, multitap delays, and reverbs built on delays.
# Every workload delays the same cheap source (shown first) in mono.
#
# Usage: $0 [options]
#
# Examples:
#     $0 --seconds 10
#     $0 --only multitap,feedback --buffer 128

require 'bundler/setup'
require 'mb-sound'

RATE = 48000

def source
  MB::Sound.noise.at(0.5)
end

# Interpolation mode for the delay workloads (see --interpolation)
$interpolation = :linear

def interp
  { interpolation: $interpolation }
end

WORKLOADS = {
  'source only' => -> { source },
  'constant 480 samples' => -> { source.delay(0.01, smoothing: false, **interp) },
  'constant, smoothing on (default)' => -> { source.delay(0.01, **interp) },
  'constant fractional (node)' => -> { source.delay(seconds: (480.4 / RATE).constant(smoothing: false), smoothing: false, **interp) },
  'tempo 3.n32 + feedback' => -> { source.delay(3.n32, feedback: 0.5, dry: 1, **interp) },
  'feedback, 0.25 s' => -> { source.delay(0.25, feedback: 0.5, smoothing: false, dry: 1, **interp) },
  'feedback, 96 samples' => -> { source.delay(96.0 / RATE, feedback: 0.5, smoothing: false, dry: 1, **interp) },
  'modulated (flanger LFO)' => -> { source.delay(seconds: 0.3.hz.lfo.at(0.001..0.008), smoothing: false, dry: 1, **interp) },
  'modulated + feedback' => -> { source.delay(seconds: 0.3.hz.lfo.at(0.001..0.008), feedback: 0.5, smoothing: false, dry: 1, **interp) },
  'multitap, 3 constant taps' => -> { source.multitap(0.1, 0.2, 0.3, **interp).to_a.sum },
  'multitap, 2 modulated taps' => -> { source.multitap(0.5.hz.lfo.at(0.001..0.005), 0.7.hz.lfo.at(0.002..0.006), **interp).to_a.sum },
  'reverb :hall' => -> { source.reverb(:hall) },
}.freeze

MB::Sound.script(
  seconds: [5.0, '-s', 'Seconds of audio per workload', 0.1..],
  buffer: [800, '-b', Integer, 'Buffer size in samples', 1..],
  only: [nil, String, 'Comma-separated substrings; only matching workloads'],
  interpolation: ['linear', String, 'Delay interpolation: linear, cubic, or sinc'],
) { |_, p|
  $interpolation = p.interpolation.to_sym
  buffers = (p.seconds * RATE / p.buffer).ceil
  puts format('%-34s %10s %10s', 'workload', 'realtime %', 'µs/buffer')

  WORKLOADS.each do |name, build|
    next if p.only && p.only.split(',').none? { |o| name.include?(o) }

    MB::Sound.rewind
    graph = build.call
    10.times { graph.sample(p.buffer) } # warm up

    t = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    buffers.times { graph.sample(p.buffer) }
    elapsed = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t

    audio = buffers * p.buffer.to_f / RATE
    puts format('%-34s %10.2f %10.1f', name, elapsed / audio * 100, elapsed / buffers * 1e6)
  end
}
