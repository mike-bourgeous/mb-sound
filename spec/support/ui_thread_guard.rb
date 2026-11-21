require 'json'
require 'fileutils'

# Examples that leave terminal UI threads running (ui-perf-2 round 4): a
# tiled screen facade_spec never stopped kept its painter, input, and REPL
# threads for the rest of the process, so band_spec counted the painter's
# Thread.pass calls as its own and meta_invariance_spec counted its
# allocations (14-91 objects per 20 ms); live_threads_spec's sound screen
# left its preview workers registered as GVL yielders for their 10 s idle
# timeout, failing yielding_spec's empty registry.  Like
# support/child_guard.rb for the starter's children, this names the example
# that started them.
#
# A UI thread is one named by the UI code (NAMES: painters, the input and
# keys threads, preview and chart workers, the perf capture, a screen's REPL
# host threads, the specs' FakeTerminal readers) or carrying a screen in its
# thread-locals (:mb_sound_ui_tiles).  An example's UI threads are those
# alive after its own `after` blocks (and UIHelpers.close_screens) that
# weren't alive before it; each gets up to WAIT seconds to end, then:
#
# MB_SOUND_UI_THREAD_CHECK:
# - unset or "fail" (default): the example fails, naming each thread and
#   where it waits; the guard stops the screens they belong to and kills
#   what is left, so one leak fails one example;
# - "report": such examples are listed after the run instead (and appended
#   as JSON lines to $MB_SOUND_UI_THREAD_REPORT/<pid>.jsonl when that names
#   a directory);
# - "off": no check.
#
# Stop screens (Tiles#stop, Band#stop also close their panes' workers) and
# close workers in the example or an `after` block.  An example that hands
# a thread on to a later one on purpose says why with metadata:
# `leaves_ui_threads: 'the reason'`.  ALLOWED lists names of UI threads
# meant to live for the process, with why (none so far: the GVL yielder's
# kicker is a pthread, not a Ruby thread).
module UIThreadGuard
  MODES = %w[report fail off].freeze

  # Names of UI threads (exact Strings or patterns).
  NAMES = [
    /\AMB::Sound::UI\b/, # painters ('MB::Sound::UI'), 'MB::Sound::UI input', '... keys', '... perf capture'
    /\Amb-sound .* render\z/, # preview workers ('mb-sound patch render', 'mb-sound ToneCycle render', 'mb-sound chart render')
    /\AMB::Term (REPL|pty|command)\z/, # a screen's ReplHost threads (mb-term)
    'spec FakeTerminal reader', # UIHelpers::FakeTerminal
  ].freeze

  # Thread-locals that mark a thread as a screen's.
  KEYS = %i[mb_sound_ui_tiles].freeze

  # UI thread names allowed to outlive their example, with why.
  ALLOWED = {}.freeze

  # Seconds to wait for an example's UI threads to end.
  WAIT = 1.0

  @records = []

  class << self
    attr_reader :records

    def mode
      m = ENV.fetch('MB_SOUND_UI_THREAD_CHECK', 'fail')
      raise ArgumentError, "MB_SOUND_UI_THREAD_CHECK is one of #{MODES.join(', ')} (got #{m.inspect})" unless MODES.include?(m)
      m
    end

    def ui_thread?(t)
      name = t.name.to_s
      return false if ALLOWED.key?(name)
      NAMES.any? { |n| n === name } || KEYS.any? { |k| t.key?(k) }
    end

    # UI threads alive now that aren't in +before+ (an Array of Threads),
    # after waiting up to +wait+ seconds for them to end.
    def leftovers(before, wait: WAIT)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      loop do
        left = (Thread.list - before).select { |t| t.alive? && ui_thread?(t) }
        return left if left.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end

    def describe(list)
      list.map { |t|
        at = (t.backtrace || []).find { |l| l.include?('/lib/') || l.include?('/spec/') }&.sub(%r{\A.*?/(lib|spec|gems)/}, '\1/')
        "#{t.name.inspect} (#{t.status}#{at ? " at #{at}" : ''})"
      }.join('; ')
    end

    # Stops the screens +list+'s threads belong to, then kills and joins
    # what is still running.
    def clean_up(list)
      ui = MB::Sound::UI
      list.each { |t| (t[:mb_sound_ui_tiles]&.stop rescue nil) }
      ObjectSpace.each_object(ui::Tiles) { |s| (s.stop rescue nil) if s.active? || s.hidden? }
      ObjectSpace.each_object(ui::Band) { |s| (s.stop rescue nil) if s.active? }
      ObjectSpace.each_object(ui::ChartWorker) { |w| (w.close rescue nil) if list.include?(w.thread) }
      ObjectSpace.each_object(ui::PatchRender::Worker) { |w| (w.close rescue nil) if list.include?(w.thread) }
      list.each { |t| t.kill if t.alive? }
      list.each { |t| t.join(1) }
    end

    def record(example, list)
      rec = { 'example' => example.location, 'threads' => describe(list) }
      @records << rec
      dir = ENV['MB_SOUND_UI_THREAD_REPORT']
      return unless dir && !dir.empty?
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, "#{Process.pid}.jsonl"), 'a') { |f| f.puts(JSON.generate(rec)) }
    end
  end
end

unless UIThreadGuard.mode == 'off'
  RSpec.configure do |config|
    # (An around hook, outside the examples' own hooks and the screen
    # guard's, which is required after this file: screens stopped there
    # are clean)
    config.around(:each) do |example|
      before = Thread.list
      example.run
      next if example.metadata[:leaves_ui_threads]

      list = UIThreadGuard.leftovers(before)
      next if list.empty?

      if UIThreadGuard.mode == 'fail'
        text = UIThreadGuard.describe(list)
        UIThreadGuard.clean_up(list)
        raise "#{example.location} left #{list.length} terminal UI #{list.length == 1 ? 'thread' : 'threads'} running " \
              "(#{text}): stop the screen or close the worker in an after/ensure (spec/support/ui_thread_guard.rb)"
      end
      UIThreadGuard.record(example, list)
    end

    config.after(:suite) do
      list = UIThreadGuard.records
      unless list.empty?
        puts "\nExamples leaving terminal UI threads running (#{list.length}; MB_SOUND_UI_THREAD_CHECK=fail fails them):"
        list.first(40).each { |r| puts "  #{r['example']}  #{r['threads']}" }
        puts "  ... #{list.length - 40} more" if list.length > 40
      end
    end
  end
end
