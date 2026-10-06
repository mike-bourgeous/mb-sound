#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures container types for an oscillator's per-buffer state
# (Tone/Oscillator consolidation, 2026-10-06), with and without YJIT.
#
# Each buffer does what Oscillator#sample_c does with its state: read the
# phase and band-limiting Arrays that the C kernel updates in place, note
# the phase at the frame start (for ports), check the queued phase-jump
# residual and the reset-ended flag, run the kernel, and store the last
# frequency and width.  The kernel is either a stub (two Array writes, so
# the state access dominates) or the real FastSynth.oscillate_bl band-limited
# ramp at --buffer samples, for proportion.
#
# Types: ivars on the node itself (the code before the consolidation), a
# class with attr_accessor, Struct (positional and keyword_init), Data
# (immutable; each buffer makes a new one with #with), a Hash, an Array
# tuple with index constants, and a frozen Struct whose per-buffer scalars
# live in a mutable Array.
#
# Measured 2026-10-06 (16-core container, best of 7 runs of 200000
# buffers; ns per buffer, real kernel at 128 samples):
#
#     type                          YJIT stub  YJIT real  interp stub  interp real
#     node ivars (before)                59.6     1701.7        130.9       1769.8
#     class + attr_accessor              67.2     1686.0        176.2       1825.3
#     Struct                             83.4     1706.2        165.5       1804.1
#     Struct keyword_init                88.1     1732.0        166.0       1792.6
#     Data (#with per buffer)          1102.7     2858.8       1236.9       2934.7
#     Hash                              184.4     1826.7        265.0       1954.3
#     Array tuple                       150.9     1806.7        190.6       1849.7
#     frozen Struct + scalar Array       91.5     1718.2        192.2       1851.8
#
# Chosen: a class with attr_accessor (Tone::State): 8 ns more than ivars on
# the node under YJIT (scripts run with YJIT), under 1% of one band-limited
# kernel call, with explicit names for serializing.
#
# Usage: $0 [options]
#
# Examples:
#     $0                      # table for YJIT and the interpreter
#     $0 --buffers 300000 --buffer 512

require 'bundler/setup'
require 'rbconfig'
require 'mb-sound'

module OscStateBenchmark
  STATE_FIELDS = [:phase, :blep, :jump_residual, :reset_ended, :last_freq, :last_width, :frame_phase].freeze

  def self.new_arrays
    [[0.0], [0.0, 0.0, 0.0, 0]]
  end

  # The kernel: a stub, or the real band-limited ramp.
  class Kernel
    def initialize(real, buffer)
      @real = real
      @buf = Numo::SFloat.zeros(buffer)
      @advance = 1.0 / 48000
    end

    def run(freq, phase, blep)
      if @real
        MB::Sound::FastSynth.oscillate_bl(@buf.inplace!, :ramp, freq, 0, @advance, 1.0, 0.0, phase, blep, 0.0, 0.0, nil, true)
      else
        phase[0] = (phase[0] + 0.01) % 1.0
        blep[3] = 1
      end
    end
  end

  # Baseline: ivars on the node itself.
  class NodeIvars
    def initialize(kernel)
      @kernel = kernel
      @phase, @blep = OscStateBenchmark.new_arrays
      @jump_residual = nil
      @reset_ended = false
      @last_freq = 0.0
      @last_width = nil
      @frame_phase = 0.0
    end

    def step(freq)
      @frame_phase = @phase[0]
      @kernel.run(freq, @phase, @blep)
      add_residual if @jump_residual
      return if @reset_ended

      @last_freq = freq
      @last_width = nil
    end

    def add_residual; end
  end

  class ClassState
    attr_accessor(*STATE_FIELDS)

    def initialize
      @phase, @blep = OscStateBenchmark.new_arrays
      @jump_residual = nil
      @reset_ended = false
      @last_freq = 0.0
      @last_width = nil
      @frame_phase = 0.0
    end
  end

  PositionalStruct = Struct.new(*STATE_FIELDS)
  KeywordStruct = Struct.new(*STATE_FIELDS, keyword_init: true)
  DataState = Data.define(*STATE_FIELDS)
  FrozenStruct = Struct.new(:phase, :blep, :jump_residual, :reset_ended, :scalars)

  # Accessor-style state (class, Struct): s.field / s.field =
  class Accessors
    def initialize(kernel, state)
      @kernel = kernel
      @s = state
    end

    def step(freq)
      s = @s
      phase = s.phase
      s.frame_phase = phase[0]
      @kernel.run(freq, phase, s.blep)
      add_residual if s.jump_residual
      return if s.reset_ended

      s.last_freq = freq
      s.last_width = nil
    end

    def add_residual; end
  end

  # Data: immutable, replaced each buffer.
  class DataNode
    def initialize(kernel)
      @kernel = kernel
      phase, blep = OscStateBenchmark.new_arrays
      @s = DataState.new(phase: phase, blep: blep, jump_residual: nil, reset_ended: false, last_freq: 0.0, last_width: nil, frame_phase: 0.0)
    end

    def step(freq)
      s = @s
      phase = s.phase
      frame_phase = phase[0]
      @kernel.run(freq, phase, s.blep)
      add_residual if s.jump_residual
      return if s.reset_ended

      @s = s.with(last_freq: freq, last_width: nil, frame_phase: frame_phase)
    end

    def add_residual; end
  end

  class HashNode
    def initialize(kernel)
      @kernel = kernel
      phase, blep = OscStateBenchmark.new_arrays
      @s = { phase: phase, blep: blep, jump_residual: nil, reset_ended: false, last_freq: 0.0, last_width: nil, frame_phase: 0.0 }
    end

    def step(freq)
      s = @s
      phase = s[:phase]
      s[:frame_phase] = phase[0]
      @kernel.run(freq, phase, s[:blep])
      add_residual if s[:jump_residual]
      return if s[:reset_ended]

      s[:last_freq] = freq
      s[:last_width] = nil
    end

    def add_residual; end
  end

  class ArrayNode
    PHASE, BLEP, JUMP_RESIDUAL, RESET_ENDED, LAST_FREQ, LAST_WIDTH, FRAME_PHASE = 0, 1, 2, 3, 4, 5, 6

    def initialize(kernel)
      @kernel = kernel
      phase, blep = OscStateBenchmark.new_arrays
      @s = [phase, blep, nil, false, 0.0, nil, 0.0]
    end

    def step(freq)
      s = @s
      phase = s[PHASE]
      s[FRAME_PHASE] = phase[0]
      @kernel.run(freq, phase, s[BLEP])
      add_residual if s[JUMP_RESIDUAL]
      return if s[RESET_ENDED]

      s[LAST_FREQ] = freq
      s[LAST_WIDTH] = nil
    end

    def add_residual; end
  end

  class FrozenNode
    LAST_FREQ, LAST_WIDTH, FRAME_PHASE = 0, 1, 2

    def initialize(kernel)
      @kernel = kernel
      phase, blep = OscStateBenchmark.new_arrays
      @s = FrozenStruct.new(phase, blep, nil, false, [0.0, nil, 0.0]).freeze
    end

    def step(freq)
      s = @s
      phase = s.phase
      sc = s.scalars
      sc[FRAME_PHASE] = phase[0]
      @kernel.run(freq, phase, s.blep)
      add_residual if s.jump_residual
      return if s.reset_ended

      sc[LAST_FREQ] = freq
      sc[LAST_WIDTH] = nil
    end

    def add_residual; end
  end

  TYPES = {
    'node ivars (before)' => ->(k) { NodeIvars.new(k) },
    'class + attr_accessor' => ->(k) { Accessors.new(k, ClassState.new) },
    'Struct' => ->(k) { p, b = OscStateBenchmark.new_arrays; Accessors.new(k, PositionalStruct.new(p, b, nil, false, 0.0, nil, 0.0)) },
    'Struct keyword_init' => ->(k) { p, b = OscStateBenchmark.new_arrays; Accessors.new(k, KeywordStruct.new(phase: p, blep: b, jump_residual: nil, reset_ended: false, last_freq: 0.0, last_width: nil, frame_phase: 0.0)) },
    'Data (#with per buffer)' => ->(k) { DataNode.new(k) },
    'Hash' => ->(k) { HashNode.new(k) },
    'Array tuple' => ->(k) { ArrayNode.new(k) },
    'frozen Struct + scalar Array' => ->(k) { FrozenNode.new(k) },
  }.freeze

  # Nanoseconds per buffer for each type: best of +rounds+ runs of
  # +buffers+ buffers, alternating types.
  def self.measure(real:, buffer:, buffers:, rounds:)
    nodes = TYPES.transform_values { |f| f.call(Kernel.new(real, buffer)) }
    nodes.each_value { |n| 20000.times { n.step(440.0) } } # warm up (YJIT compiles)
    best = TYPES.keys.to_h { |k| [k, Float::INFINITY] }
    rounds.times do
      nodes.each do |name, n|
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        i = 0
        while i < buffers
          n.step(440.0)
          i += 1
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
        best[name] = elapsed if elapsed < best[name]
      end
    end
    best.transform_values { |s| s * 1e9 / buffers }
  end
end

MB::Sound.script(
  buffers: [200000, Integer, '-n', 'Buffers per run', 1000..],
  rounds: [7, Integer, '-r', 'Runs per type (best is kept)', 1..],
  buffer: [128, Integer, '-b', 'Samples per buffer for the real kernel', 1..],
  child: [nil, String, 'Internal: measure in this process and print JSON (stub or real)'],
) { |_args, p|
  if p.child
    require 'json'
    puts JSON.generate(OscStateBenchmark.measure(real: p.child == 'real', buffer: p.buffer, buffers: p.buffers, rounds: p.rounds))
    next
  end

  require 'json'
  results = {}
  { 'YJIT' => '1', 'interpreter' => '0' }.each do |mode, yjit|
    %w[stub real].each do |kernel|
      args = [RbConfig.ruby, __FILE__, '--child', kernel, '-n', p.buffers.to_s, '-r', p.rounds.to_s, '-b', p.buffer.to_s]
      text = IO.popen({ 'RUBY_YJIT_ENABLE' => yjit }, args, &:read)
      abort "Child failed: #{text}" unless $?.success?
      results[[mode, kernel]] = JSON.parse(text)
    end
  end

  cols = results.keys
  puts format('%-30s %s', 'ns per buffer', cols.map { |m, k| format('%18s', "#{m} #{k}") }.join)
  OscStateBenchmark::TYPES.each_key do |name|
    puts format('%-30s %s', name, cols.map { |c| format('%18.1f', results[c][name]) }.join)
  end
  puts "(real kernel: band-limited ramp, #{p.buffer} samples; best of #{p.rounds} runs of #{p.buffers} buffers)"
}
