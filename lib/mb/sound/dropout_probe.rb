require 'json'
require 'fileutils'
require 'time'

require_relative 'dropout_probe/analysis'
require_relative 'dropout_probe/report'

module MB
  module Sound
    # Tells where live dropouts come from (dropout-probe-1, 2026-11-01;
    # design/notes/latency_probe.md, Dropout probe): while a realtime
    # Session plays through a DeviceOutput, it logs every counted underrun
    # with what the render thread, the GC, YJIT, the adaptive queue, and the
    # machine were doing in the window before it, and gives each a likely
    # cause (Analysis).
    #
    #     probe = MB::Sound::DropoutProbe.start(MB::Sound::Session.current, json: 'tmp/dropouts.json')
    #     ...                                   # play
    #     probe.finish                          # report on stdout; .json, .csv, .txt
    #
    # What it reads, all from its own thread ('dropout-probe', waking every
    # +poll+ seconds) so the render and device threads only read clocks and
    # store numbers:
    # - the output's dropout trace (DeviceOutput#trace_start): each write's
    #   start and return, its wait for room, when the room appeared and when
    #   the wait noticed, the GVL back, the render thread's CPU time, and the
    #   queue; each counted underrun's time, frames short, and queue;
    # - FastUI::GVLProbe's log: the watched threads' (render, scheduler, the
    #   UI painter, main, the probes') waits for the GVL and times blocked off it, with
    #   the thread holding the GVL, and every GC step (an internal GC
    #   TracePoint, which YJIT ignores);
    # - per poll: GC counts (majors), YJIT compile time, the adaptive
    #   queue's state (DeviceOutput#adapt_state);
    # - a LatencyProbe (unless +system: false+): system stall episodes from
    #   a thread outside the GVL, and load, CPU, and memory per second.
    #
    # The render thread is never watched through a tap (taps run on it and
    # allocate).  Dropouts are analyzed +settle+ seconds after they happen
    # (a line each on stdout unless +quiet+), and again at #finish with
    # everything the LatencyProbe filed by then.
    class DropoutProbe
      # A write record (FastAudio::Playback#trace_drain), in order.
      WRITE_FIELDS = %i[enter exit wait room back pull cpu_enter cpu_exit queued limit frames].freeze

      # A gap record (one counted underrun), in order.
      GAP_FIELDS = %i[start end since frames available short pulls limit write_pos underrun late late_at].freeze

      # Threads the GVL probe watches, by name (GVLProbe has 6 slots): the
      # render thread, the scheduler (scene and patch builds), the UI
      # painter, main (the REPL in bin/sound.rb), and the probes' own.
      WATCH = {
        'render' => ->(session) { session.render_thread },
        'scheduler' => ->(_) { Thread.list.find { |t| t.name == 'MB::Sound::Session scheduler' } },
        'ui' => ->(_) { Thread.list.find { |t| t.name == 'MB::Sound::UI' } },
        'main' => ->(_) { Thread.main },
        'probe' => ->(_) { Thread.list.find { |t| t.name == 'dropout-probe' } },
        'latency' => ->(_) { Thread.list.find { |t| t.name == 'latency-consumer' } },
      }.freeze

      DEFAULTS = {
        json: nil,
        name: 'probe',
        system: true,
        ticker: false,
        poll: 0.1,
        settle: 1.0,
        keep: 30.0,
        gvl_threshold: 0.001,
        gc_threshold: 0.0001,
        seconds: nil,
        on_done: nil,
        quiet: false,
        max_dropouts: 10_000,
        meta: {},
        marks: nil,
        startup: Analysis::STARTUP,
      }.freeze

      @armed = nil

      class << self
        # Starts a probe on +session+ (see #initialize for the options).
        def start(session = Session.current, **opts)
          new(session, **opts).start
        end

        # Asks the next ScriptRunner live playback (#from_env) to run a
        # probe with +opts+ (bin/dropout_probe.rb).
        def arm(**opts)
          @armed = opts
        end

        # A started probe for +session+ when one was armed (.arm) or
        # MB_SOUND_DROPOUT_PROBE is set (a .json path, or 1 for
        # .default_path(+name+)), else nil.  How ScriptRunner#live probes any
        # live script; call #finish at the end.
        def from_env(session, name: 'probe', env: ENV)
          opts = @armed
          @armed = nil
          v = env['MB_SOUND_DROPOUT_PROBE'].to_s
          return nil if opts.nil? && (v.empty? || v == '0')

          opts = (opts || {}).dup
          opts[:json] ||= v.empty? || v == '1' || v == '0' ? default_path(name) : v
          opts[:name] ||= name
          start(session, **opts)
        end

        # tmp/dropout_probe/<name>-<local time>.json
        def default_path(name = 'probe')
          File.join('tmp', 'dropout_probe', "#{name}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.json")
        end

        def mono_ns
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        end
      end

      attr_reader :options, :session, :dropouts, :started_at, :stopped_at, :latency_probe

      # Options: +json+ (path for the JSON log; the .csv and .txt go beside
      # it, the LatencyProbe's files in <base>-latency/), +name+, +system+
      # (true: run a LatencyProbe), +ticker+ (false: its Ruby ticker, which
      # adds GVL traffic of its own), +poll+ (0.1 s), +settle+ (1 s before a
      # dropout is analyzed), +keep+ (30 s of records kept for windows),
      # +gvl_threshold+ (1 ms: the shortest GVL wait or block logged),
      # +gc_threshold+ (0.1 ms: the shortest GC step logged), +seconds+ and
      # +on_done+ (a Proc called once, from the probe's thread, after that
      # many seconds), +quiet+, +max_dropouts+ (10000 kept), +meta+ (a Hash
      # saved with the run), +marks+ (an object whose #marks lists
      # [monotonic ns, label] of things done on purpose, e.g.
      # bin/dropout_probe.rb's injected stalls, which the report matches
      # with the dropouts after them), +startup+ (2 s: dropouts this soon
      # after the output started are :startup).
      def initialize(session, **opts)
        unknown = opts.keys - DEFAULTS.keys
        raise ArgumentError, "Unknown dropout probe options: #{unknown.join(', ')} (known: #{DEFAULTS.keys.join(', ')})" unless unknown.empty?

        @options = DEFAULTS.merge(opts)
        @session = session
        @output = nil
        @traced = false
        @rate = nil
        @buffer = nil
        @thread = nil
        @stopping = false
        @started_at = nil
        @stopped_at = nil
        @started_mono = nil
        @offset = 0
        @latency_probe = nil
        @slots = []
        @last_watch = 0
        @lock = Mutex.new

        @writes = [] # raw write rows (WRITE_FIELDS), the last +keep+ seconds
        @threads = [] # thread log Hashes
        @gc = [] # GC step Hashes
        @samples = []
        @pending = [] # [gap Hash, due ns]
        @dropouts = []
        @idle = 0
        @first_write = nil
        @written_before = 0 # frames the output had written when the trace started
        @last_write = nil
        @prev_write = nil
        @queue_changes = [] # [ns, from, to] (device frames)
        @limit = nil
        @limit_history = [] # [ns, limit] for limit_before
        @major_counts = {}
        @gc_count = nil
        @gc_majors = nil
        @gc_count_seen = nil
        @gc_majors_seen = nil
        @underruns0 = nil
        @outputs = 0
        @done_called = false

        @hist = %i[render render_cpu wake gvl_back gvl_wait poll].to_h { |k| [k, LatencyProbe::Histogram.new] }
        @counts = Hash.new(0)
        @gc_by = Hash.new(0)
        @gvl_by = Hash.new(0)
        @gvl_top = [] # the render thread's 10 longest GVL waits: [ns, ready ns, holder]
        @yjit0 = nil
        @yjit_last = nil
        @cpu_ns = 0
        @poll_max_ns = 0 # the longest poll (the probe's thread holds the GVL for most of one)
        @polls = 0
        @trace_stats = nil
        @log_stats = nil
      end

      def running?
        !!@thread&.alive?
      end

      # Starts tracing and the probe's thread.  Returns self.
      def start
        raise 'Dropout probe already started' if @thread

        @started_at = Time.now
        @started_mono = self.class.mono_ns
        @offset = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - @started_mono
        attach_output
        @gc_count = GC.count
        @gc_majors = GC.stat(:major_gc_count)
        @yjit0 = @yjit_last = yjit_ns
        if @options[:system]
          @latency_probe = LatencyProbe.start(dir: latency_dir, ruby: @options[:ticker], flush_every: 86_400)
        end
        FastUI::GVLProbe.log_start(@options[:gvl_threshold], @options[:gc_threshold])
        watch_threads
        @stopping = false
        @thread = Thread.new { monitor }
        @thread.name = 'dropout-probe'
        ExitClose.register(self) # (a console session that quits still writes its log)
        unless @options[:quiet]
          $stdout.puts "Dropout probe: #{@traced ? describe_output : "#{@output.class} has no dropout trace (no underruns to see; render timings only)"}#{@latency_probe ? "; system probe #{@latency_probe.stats[:priority]}" : ''}"
        end
        self
      end

      # Stops the probe, analyzes what is left, and (with +json+) writes the
      # files.  Returns self.
      def stop
        return self unless @thread

        ExitClose.unregister(self)
        @stopping = true
        @thread.join
        @thread = nil
        @stopped_at = Time.now
        poll_once
        @trace_stats = @traced ? @output.trace_stats : nil
        @output.trace_stop if @traced
        FastUI::GVLProbe.log_stop
        @log_stats = FastUI::GVLProbe.log_stats
        FastUI::GVLProbe.stop
        if @latency_probe
          @latency_probe.stop
          @latency_probe.save(formats: %w[svg txt]) if @latency_probe.dir
        end
        @pending.each { |gap, _| record(gap, final: true) }
        @pending.clear
        reanalyze
        save if @options[:json]
        self
      end

      # #finish if still running (ExitClose calls it at exit).
      def close
        finish if @thread
        nil
      end

      # Stops, prints the report, and says where the files are.
      def finish
        stop
        $stdout.puts report
        $stdout.puts "Dropout log: #{paths.values.join(', ')}" if @options[:json]
        self
      end

      # The report text (Report#text).
      def report
        Report.new(self).text
      end

      # Paths written by #save: :json, :csv, :txt (and :latency, the
      # LatencyProbe's directory).
      def paths
        base = @options[:json].to_s.sub(/\.json\z/, '')
        h = { json: "#{base}.json", csv: "#{base}.csv", txt: "#{base}.txt" }
        h[:latency] = latency_dir if @latency_probe&.dir
        h
      end

      # Writes the JSON log, the CSV of dropouts, and the report text.
      def save
        p = paths
        FileUtils.mkdir_p(File.dirname(p[:json]))
        r = Report.new(self)
        File.write(p[:json], JSON.pretty_generate(r.to_h) + "\n")
        File.write(p[:csv], r.csv)
        File.write(p[:txt], r.text + "\n")
        p
      end

      # Run facts for reports: the output, rates, buffer, and options.
      def meta
        out = @output
        state = out.respond_to?(:adapt_state) ? out.adapt_state : {}
        {
          name: @options[:name],
          started: @started_at&.iso8601(3),
          stopped: @stopped_at&.iso8601(3),
          seconds: elapsed.round(3),
          output: out.inspect,
          traced: @traced,
          backend: out.respond_to?(:backend) ? out.backend.to_s : nil,
          device: out.respond_to?(:device_name) ? out.device_name : nil,
          profile: out.respond_to?(:profile) ? out.profile.to_s : nil,
          rate: @rate,
          sample_rate: out.respond_to?(:sample_rate) ? out.sample_rate : nil,
          buffer: @session.buffer_size,
          period: out.respond_to?(:period) ? out.period : nil,
          base_queue_ms: state[:base_queue] && @rate ? (state[:base_queue] * 1000.0 / @rate).round(1) : nil,
          adaptive: state[:adaptive],
          conceal: out.respond_to?(:concealment) ? out.concealment[:mode].to_s : nil,
          gc_quiet: GCQuiet.held?,
          yjit: yjit?,
          ruby: RUBY_DESCRIPTION,
          platform: RUBY_PLATFORM,
          pid: Process.pid,
          host: @latency_probe&.host_info,
          system_probe: @latency_probe && { priority: @latency_probe.stats[:priority].to_s, dir: @latency_probe.dir },
          outputs: @outputs,
          options: @options.except(:on_done, :meta, :marks).transform_values { |v| v.is_a?(Symbol) ? v.to_s : v },
        }.merge(@options[:meta])
      end

      # Seconds since #start (to #stop once stopped).
      def elapsed
        return 0.0 unless @started_at

        (@stopped_at || Time.now) - @started_at
      end

      # Run-wide numbers for Report (see Report#summary).
      def totals
        {
          writes: @counts[:writes],
          underruns: @counts[:underruns],
          idle: @idle,
          hist: @hist,
          gvl_by: @gvl_by,
          gvl_top: @gvl_top.max_by(10, &:first),
          gc_by: @gc_by,
          gc_steps: @counts[:gc_steps],
          gc_ns: @counts[:gc_ns],
          gc_max_ns: @counts[:gc_max_ns],
          gc_collections: GC.count - @gc_count.to_i,
          gc_majors: GC.stat(:major_gc_count) - @gc_majors.to_i,
          yjit_ms: @yjit_last && @yjit0 ? (@yjit_last - @yjit0) / 1e6 : nil,
          queue_changes: @queue_changes,
          trace: @trace_stats || (@traced ? @output.trace_stats : nil),
          log: @log_stats || FastUI::GVLProbe.log_stats,
          probe_cpu_ms: @cpu_ns / 1e6,
          poll_max_ms: @poll_max_ns / 1e6,
          polls: @polls,
          started_mono: @started_mono,
          offset: @offset,
          rate: @rate,
          episodes: @latency_probe ? @latency_probe.episodes.length : nil,
          worst_episode: @latency_probe&.episodes&.max_by { |e| e[:stall_ns] },
        }
      end

      def yjit?
        defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false
      end

      # [monotonic ns, label] from the +marks+ option's #marks.
      def marks
        @options[:marks]&.marks&.dup || []
      end

      private

      def latency_dir
        return nil unless @options[:json]

        "#{@options[:json].to_s.sub(/\.json\z/, '')}-latency"
      end

      def describe_output
        s = meta
        format('%s %s at %d Hz, buffer %d, queue %s ms%s', s[:backend], s[:device].inspect, @rate.to_i, s[:buffer].to_i, s[:base_queue_ms], s[:adaptive] ? ' (adaptive)' : '')
      end

      # Starts the dropout trace on the session's output (again after the
      # Session switched outputs, e.g. live MIDI's :low profile).
      def attach_output
        out = @session.output
        return if out.equal?(@output)

        @output&.trace_stop if @traced
        @output = out
        @outputs += 1
        @traced = out.respond_to?(:trace_start)
        @rate = (out.respond_to?(:device_rate) ? out.device_rate : out.sample_rate).to_f
        @buffer = (@session.buffer_size * @rate / (out.respond_to?(:sample_rate) ? out.sample_rate : @rate)).round
        @prev_write = nil
        @limit = nil
        if @traced
          out.trace_start
          @underruns0 = out.underruns
          @written_before = out.frames_written
        end
      end

      # (Re)watches the threads in WATCH that exist, draining the log first
      # (its records name slots).
      def watch_threads
        found = WATCH.filter_map { |name, find|
          t = find.(@session)
          [name, t] if t&.alive?
        }.uniq { |_, t| t }.first(6)
        return if found.map(&:last) == @slots.map(&:last)

        drain_log unless @slots.empty?
        FastUI::GVLProbe.start(found.map(&:last)) unless found.empty?
        @slots = found
      end

      def monitor
        cpu0 = thread_cpu_ns
        until @stopping
          sleep @options[:poll]
          t = self.class.mono_ns
          poll_once
          took = self.class.mono_ns - t
          @polls += 1
          @poll_max_ns = took if took > @poll_max_ns
          @hist[:poll].add(took)
          if @options[:seconds] && !@done_called && elapsed >= @options[:seconds]
            @done_called = true
            @options[:on_done]&.call
          end
        end
        @cpu_ns += thread_cpu_ns - cpu0
      rescue => e
        warn "Dropout probe stopped: #{e.class}: #{e.message} (at #{e.backtrace&.first})"
      end

      def thread_cpu_ns
        Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :nanosecond)
      rescue Errno::EINVAL, NotImplementedError
        0
      end

      def poll_once
        @lock.synchronize {
          now = self.class.mono_ns
          @offset = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond) - now
          attach_output unless @session.output.equal?(@output)
          drain_trace
          drain_log
          sample(now)
          if now - @last_watch > 1_000_000_000
            @last_watch = now
            watch_threads
          end
          analyze_due(now)
          trim(now)
        }
      end

      def drain_trace
        return unless @traced

        writes, gaps = @output.trace_drain
        writes.each { |w| file_write(w) }
        gaps.each do |g|
          gap = GAP_FIELDS.zip(g).to_h
          @counts[:underruns] += 1
          @pending << [gap, gap[:start] + (@options[:settle] * 1e9).round]
        end
      end

      def file_write(w)
        @counts[:writes] += 1
        @writes << w
        enter, _exit, _wait, room, back, pull, cpu_enter, _cpu_exit, _queued, limit, _frames = w
        # (when the output started playing: before the trace if it had
        # written already)
        @first_write ||= enter - (@written_before / @rate * 1e9).round
        if (p = @prev_write)
          @hist[:render].add(enter - p[1])
          @hist[:render_cpu].add(cpu_enter - p[7]) if cpu_enter >= 0 && p[7] >= 0
        end
        if room > 0
          @hist[:wake].add(room - pull) if pull > 0 && room >= pull
          @hist[:gvl_back].add(back - room)
        end
        if @limit && limit != @limit
          @queue_changes << [enter, @limit, limit]
        end
        @limit_history << [enter, limit] if @limit != limit
        @limit = limit
        @prev_write = w
        @last_write = enter
      end

      def drain_log
        names = @slots.map(&:first)
        FastUI::GVLProbe.log_drain.each do |kind, slot, holder, a, b, c, gc_count|
          thread = slot >= 0 ? names[slot] : nil
          if kind == :gc
            @counts[:gc_steps] += 1
            @counts[:gc_ns] += b - a
            @counts[:gc_max_ns] = [@counts[:gc_max_ns], b - a].max
            @gc_by[thread || 'another thread'] += b - a
            @gc << { thread: thread, a: a, b: b, count: gc_count }
          else
            h = holder >= 0 ? names[holder] : nil
            @threads << { thread: thread, holder: h, a: a, b: b, c: c }
            if thread == 'render' && c - b >= 1_000_000
              @hist[:gvl_wait].add(c - b)
              @gvl_by[h || 'another thread'] += c - b
              @gvl_top << [c - b, b, h || 'another thread']
              @gvl_top = @gvl_top.max_by(10, &:first) if @gvl_top.length > 20
            end
          end
        end
      end

      def sample(now)
        count = GC.count
        majors = GC.stat(:major_gc_count)
        prev = @gc_majors_seen || @gc_majors.to_i
        if majors > prev
          # The collections since the last poll that were majors
          # (GC.latest_gc_info names the latest; the rest are taken from the
          # earliest, a guess only when one poll saw several collections)
          n = majors - prev
          newest = GC.latest_gc_info(:major_by) ? [count] : []
          rest = (((@gc_count_seen || @gc_count.to_i) + 1)..count).to_a - newest
          (newest + rest.first(n - newest.length)).each { |c| @major_counts[c] = true }
        end
        @gc_count_seen = count
        @gc_majors_seen = majors
        y = yjit_ns
        @yjit_last = y if y
        state = @output.respond_to?(:adapt_state) ? @output.adapt_state : {}
        @samples << { mono: now, yjit_ns: y, gc_count: count, majors: majors, limit: state[:queue_limit], shrink_wait: state[:shrink_wait], last_adapt: state[:last_adapt], load: @session.render_load }
      end

      def yjit_ns
        return nil unless yjit?

        RubyVM::YJIT.runtime_stats(:compile_time_ns)
      rescue ArgumentError, TypeError
        RubyVM::YJIT.runtime_stats[:compile_time_ns]
      end

      def analyze_due(now)
        due = @pending.select { |_, at| at <= now }
        return if due.empty?

        @pending -= due
        due.each { |gap, _| record(gap) }
      end

      # Files a dropout with its context, classified (or an idle gap).
      def record(gap, final: false)
        ctx = context(gap, final: final)
        result = Analysis.classify(ctx)
        if result[:cause] == :idle
          @idle += 1
          return
        end
        return if @dropouts.length >= @options[:max_dropouts]

        d = { n: @dropouts.length + 1, gap: gap, ctx: ctx, result: result }
        @dropouts << d
        $stdout.puts(Report.live_line(d, self)) unless @options[:quiet]
      end

      # Classifies every dropout again with what the LatencyProbe filed by
      # now (episodes close and are drained up to a few seconds late).
      def reanalyze
        eps = episodes
        @dropouts.each do |d|
          d[:ctx][:episodes] = eps
          d[:ctx][:ended] = d[:ctx][:writes].none? { |w| w[:enter] > d[:gap][:start] } && @last_write.to_i <= d[:gap][:start]
          d[:result] = Analysis.classify(d[:ctx])
        end
        idle, @dropouts = @dropouts.partition { |d| d[:result][:cause] == :idle }
        @idle += idle.length
        @dropouts.each_with_index { |d, i| d[:n] = i + 1 }
      end

      def context(gap, final:)
        t = gap[:start]
        window = ((gap[:limit].to_i + @buffer.to_i) / @rate * 1e9).round
        lo = t - window - 300_000_000
        hi = t + 1_500_000_000
        writes = @writes.select { |w| w[1] >= lo && w[0] <= hi }.map { |w| WRITE_FIELDS.zip(w).to_h }
        after = writes.index { |w| w[:enter] > t }
        writes = writes[0..(after + 2)] if after
        limit_before = @limit_history.select { |at, _| at < t && at >= t - Analysis::SHRINK_RECENT * 1e9 }.map(&:last)
        held = @limit_history.reverse_each.find { |at, _| at < t - Analysis::SHRINK_RECENT * 1e9 }
        limit_before << held[1] if held
        {
          gap: gap,
          writes: writes,
          threads: @threads.select { |e| e[:c] >= lo && (e[:a].to_i > 0 ? e[:a] : e[:b]) <= hi },
          gc: @gc.select { |g| g[:b] >= lo && g[:a] <= hi }.map { |g| g.merge(major: !!@major_counts[g[:count]]) },
          samples: @samples.select { |s| s[:mono] >= lo - 200_000_000 && s[:mono] <= hi + 200_000_000 },
          episodes: episodes,
          rate: @rate,
          buffer: @buffer,
          first_write: @first_write,
          limit_before: limit_before.max,
          ended: final && writes.none? { |w| w[:enter] > t },
          render: 'render',
          startup: @options[:startup],
          wall_offset: @offset,
        }
      end

      # The LatencyProbe's episodes, in this probe's clock (ns).
      def episodes
        return [] unless @latency_probe

        @latency_probe.episodes.last(500).map { |e|
          { start: e[:wall_ns] - @offset, duration: e[:duration_ns], stall: e[:stall_ns], worst: e[:worst_wall_ns].to_i - @offset }
        }
      end

      def trim(now)
        keep = (@options[:keep] * 1e9).round
        cut = now - keep
        @writes.shift while @writes.first && @writes.first[1] < cut
        @threads.shift while @threads.first && @threads.first[:c] < cut
        @gc.shift while @gc.first && @gc.first[:b] < cut
        @samples.shift while @samples.first && @samples.first[:mono] < cut
        # (one limit before the cut stays: limit_before reads it)
        @limit_history.shift while @limit_history.length > 1 && @limit_history[1][0] < cut - (Analysis::SHRINK_RECENT * 1e9)
        @major_counts.delete_if { |c, _| c < @gc_count_seen.to_i - 1000 }
      end
    end
  end
end
