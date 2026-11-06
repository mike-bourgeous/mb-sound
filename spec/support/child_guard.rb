require 'json'
require 'fileutils'

# Examples that leave children of the process starter running
# (fix-batch-1106): fix-flaky-1104 found 19 FFMPEGInput readers that their
# specs never closed, each an ffmpeg blocked on a full pipe until the GC
# closed its read end (one from graph_io_spec.rb alive through 1432 later
# examples), so starter_spec's "40 children at once" counted them.  Like
# support/session_guard.rb for the default Session, this names the example
# that started them.
#
# An example's children are those of MB::Sound::Starter.current that weren't
# running before it.  A child still running after the example's own `after`
# blocks (which run before this config-level hook) gets a short grace wait
# (WAIT seconds: a closed pipe ends ffmpeg within milliseconds), then:
#
# MB_SOUND_CHILD_CHECK:
# - unset or "fail" (default): the example fails, naming each child by id,
#   pid, and argv (close the input, or wait for the child, in the example
#   or an `after` block);
# - "report": such examples are listed after the run instead (and appended
#   as JSON lines to $MB_SOUND_CHILD_REPORT/<pid>.jsonl when that names a
#   directory);
# - "off": no check.
#
# An example that hands a child on to a later one on purpose says why with
# metadata: `leaves_children: 'the reason'`.  Children started directly
# (no starter: forks, MB_SOUND_STARTER=0) aren't seen.
module ChildGuard
  MODES = %w[report fail off].freeze

  # Seconds to wait for an example's children to end before calling them
  # left running.
  WAIT = 1.0

  @records = []

  class << self
    attr_reader :records

    def mode
      m = ENV.fetch('MB_SOUND_CHILD_CHECK', 'fail')
      raise ArgumentError, "MB_SOUND_CHILD_CHECK is one of #{MODES.join(', ')} (got #{m.inspect})" unless MODES.include?(m)
      m
    end

    # [starter, Set of child ids] for the current starter (nil if none).
    def snapshot
      s = MB::Sound::Starter.current
      s && [s, s.child_list.map { |c| c[:id] }]
    end

    # Children of the starter in +before+ (from #snapshot) that weren't
    # running then and are still running after up to +wait+ seconds, as
    # [{ id:, pid:, argv: }].
    def leftovers(before, wait: WAIT)
      return [] if before.nil?
      starter, ids = before
      return [] unless MB::Sound::Starter.current.equal?(starter)

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      loop do
        left = starter.child_list.reject { |c| ids.include?(c[:id]) }
        return left if left.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end

    def describe(list)
      list.map { |c| "##{c[:id]} pid #{c[:pid].inspect} #{Array(c[:argv]).flatten.join(' ')[0, 200]}" }.join('; ')
    end

    def record(example, list)
      rec = { 'example' => example.location, 'children' => describe(list) }
      @records << rec
      dir = ENV['MB_SOUND_CHILD_REPORT']
      return unless dir && !dir.empty?
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, "#{Process.pid}.jsonl"), 'a') { |f| f.puts(JSON.generate(rec)) }
    end
  end
end

# close_inputs(graph, ...) in examples: closes the process-backed inputs
# (FFMPEGInput) of each graph (a GraphNode, an input, or an Array or
# Channels of them) that the example read only part of.
module ChildGuardHelpers
  def close_inputs(*graphs)
    graphs.flat_map { |g| g.respond_to?(:to_a) && !g.is_a?(MB::Sound::GraphNode) ? g.to_a : [g] }.each do |g|
      [g, *(g.respond_to?(:graph) ? g.graph : [])].each { |n| n.close if n.is_a?(MB::Sound::IOInput) && n.runs_command? && !n.closed? }
    end
    nil
  end

  # `close_file_inputs_after_each` in a group: every FFMPEGInput its
  # examples open and leave open is closed after each (for files of
  # examples that read inputs only in part, e.g. ffmpeg_input_spec's lets).
  module ClassMethods
    def close_file_inputs_after_each
      before do
        @opened_file_inputs = []
        allow(MB::Sound::FFMPEGInput).to receive(:new).and_wrap_original { |m, *a, **k, &b| m.call(*a, **k, &b).tap { |i| @opened_file_inputs << i } }
      end

      after do
        @opened_file_inputs.each do |i|
          next if i.closed?
          begin
            i.close
          rescue RuntimeError
            nil # (an example checking a failing read)
          end
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.include ChildGuardHelpers
  config.extend ChildGuardHelpers::ClassMethods
end

unless ChildGuard.mode == 'off'
  RSpec.configure do |config|
    config.before(:each) do |example|
      example.metadata[:child_guard_before] = ChildGuard.snapshot unless example.metadata[:leaves_children]
    end

    config.after(:each) do |example|
      before = example.metadata.delete(:child_guard_before)
      next if example.metadata[:leaves_children]
      list = ChildGuard.leftovers(before)
      next if list.empty?
      if ChildGuard.mode == 'fail'
        raise "the example left #{list.length} starter #{list.length == 1 ? 'child' : 'children'} running " \
              "(#{ChildGuard.describe(list)}): close the input or wait for the child (spec/support/child_guard.rb)"
      end
      ChildGuard.record(example, list)
    end

    config.after(:suite) do
      list = ChildGuard.records
      unless list.empty?
        puts "\nExamples leaving starter children running (#{list.length}; MB_SOUND_CHILD_CHECK=fail fails them):"
        list.first(40).each { |r| puts "  #{r['example']}  #{r['children']}" }
        puts "  ... #{list.length - 40} more" if list.length > 40
      end
    end
  end
end
