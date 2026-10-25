require 'json'
require 'fileutils'
require 'etc'
require 'socket'
require 'time'

require_relative 'fast_latency'
require_relative 'latency_probe/histogram'
require_relative 'latency_probe/periodicity'
require_relative 'latency_probe/system'
require_relative 'latency_probe/ticker'
require_relative 'latency_probe/report'
require_relative 'latency_probe/saved'

module MB
  module Sound
    # A system latency detector meant to run for hours (latency-probe-1,
    # 2026-10-25; design/notes/latency_probe.md).
    #
    # Three series on one wall-clock timeline:
    # - the probe (FastLatency::Probe): a C thread outside the GVL waking on
    #   an absolute-deadline loop (default every 1 ms), timing a little
    #   memory-touching and CPU-only work each tick; it sees only the system
    #   (the OS, the VM, other processes);
    # - the Ruby ticker (Ticker): a Ruby thread on the same kind of loop
    #   (default every 2 ms), which also waits for the GVL, GC, and YJIT;
    # - optionally a Session's buffers, slow renders, and underruns
    #   (#watch), so audio dropouts line up with what caused them.
    # Plus per-second GC and YJIT deltas and System readings (free memory,
    # load, CPU busy/steal, PSI).
    #
    #     probe = MB::Sound::LatencyProbe.start(dir: 'tmp/latency')
    #     probe.watch(session)          # optional
    #     ...
    #     probe.stop
    #     puts probe.report
    #     probe.save                    # report, plots, CSV, JSON in +dir+
    #
    # A consumer Ruby thread waits in C without the GVL for the probe's
    # records and drains them into per-second rows and event lists; with
    # +dir+ it appends rows and events to CSV files every few seconds, so a
    # crash keeps the data.  Memory is bounded: per-second rows for the last
    # +keep_seconds+ (24 hours by default), capped event lists, and lifetime
    # histograms.
    class LatencyProbe
      # Per-second columns, in CSV order (times in milliseconds).
      COLUMNS = (%i[
        second ticks missed over events dropped
        late_max_ms late_p50_ms late_p99_ms mem_max_ms mem_p50_ms mem_p99_ms cpu_max_ms cpu_p50_ms cpu_p99_ms
        stall_max_ms thread_cpu_ms nivcsw migrations cpu
        r_ticks r_missed r_over r_late_max_ms r_late_p99_ms
        gc_count gc_major gc_ms yjit_ms
        s_buffers s_render_max_ms s_gap_max_ms s_underruns s_slow
      ] + System::COLUMNS).freeze
      COLUMN_INDEX = COLUMNS.each_with_index.to_h.freeze

      EVENT_COLUMNS = %w[source kind wall time stall_ms late_ms mem_ms cpu_ms duration_ms ticks over missed worst_wall cpu mem_thread_cpu_ms detail].freeze

      DEFAULTS = {
        period: 0.001,
        threshold: 0.002,
        work: %i[memory cpu],
        memory: 64 * 1024 * 1024,
        memory_touch: 128 * 1024,
        cpu_iterations: 10_000,
        work_ratio: 5.0,
        work_min: 0.00025,
        gap: 0.1,
        events_per_second: 100,
        ring: 4096,
        boost: true,
        rt_priority: 10,
        nice: -10,
        pin_cpu: nil,
        mlock: false,
        ruby: true,
        ruby_period: 0.002,
        system: true,
        dir: nil,
        flush_every: 10,
        keep_seconds: 86_400,
        max_events: 100_000,
      }.freeze

      # Starts a probe (see #initialize for the options).
      def self.start(**opts)
        new(**opts).start
      end

      # A saved run (the files #save and the flushes write) for reports and
      # plots after the fact, e.g. after a crash (Saved).
      def self.load(dir)
        Saved.new(dir)
      end

      # The directory for a run named +name+ under tmp/latency_probe/ in
      # the current directory, stamped with the local time.
      def self.default_dir(name = 'probe')
        File.join('tmp', 'latency_probe', "#{name}-#{Time.now.strftime('%Y%m%d-%H%M%S')}")
      end

      # When MB_SOUND_LATENCY_PROBE is set (a directory, or 1 for
      # .default_dir(+name+)), starts a probe watching +session+ and
      # returns it (call #finish at the end); else nil.  How ScriptRunner
      # probes any live script.
      def self.from_env(session = nil, name: 'probe', env: ENV)
        v = env['MB_SOUND_LATENCY_PROBE'].to_s
        return nil if v.empty? || v == '0'

        dir = v == '1' ? default_dir(name) : v
        probe = start(dir: dir)
        probe.watch(session) if session
        $stderr.puts "Latency probe running (#{probe.stats[:priority]}); report in #{dir}"
        probe
      end

      attr_reader :options, :dir, :episodes, :ruby_events, :session_events, :ticks, :top, :started_at, :stopped_at

      # Options (times in seconds, sizes in bytes):
      # +period+ (0.001) the probe's tick; +threshold+ (0.002) the stall
      # that makes an event; +work+ (%i[memory cpu]; [] or nil for wake
      # lateness only); +memory+ (64 MiB, larger than the caches) the memory
      # probe's buffer, +memory_touch+ (128 KiB) the part walked each tick;
      # +cpu_iterations+ (10000) the CPU probe's loop; work counts as a
      # stall when over +work_ratio+ (5) times its baseline (the median of
      # the first FastLatency::CALIBRATION_TICKS ticks) and +work_min+
      # (0.25 ms) longer, or over the threshold longer; +gap+ (0.1) merges
      # stalls into episodes; +events_per_second+ (100) caps tick events;
      # +ring+ (4096 records); +boost+ (true) raises the probe thread's
      # priority where allowed (macOS time constraint policy; Linux
      # SCHED_FIFO +rt_priority+ (10), else +nice+ (-10)); +pin_cpu+;
      # +mlock+; +ruby+ (true) runs the Ruby ticker every +ruby_period+
      # (0.002); +system+ (true) samples System once a second; +dir+ writes
      # CSV files there every +flush_every+ (10) seconds; +keep_seconds+
      # (86400) rows in memory; +max_events+ (100000) per event list.
      def initialize(**opts)
        unknown = opts.keys - DEFAULTS.keys
        raise ArgumentError, "Unknown latency probe options: #{unknown.join(', ')} (known: #{DEFAULTS.keys.join(', ')})" unless unknown.empty?

        @options = DEFAULTS.merge(opts)
        @options[:work] = Array(@options[:work]).map(&:to_sym)
        bad = @options[:work] - %i[memory cpu]
        raise ArgumentError, "Unknown work probes: #{bad.join(', ')} (:memory, :cpu)" unless bad.empty?

        @dir = @options[:dir]
        @probe = FastLatency::Probe.new(probe_options)
        @ticker = @options[:ruby] ? Ticker.new(period: @options[:ruby_period], threshold: @options[:threshold], events_per_second: @options[:events_per_second]) : nil
        @system = @options[:system] ? System.new : nil
        @watch = nil

        @lock = Mutex.new
        @pending = {}
        @rows = []
        @last_row_second = nil
        @episodes = []
        @ruby_events = []
        @session_events = []
        @ticks = []
        @top = []
        @counts = Hash.new(0)
        @session_hist = Histogram.new

        @consumer = nil
        @stopping = false
        @started_at = nil
        @stopped_at = nil
        @last_flush = nil
        @unflushed_rows = []
        @unflushed_events = []
        @files_started = false
        @last_sample_second = nil
        @gc_last = nil
        @yjit_last = nil
        @final_stats = nil
      end

      # Starts the probe thread, the Ruby ticker, and the consumer.
      def start
        raise 'Latency probe already started' if @consumer

        @started_at = Time.now
        @gc_last = gc_snapshot
        @yjit_last = yjit_compile_ns
        @system&.sample # primes the deltas
        @last_sample_second = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
        @probe.start
        @ticker&.start
        @stopping = false
        @consumer = Thread.new { consume }
        @consumer.name = 'latency-consumer'
        start_files if @dir
        self
      end

      def running?
        !!@consumer&.alive?
      end

      # Logs +session+'s buffers, slow renders, and underruns (SessionWatch)
      # until #unwatch or #stop.  Returns self.
      def watch(session, slow: 0.8)
        unwatch
        @watch = SessionWatch.new(session, threshold: @options[:threshold], slow: slow).start
        self
      end

      # The SessionWatch while a Session is watched, else nil.
      def session_watch
        @watch
      end

      def unwatch
        @watch&.stop
        @watch = nil
        self
      end

      # Stops everything, collects the last records, and (with +dir+)
      # flushes the files.  Returns self.
      def stop
        return self unless @consumer

        @watch&.stop
        @ticker&.stop
        @probe.stop
        @stopping = true
        @consumer.join
        @consumer = nil
        @stopped_at = Time.now
        ingest
        sample_second(final: true)
        finalize_rows(all: true)
        @final_stats = @probe.stats
        flush if @dir
        self
      end

      # The probe thread's lifetime counters (FastLatency::Probe#stats).
      def stats
        @final_stats || @probe.stats
      end

      # Lifetime histograms (Histogram): +kind+ :late, :memory, :cpu, :stall
      # (the probe), :ruby (the ticker's lateness), :session (render times).
      def histogram(kind = :stall)
        case kind
        when :ruby then @ticker ? @ticker.histogram : Histogram.new
        when :session then @session_hist
        when :late then Histogram.new(@probe.histogram(kind), max: stats[:max_late_ns])
        when :stall then Histogram.new(@probe.histogram(kind), max: stats[:max_stall_ns])
        else Histogram.new(@probe.histogram(kind))
        end
      end

      # Per-second rows as Hashes (finished seconds, oldest first, at most
      # +keep_seconds+).
      def seconds
        @lock.synchronize { @rows.map { |r| COLUMNS.zip(r).to_h } }
      end

      # Per-second rows as Arrays in COLUMNS order.
      def rows
        @lock.synchronize { @rows.dup }
      end

      # All events, oldest first: probe episodes (source :probe), Ruby
      # ticker stalls (:ruby), and session events (:session).
      def events
        @lock.synchronize { (@episodes + @ruby_events + @session_events) }.sort_by { |e| e[:wall_ns] }
      end

      # A Hash of the run so far: counters, percentiles, and the latest
      # finished second.
      def snapshot
        s = stats
        h = histogram(:stall)
        r = @ticker&.histogram
        last = @lock.synchronize { @rows.last }
        {
          running: running?,
          seconds: elapsed,
          ticks: s[:ticks],
          missed: s[:missed],
          overflow: s[:overflow],
          episodes: s[:episodes],
          max_stall_ms: s[:max_stall_ns] / 1e6,
          stall_p99_ms: h.percentile(0.99) / 1e6,
          ruby_max_ms: r&.max_ns.to_f / 1e6,
          ruby_events: @counts[:ruby],
          session_events: @counts[:session],
          underruns: @counts[:underrun],
          gc_count: @counts[:gc_count],
          gc_ms: @counts[:gc_ms],
          last: last && COLUMNS.zip(last).to_h,
          priority: s[:priority],
        }
      end

      # Seconds since #start (to #stop if stopped).
      def elapsed
        return 0.0 unless @started_at

        (@stopped_at || Time.now) - @started_at
      end

      # One line for a live status display.
      def status_line
        s = snapshot
        last = s[:last] || {}
        worst = @lock.synchronize { @episodes.max_by { |e| e[:stall_ns] } }
        worst_text = worst ? format(' (worst %.1f ms at %s)', worst[:stall_ns] / 1e6, Report.clock(worst[:worst_wall_ns])) : ''
        format('%s %s | probe max %.2f ms p99 %.2f | ruby max %.1f ms | episodes %d%s | ruby stalls %d | gc %d (%.0f ms)%s | load %s mem %s | overflow %d',
          Time.now.strftime('%H:%M:%S'), Report.duration(s[:seconds]),
          last[:stall_max_ms].to_f, last[:late_p99_ms].to_f, last[:r_late_max_ms].to_f,
          s[:episodes], worst_text, s[:ruby_events], s[:gc_count], s[:gc_ms],
          @watch ? format(' | underruns %d', s[:underruns]) : '',
          last[:load1] ? format('%.2f', last[:load1]) : '-',
          last[:mem_available_mb] ? format('%.0fM', last[:mem_available_mb]) : '-',
          s[:overflow])
      end

      # The text summary (Report#text).
      def report
        Report.new(self).text
      end

      # Writes the report, plots (SVG, PNG, text), per-second CSV, events
      # CSV, and histograms JSON into +dir+ (default the probe's +dir+).
      # Plots go in +formats+ (svg, png, txt).  Returns the Hash of written
      # paths.
      def save(dir = @dir, formats: %w[svg png txt])
        raise ArgumentError, 'Pass a directory to save the latency report in' unless dir

        FileUtils.mkdir_p(dir)
        if dir != @dir || !@files_started
          write_csv(File.join(dir, 'seconds.csv'), COLUMNS.map(&:to_s), rows)
          write_csv(File.join(dir, 'events.csv'), EVENT_COLUMNS, events.map { |e| event_row(e) })
        end
        write_meta(dir)
        Report.new(self).save(dir, formats: formats)
      end

      # Stops, saves the report and plots (SVG and text: PNGs take a few
      # seconds) in +dir+, and prints where.
      def finish(formats: %w[svg txt])
        stop
        paths = save(formats: formats)
        $stderr.puts "Latency report: #{paths[:report]}"
        paths
      end

      # Run information saved in meta.json.
      def meta
        s = stats
        {
          started: @started_at&.iso8601(3),
          stopped: @stopped_at&.iso8601(3),
          seconds: elapsed.round(3),
          host: host_info,
          options: @options.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v },
          probe: s.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v },
          wake_clock: FastLatency::WAKE_CLOCK,
          psi: @system&.psi? || false,
          ruby: RUBY_DESCRIPTION,
          yjit: yjit?,
          pid: Process.pid,
        }
      end

      def host_info
        info = { platform: RUBY_PLATFORM }
        if File.readable?('/proc/cpuinfo')
          info[:cpu_model] = File.foreach('/proc/cpuinfo').find { |l| l.start_with?('model name') }&.split(':', 2)&.last&.strip
        end
        info[:cpus] = Etc.nprocessors if defined?(Etc)
        info[:hostname] = Socket.gethostname if defined?(Socket)
        info
      rescue SystemCallError
        info
      end

      def yjit?
        defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false
      end

      private

      def probe_options
        o = @options
        work = o[:work]
        {
          period_ns: (o[:period] * 1e9).round,
          threshold_ns: (o[:threshold] * 1e9).round,
          gap_ns: (o[:gap] * 1e9).round,
          work_ratio: o[:work_ratio].to_f,
          work_min_ns: (o[:work_min] * 1e9).round,
          memory_bytes: work.include?(:memory) ? o[:memory].to_i : 0,
          memory_touch: o[:memory_touch].to_i,
          cpu_iterations: work.include?(:cpu) ? o[:cpu_iterations].to_i : 0,
          events_per_second: o[:events_per_second],
          ring: o[:ring],
          boost: o[:boost],
          rt_priority: o[:rt_priority],
          nice: o[:nice],
          pin_cpu: o[:pin_cpu],
          mlock: o[:mlock],
        }
      end

      # The consumer thread: waits (without the GVL) for the probe's
      # records, then files them with the ticker's and session's, samples
      # GC/YJIT/System once a wall second, and flushes files.
      def consume
        until @stopping
          @probe.wait(0.25)
          ingest
          sample_second
          finalize_rows
          flush if @dir && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_flush >= @options[:flush_every]
        end
      rescue => e
        warn "Latency probe consumer stopped: #{e.class}: #{e.message}"
      end

      def ingest
        recs = @probe.drain
        recs.concat(@ticker.drain) if @ticker
        recs.concat(@watch.drain) if @watch
        return if recs.empty?

        @lock.synchronize { recs.each { |r| file(r) } }
      end

      # Files one record (with the lock held).
      def file(r)
        case r[:kind]
        when :second
          row = pending_row(r[:second])
          row.merge!(
            ticks: r[:ticks], missed: r[:missed], over: r[:over], events: r[:events], dropped: r[:dropped],
            late_max_ms: ms(r[:late_max_ns]), late_p50_ms: ms(r[:late_p50_ns]), late_p99_ms: ms(r[:late_p99_ns]),
            mem_max_ms: ms(r[:mem_max_ns]), mem_p50_ms: ms(r[:mem_p50_ns]), mem_p99_ms: ms(r[:mem_p99_ns]),
            cpu_max_ms: ms(r[:cpu_max_ns]), cpu_p50_ms: ms(r[:cpu_p50_ns]), cpu_p99_ms: ms(r[:cpu_p99_ns]),
            stall_max_ms: ms(r[:stall_max_ns]), thread_cpu_ms: r[:thread_cpu_ns] >= 0 ? ms(r[:thread_cpu_ns]) : nil,
            nivcsw: r[:nivcsw] >= 0 ? r[:nivcsw] : nil, migrations: r[:migrations], cpu: r[:cpu] >= 0 ? r[:cpu] : nil,
          )

        when :episode
          e = r.merge(source: :probe)
          keep(@episodes, e)
          keep_top(e)
          @counts[:episodes] += 1
          @unflushed_events << e

        when :tick
          e = r.merge(source: :probe)
          @ticks << e
          @ticks.shift if @ticks.length > 10_000
          @unflushed_events << e

        when :ruby_second
          row = pending_row(r[:second])
          row.merge!(r_ticks: r[:ticks], r_missed: r[:missed], r_over: r[:over], r_late_max_ms: ms(r[:late_max_ns]), r_late_p99_ms: ms(r[:late_p99_ns]))

        when :ruby_tick
          e = r.merge(source: :ruby, stall_ns: r[:late_ns])
          keep(@ruby_events, e)
          @counts[:ruby] += 1
          @unflushed_events << e

        when :session_second
          row = pending_row(r[:second])
          row.merge!(s_buffers: r[:buffers], s_render_max_ms: ms(r[:render_max_ns]), s_gap_max_ms: ms(r[:gap_max_ns]), s_underruns: r[:underruns], s_slow: r[:slow])
          @session_hist.add(r[:render_max_ns])

        when :session_slow, :session_gap, :underrun
          e = r.merge(source: :session, stall_ns: r[:render_ns] || r[:gap_ns] || 0)
          keep(@session_events, e)
          @counts[:session] += 1
          @counts[:underrun] += r[:count] if r[:kind] == :underrun
          @unflushed_events << e
        end
      end

      def keep(list, e)
        list << e
        list.shift if list.length > @options[:max_events]
      end

      def keep_top(e)
        @top << e
        return if @top.length <= 100

        @top.sort_by! { |x| -x[:stall_ns] }
        @top.pop(@top.length - 50)
      end

      def pending_row(sec)
        @pending[sec] ||= { second: sec }
      end

      # GC, YJIT, and System readings for the second that just ended.
      # (+final+: the partial second at #stop, counted in the current second)
      def sample_second(final: false)
        sec = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
        return if sec == @last_sample_second && !final

        sec += 1 if final

        @last_sample_second = sec
        gc = gc_snapshot
        d = gc.zip(@gc_last).map { |a, b| a - b }
        @gc_last = gc
        y = yjit_compile_ns
        yd = y && @yjit_last ? y - @yjit_last : nil
        @yjit_last = y
        sys = @system ? @system.sample : {}

        @lock.synchronize {
          row = pending_row(sec - 1)
          row[:gc_count] = d[0]
          row[:gc_major] = d[1]
          row[:gc_ms] = d[2]
          row[:yjit_ms] = yd && yd / 1e6
          row.merge!(sys)
          @counts[:gc_count] += d[0]
          @counts[:gc_ms] += d[2]
        }
      end

      def gc_snapshot
        s = GC.stat
        [s[:count], s[:major_gc_count], s[:time] || 0]
      end

      def yjit_compile_ns
        return nil unless yjit?

        RubyVM::YJIT.runtime_stats(:compile_time_ns)
      rescue ArgumentError, TypeError
        RubyVM::YJIT.runtime_stats[:compile_time_ns]
      end

      # Moves rows at least 3 seconds old (every series has reported) out
      # of the pending Hash, filling seconds the probe never reported (a
      # stall longer than a second) with zero ticks.
      def finalize_rows(all: false)
        now = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
        @lock.synchronize {
          done = @pending.keys.select { |s| all || s < now - 3 }.sort
          done.each do |s|
            if @last_row_second && s > @last_row_second + 1 && s - @last_row_second < 3600
              ((@last_row_second + 1)...s).each { |gap| push_row(second: gap, ticks: 0) }
            end
            next if @last_row_second && s <= @last_row_second

            push_row(@pending.delete(s))
          end
          done.each { |s| @pending.delete(s) }
        }
      end

      def push_row(h)
        row = COLUMNS.map { |c| h[c] }
        row[COLUMN_INDEX[:ticks]] ||= 0
        @rows << row
        @rows.shift if @rows.length > @options[:keep_seconds]
        @unflushed_rows << row
        @last_row_second = h[:second]
      end

      def ms(ns)
        ns && ns / 1e6
      end

      def start_files
        FileUtils.mkdir_p(@dir)
        File.write(File.join(@dir, 'seconds.csv'), COLUMNS.join(',') + "\n")
        File.write(File.join(@dir, 'events.csv'), EVENT_COLUMNS.join(',') + "\n")
        @files_started = true
        @last_flush = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        write_meta(@dir)
      end

      # Appends the rows and events filed since the last flush, and rewrites
      # the histograms.
      def flush
        rows, evs = @lock.synchronize {
          r = @unflushed_rows
          e = @unflushed_events
          @unflushed_rows = []
          @unflushed_events = []
          [r, e]
        }
        File.open(File.join(@dir, 'seconds.csv'), 'a') { |f| rows.each { |r| f.puts(csv_line(r)) } } unless rows.empty?
        File.open(File.join(@dir, 'events.csv'), 'a') { |f| evs.each { |e| f.puts(csv_line(event_row(e))) } } unless evs.empty?
        write_histograms(@dir)
        write_meta(@dir) if @stopped_at
        @last_flush = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def write_meta(dir)
        File.write(File.join(dir, 'meta.json'), JSON.pretty_generate(meta) + "\n")
      end

      def write_histograms(dir)
        hists = %i[late memory cpu stall ruby session].to_h { |k| [k, histogram(k)] }
        h = hists.transform_values(&:to_pairs)
        h[:max] = hists.transform_values(&:max).compact
        File.write(File.join(dir, 'histograms.json'), JSON.generate(h) + "\n")
      end

      def write_csv(path, header, rows)
        File.open(path, 'w') do |f|
          f.puts(header.join(','))
          rows.each { |r| f.puts(csv_line(r)) }
        end
      end

      def csv_line(values)
        values.map { |v|
          case v
          when nil then ''
          when Float then v.round(4).to_s
          when String then v.include?(',') || v.include?('"') ? "\"#{v.gsub('"', '""')}\"" : v
          else v.to_s
          end
        }.join(',')
      end

      def event_row(e)
        wall = e[:wall_ns] / 1e9
        detail =
          case e[:kind]
          when :session_slow then format('render_ms %.3f buffer_ms %.3f', e[:render_ns] / 1e6, e[:buffer_ns] / 1e6)
          when :session_gap then format('gap_ms %.3f buffer_ms %.3f', e[:gap_ns] / 1e6, e[:buffer_ns] / 1e6)
          when :underrun then "count #{e[:count]}"
          end
        [
          e[:source], e[:kind], wall.round(6), Report.clock(e[:wall_ns], date: true),
          ms(e[:stall_ns]), ms(e[:late_ns]), ms(e[:mem_ns]), ms(e[:cpu_ns]), ms(e[:duration_ns]), e[:ticks],
          e[:over], e[:missed], e[:worst_wall_ns] && (e[:worst_wall_ns] / 1e9).round(6), e[:cpu], ms(e[:mem_thread_cpu_ns]), detail,
        ]
      end
    end
  end
end
