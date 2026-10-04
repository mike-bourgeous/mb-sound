#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# Measures the graph cost of a bin/ script (effect, synth, or song) as a
# percentage of realtime at one or more buffer sizes, and optionally the
# self time of each node class.  The script runs normally up to the point
# where it would play, then its graph is captured instead (effects and
# synths through ScriptRunner; songs through MB::Sound.bg, taking the
# players launched immediately).  Only the graph is measured: no Session
# mixing, master effects, or output.
#
# --profile wraps every node's #sample, which adds about 3 us per call, so
# cheap nodes called often (Constant, Tee branches) look more expensive than
# they are; compare self times between branches rather than reading them as
# absolute costs, and use the unprofiled percentages for speedups.
#
# Graphs that take an input (effects) get spec/test_data/arp_a7.flac unless
# script arguments name another file; synths need a MIDI file argument.
#
# Usage: $0 [options] script.rb [script arguments...]
#
# Examples:
#     $0 bin/effects/flanger.rb
#     $0 -n 32,128,800 --profile bin/effects/tape_delay.rb
#     $0 bin/synths/fm_bass.rb spec/test_data/midi.mid
#     $0 -s 2 bin/songs/stereo_drone.rb
#
# Compare branches by running the same command in each worktree, in
# alternating order (other work on the machine skews single runs).

require 'bundler/setup'
require 'mb-sound'

# Captures graphs instead of playing them.
module GraphCapture
  class Captured < StandardError
    attr_reader :graph

    def initialize(graph)
      @graph = graph
      super('captured')
    end
  end

  @songs = []

  class << self
    attr_reader :songs
  end

  module RunnerHook
    def play_or_render(graph)
      raise Captured.new(graph)
    end
  end
  MB::Sound::ScriptRunner.prepend(RunnerHook)

  module BgHook
    def bg(name = nil, graph = nil, **kwargs, &block)
      graph = name if graph.nil? && !name.is_a?(Symbol) && !name.is_a?(String)
      GraphCapture.songs << graph if graph
      nil
    end
  end
end

# Accumulates self time per node class (see --profile).
module SelfTime
  @totals = Hash.new(0.0)
  @calls = Hash.new(0)
  @stack = []

  class << self
    attr_reader :totals, :calls

    def wrap(node)
      return if node.instance_variable_get(:@__self_time_wrapped)

      node.instance_variable_set(:@__self_time_wrapped, true)
      klass = node.class.name.sub(/\AMB::Sound::/, '')
      stack = @stack
      totals = @totals
      calls = @calls
      node.singleton_class.prepend(Module.new do
        define_method(:sample) do |*args|
          t0 = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
          stack.push(0.0)
          begin
            super(*args)
          ensure
            children = stack.pop
            elapsed = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - t0
            totals[klass] += elapsed - children
            calls[klass] += 1
            stack[-1] += elapsed unless stack.empty?
          end
        end
      end)
    end

    def reset
      @totals.clear
      @calls.clear
    end
  end
end

def capture_graph(script, args)
  ARGV.replace(args)
  $0 = script
  graph = nil

  MB::Sound.singleton_class.prepend(GraphCapture::BgHook) unless MB::Sound.singleton_class.include?(GraphCapture::BgHook)
  GraphCapture.songs.clear
  begin
    load script
  rescue GraphCapture::Captured => e
    graph = e.graph
  end

  if graph.nil?
    songs = GraphCapture.songs
    raise "#{script} produced no graph (is it an effect, synth, or song script?)" if songs.empty?

    graph = songs.size == 1 ? songs.first : songs
  end

  graph
end

# Every output channel to sample each buffer.
def outputs_of(graph)
  list = graph.is_a?(Array) ? graph : [graph]
  list.flat_map { |g| g.respond_to?(:outputs) ? g.outputs.to_a : [g] }
end

# Every node feeding the outputs (for --profile).
def nodes_of(outputs)
  outputs.flat_map { |o| o.respond_to?(:graph) ? o.graph(include_tees: true) : [o] }.uniq
end

MB::Sound.script(
  args: 1..,
  buffer: ['800', String, 'Comma-separated buffer sizes', '-n'],
  seconds: [4.0, '-s', 'Seconds of audio per buffer size', 0.1..],
  profile: [false, 'Also report self time per node class (slower; shares are what matter)'],
) { |args, p|
  script, *script_args = args
  sizes = p.buffer.split(',').map { |v| Integer(v) }

  script_args << '-q' unless script_args.include?('-q') # don't print the script's parameters

  # Effects get the short test file unless an audio file was given
  if File.read(script).include?('effect_script') && script_args.none? { |a| a.match?(/\.(flac|wav|mp3|ogg)\z/i) }
    script_args << File.expand_path('../spec/test_data/arp_a7.flac', __dir__)
  end

  sizes.each do |n|
    graph = capture_graph(script, script_args.dup)
    outputs = outputs_of(graph)
    SelfTime.reset
    nodes_of(outputs).each { |node| SelfTime.wrap(node) if node.respond_to?(:sample) && !node.frozen? } if p.profile

    10.times { outputs.each { |o| o.sample(n) } } # warm up
    frames = (p.seconds * 48000 / n).ceil
    t0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    done = frames.times do |i|
      ended = outputs.map { |o| o.sample(n) }.any?(&:nil?)
      break i if ended
    end
    elapsed = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t0
    played = (done.is_a?(Integer) ? done : frames) * n / 48000.0

    puts format('%-40s buffer %5d: %7.1f%% of realtime (%d outputs, %.1f s%s)',
      File.basename(script), n, 100 * elapsed / played, outputs.size, played, p.profile ? ', profiled' : '')

    next unless p.profile

    total = SelfTime.totals.values.sum
    SelfTime.totals.sort_by { |_, t| -t }.first(12).each do |klass, t|
      puts format('    %-44s %5.1f%%  %8.2f us/call  %8d calls', klass, 100 * t / total, t / SelfTime.calls[klass] * 1e6, SelfTime.calls[klass])
    end
  end
}
