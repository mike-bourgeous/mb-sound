#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Measures oscillator-heavy workloads as a percentage of realtime (CPU time
# per second of audio), for comparing oscillator implementations: single
# oscillators, 8 voices of 6-operator FM (phase modulation chains), 8 voices
# of a 7-oscillator supersaw, and 32 LFOs.
#
# Usage: $0 [options]
#
# Example:
#     $0 --seconds 10

require 'bundler/setup'
require 'mb-sound'

BUFFER = 800
RATE = 48000

WORKLOADS = {
  'sine x1' => -> { 220.hz.sine.at(0.5) },
  'ramp x1' => -> { 220.hz.ramp.at(0.5) },
  'complex_sine x1' => -> { 220.hz.complex_sine.at(0.5).real },
  'fm 6-op x8 voices' => -> {
    voices = 8.times.map { |v|
      f = 110 * 2**(v / 12.0)
      # op6 -> op5 -> ... -> op1, each modulating the next one's phase
      mod = nil
      [7, 5, 3, 2, 1].each_with_index do |ratio, idx|
        op = (f * ratio).hz.sine.at(1)
        op = op.pm(mod) if mod
        mod = op * (1.5 - idx * 0.2)
      end
      f.hz.sine.at(0.1).pm(mod)
    }
    voices.sum
  },
  'supersaw 7 x8 voices' => -> {
    voices = 8.times.map { |v|
      f = 110 * 2**(v / 12.0)
      7.times.map { |i| (f * 2**((i - 3) * 0.1 / 12)).hz.ramp.at(0.02).with_phase(i) }.sum
    }
    voices.sum
  },
  'lfo x32' => -> { 32.times.map { |i| (0.1 + i * 0.37).hz.lfo.at(0..0.03) }.sum },
}.freeze

MB::Sound.script(
  seconds: [5.0, '-s', 'Seconds of audio per workload', 0.1..],
  only: [nil, String, 'Comma-separated substrings; only matching workloads'],
) { |_, p|
  buffers = (p.seconds * RATE / BUFFER).ceil
  puts format('%-24s %10s %10s', 'workload', 'realtime %', 'µs/buffer')

  WORKLOADS.each do |name, build|
    next if p.only && p.only.split(',').none? { |o| name.include?(o) }

    graph = build.call
    10.times { graph.sample(BUFFER) } # warm up

    t = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    buffers.times { graph.sample(BUFFER) }
    elapsed = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t

    audio = buffers * BUFFER.to_f / RATE
    puts format('%-24s %10.2f %10.1f', name, elapsed / audio * 100, elapsed / buffers * 1e6)
  end
}
