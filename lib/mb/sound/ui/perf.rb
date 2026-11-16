require 'json'
require 'etc'

module MB
  module Sound
    module UI
      # Frame instruments for the screens (ui-perf-1, 2026-11-15; the
      # maintainer: "UI lag or dropped frames ... even if the listed fps and
      # target fps are high").  `ui.fps` counts frames the painter wrote;
      # this measures what lies between a written frame and a smooth
      # screen: how late each frame started against its deadline, paint
      # and write times (a write blocks while the terminal drains), bytes,
      # full redraws, GC during frames, the longest gap between written
      # frames, each pane's update age (the time between its redraws: how
      # stale its picture gets), key-to-frame latency (a key's arrival to
      # the write of the first frame drawn after its handler ran; for REPL
      # keys, the first frame that redrew the REPL after it), and an
      # end-to-end acknowledgement: after a sampled frame a query (DA1,
      # `ESC [ c`, or DSR, `ESC [ 6 n`) whose answer the terminal sends only
      # after parsing every byte before it, so the answer's time bounds the
      # terminal's parse time.  It does not prove the frame reached the
      # glass: a terminal parses into its model and paints later on its own
      # clock (Konsole, iTerm2, and VTE batch paints at their refresh), so
      # an answer is a lower bound on what is seen.
      #
      # Opt-in: a screen holds a Perf only while `ui.perf` runs (nil
      # otherwise, so the hooks cost one ivar test).  Records go into
      # preallocated rings (Floats are immediates; no allocation per frame).
      #
      #     ui.perf              # start (or the report, when running)
      #     ui.perf :report      # the page: percentiles, worst stall, panes, keys, acks, audio
      #     ui.perf :save        # report.txt + perf.json under tmp/ui-perf/captures/
      #     ui.perf :stop
      #     ui.perf :capture     # one minute of scenarios, saved, three lines printed
      class Perf
        # Frames kept (about 4.5 minutes at 60/s).
        RING = 16_384

        # Draws kept per pane, keys, and acks.
        PANE_RING = 4096
        KEY_RING = 2048
        ACK_RING = 2048

        # Seconds between acknowledgement queries, and how long one may stay
        # unanswered before it counts as lost (and another may go).
        ACK_EVERY = 0.25
        ACK_TIMEOUT = 2.0

        # Seconds a key waits for a frame that shows it (else "no change").
        KEY_TIMEOUT = 1.0

        # A pane age (seconds between redraws) counted as stale.
        STALE = 0.1

        # Queries by kind.
        ACK_QUERIES = { da1: "\e[c", dsr: "\e[6n" }.freeze

        # Per-frame fields, each a preallocated Array of RING values.
        FIELDS = %i[at late paint write bytes panes repl full gc_ms gc_runs skipped].freeze

        attr_reader :started_at, :stopped_at, :count, :ack_kind, :identity, :pending_keys

        # Where captures and saves go (tmp/ui-perf/captures in the main
        # checkout, $MB_SOUND_CHECKOUT_TMP, or the user data directory).
        def self.captures_dir
          base = Internal.checkout_tmp_dir
          return File.join(base, 'ui-perf', 'captures') if base
          File.join(File.dirname(Internal.help_data_dir), 'ui-perf', 'captures')
        end

        # +clock+ the screen's clock (seconds); +ack+ :da1, :dsr, or nil
        # (no queries: a band, whose input Reline owns, or a terminal that
        # doesn't answer); +ring+ frames kept.
        def initialize(clock: -> { MB::U.clock_now }, ack: :da1, ack_every: ACK_EVERY, ring: RING, label: nil)
          raise ArgumentError, "ack is :da1, :dsr, or nil (got #{ack.inspect})" unless ack.nil? || ACK_QUERIES.key?(ack)
          @clock = clock
          @ack_kind = ack
          @ack_every = ack_every
          @ring = ring
          @label = label
          @cols = FIELDS.to_h { |f| [f, Array.new(ring, 0.0)] }
          @count = 0
          @started_at = @clock.call
          @stopped_at = nil
          @frame_start = 0.0
          @begun = false
          @gc_count0 = 0
          @gc_time0 = 0
          @frame_bytes = 0
          @frame_panes = 0
          @frame_repl = false
          @frame_full = false
          @write_start = nil
          @write_end = nil
          @last_written = nil
          @gap_max = 0.0
          @gap_at = 0.0
          @start_gap_max = 0.0
          @start_gap_at = 0.0
          @last_start = nil
          @panes = {} # name => [ring of gaps, count, last draw]
          @key_lock = Mutex.new
          @keys_arrival = Array.new(KEY_RING, 0.0)
          @keys_handled = Array.new(KEY_RING, 0.0)
          @keys_repl = Array.new(KEY_RING, false)
          @key_head = 0 # (oldest pending)
          @key_tail = 0 # (next free)
          @key_lat = Array.new(KEY_RING, 0.0)
          @key_lat_count = 0
          @key_unseen = 0
          @ack_sent = nil
          @ack_wrote = nil
          @ack_from_start = Array.new(ACK_RING, 0.0)
          @ack_from_end = Array.new(ACK_RING, 0.0)
          @ack_count = 0
          @ack_queries = 0
          @ack_lost = 0
          @ack_due = @started_at
          @identity = {}
          @replies = {}
          @probe = nil
          @pending_query = nil
          @probe_started = false
          @audio = nil
        end

        def running? = @stopped_at.nil?

        # Ends recording (the rings stay for the report).
        def stop
          @stopped_at ||= @clock.call
          stop_probe
          self
        end

        ### The painter's hooks (UI::Pacer#frame, the screen's refresh)

        # A frame starts at +start+ (the Pacer, before the refresh).
        def begin_frame(start)
          @begun = true
          @frame_start = start
          @gc_count0 = GC.count
          @gc_time0 = GC.stat(:time)
          @frame_bytes = 0
          @frame_panes = 0
          @frame_repl = false
          @frame_full = false
          @write_start = @write_end = nil
          if @last_start
            g = start - @last_start
            if g > @start_gap_max
              @start_gap_max = g
              @start_gap_at = start
            end
          end
          @last_start = start
        end

        # What the refresh drew: +panes+ drawn, whether it redrew the REPL,
        # whether it was a full redraw, and the bytes it wrote (0: none).
        def painted(panes, repl, full, bytes)
          @frame_panes = panes
          @frame_repl = repl
          @frame_full = full
          @frame_bytes = bytes
        end

        # The screen wrote a frame between +t0+ and +t1+ (FrameRate#timed_write).
        def wrote(t0, t1)
          @write_start ||= t0
          @write_end = t1
          if @ack_sent == :pending
            @ack_sent = t0
            @ack_wrote = t1
          end
          if @last_written
            g = t1 - @last_written
            if g > @gap_max
              @gap_max = g
              @gap_at = t1
            end
          end
          @last_written = t1
          match_keys(t1)
        end

        # The frame (a UI::Pacer::Frame) ended: one record.
        def end_frame(f)
          return unless running? && @begun # (a frame already painting when recording started)
          i = @count % @ring
          c = @cols
          c[:at][i] = f.at - @started_at
          c[:late][i] = f.late
          c[:paint][i] = f.paint
          c[:write][i] = f.write
          c[:bytes][i] = @frame_bytes
          c[:panes][i] = @frame_panes
          c[:repl][i] = @frame_repl ? 1 : 0
          c[:full][i] = @frame_full ? 1 : 0
          c[:gc_runs][i] = GC.count - @gc_count0
          c[:gc_ms][i] = GC.stat(:time) - @gc_time0
          c[:skipped][i] = f.skipped
          @count += 1
        end

        # A pane drew at +now+, its previous draw at +prev+ (nil: first).
        def pane_drew(name, now, prev)
          return unless running?
          e = @panes[name] || (@panes[name] = [Array.new(PANE_RING, 0.0), 0, nil])
          if prev
            ring = e[0]
            ring[e[1] % PANE_RING] = now - prev
            e[1] += 1
          end
          e[2] = now
        end

        # The query to send after this frame (a frozen String), or nil: one
        # every +ack_every+ seconds while none is unanswered.
        def ack_query(now)
          return nil if @ack_kind.nil? || !running?
          if (q = @pending_query)
            @pending_query = nil
            @probe[:sent] = now
            return q
          end
          if @ack_sent
            return nil unless @ack_sent.is_a?(Float) && now - @ack_sent > ACK_TIMEOUT
            @ack_lost += 1
            @ack_sent = nil
          end
          return nil if now < @ack_due
          @ack_due = now + @ack_every
          @ack_sent = :pending
          @ack_queries += 1
          ACK_QUERIES[@ack_kind]
        end

        # True while a cursor report is awaited (the decoder parses CSI r;c R
        # as a Reply then, not Shift-F3).
        def expect_cpr? = @ack_kind == :dsr && !@ack_sent.nil?

        # True while an XTVERSION answer (a DCS) may come (IDENTITY_WAIT
        # seconds after #identify asked; a DCS after that is Alt-P again).
        def expect_dcs?(now) = !@probe.nil? && now - @probe[:sent] < IDENTITY_WAIT && !@identity.key?(:xtversion)

        # Seconds an XTVERSION answer is waited for.
        IDENTITY_WAIT = 5.0

        ### The input thread's hooks

        # A reply event from the terminal at +now+: true if it was ours
        # (consumed: it never reaches the Router, Pry, or NAV).
        def reply(e, now)
          case e.kind
          when :device, :cursor
            want = @ack_kind == :da1 ? :device : :cursor
            return false unless e.kind == want && @ack_sent.is_a?(Float)
            i = @ack_count % ACK_RING
            @ack_from_start[i] = now - @ack_sent
            @ack_from_end[i] = now - @ack_wrote
            @ack_count += 1
            @ack_sent = nil
            true
          when :dcs
            @identity[:xtversion] = e.data.sub(/\A>\|/, '')
            true
          when :device2
            @identity[:da2] = e.data
            true
          else
            false
          end
        end

        # A key arrived at +arrival+ and its handler finished at +handled+;
        # +repl+ when it went to the REPL (its echo comes through the pty).
        def key(arrival, handled, repl)
          return unless running?
          @key_lock.synchronize do
            if @key_tail - @key_head >= KEY_RING
              @key_head += 1
              @key_unseen += 1
            end
            i = @key_tail % KEY_RING
            @keys_arrival[i] = arrival
            @keys_handled[i] = handled
            @keys_repl[i] = repl
            @key_tail += 1
          end
        end

        # Keys whose frame this is (written at +t1+): handled before the
        # frame started, and for REPL keys only when the frame redrew the
        # REPL.  Keys older than KEY_TIMEOUT count as showing no change.
        private def match_keys(t1)
          return if @key_head == @key_tail
          @key_lock.synchronize do
            j = @key_head
            while j < @key_tail
              i = j % KEY_RING
              if @keys_handled[i] <= @frame_start && (!@keys_repl[i] || @frame_repl)
                @key_lat[@key_lat_count % KEY_RING] = t1 - @keys_arrival[i]
                @key_lat_count += 1
                @keys_handled[i] = Float::INFINITY # (done)
              elsif t1 - @keys_arrival[i] > KEY_TIMEOUT && @keys_handled[i] != Float::INFINITY
                @key_unseen += 1
                @keys_handled[i] = Float::INFINITY
              end
              j += 1
            end
            @key_head += 1 while @key_head < @key_tail && @keys_handled[@key_head % KEY_RING] == Float::INFINITY
          end
        end

        ### Terminal identity and audio

        # The terminal's identity: the probe's findings (+features+), the
        # environment, and XTVERSION / DA2 answers when +term+ can be asked
        # (written now; the answers come through #reply).
        def identify(features: {}, term: nil, size: nil)
          @identity[:features] = features.dup
          @identity[:size] = size
          @identity[:env] = Perf.terminal_env
          @identity[:da1] = features[:device] if features[:device]
          return unless term && @ack_kind
          # (sent with the next written frame, by the painter: the one writer)
          @probe = { sent: @clock.call, done: nil }
          @pending_query = IDENTITY_QUERY
        end

        # XTVERSION and secondary device attributes.
        IDENTITY_QUERY = "\e[>0q\e[>c".freeze

        # Environment variables that name the terminal (TERM, TERM_PROGRAM,
        # KONSOLE_VERSION, VTE_VERSION, ...; ssh and tmux too).
        def self.terminal_env
          keys = %w[TERM TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM KONSOLE_VERSION VTE_VERSION LC_TERMINAL LC_TERMINAL_VERSION
                    WT_SESSION KITTY_WINDOW_ID ALACRITTY_WINDOW_ID WEZTERM_VERSION GHOSTTY_RESOURCES_DIR TMUX STY SSH_CONNECTION
                    OUTPUT_TYPE AUDIO_PROFILE RUBY_THREAD_TIMESLICE MB_SOUND_YJIT]
          keys.filter_map { |k| [k, k == 'SSH_CONNECTION' && ENV[k] ? 'yes' : ENV[k]] if ENV[k] }.to_h
        end

        # The machine (CPU model, cores, OS, Ruby, YJIT, load average).
        def self.machine
          cpu = File.foreach('/proc/cpuinfo').find { |l| l.start_with?('model name') }&.split(':', 2)&.last&.strip rescue nil
          {
            host_cpu: cpu || RbConfig::CONFIG['host_cpu'],
            cores: Etc.nprocessors,
            os: RbConfig::CONFIG['host_os'],
            container: File.exist?('/.dockerenv'),
            ruby: RUBY_VERSION,
            yjit: defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false,
            loadavg: loadavg,
          }
        end

        # The 1, 5, and 15 minute load averages, or nil (no /proc).
        def self.loadavg
          File.read('/proc/loadavg').split.first(3).map(&:to_f)
        rescue SystemCallError
          nil
        end

        # Watches the render thread's GVL waits (wake delay) and the
        # painter's with FastUI::GVLProbe while recording, unless another
        # tool runs the probe.  +threads+: {name => Thread}.
        def start_probe(threads)
          return if @probe_started || FastUI::GVLProbe.active?
          names = threads.keys.first(6)
          list = names.map { |n| threads[n] }
          return if list.compact.length != list.length || list.empty?
          FastUI::GVLProbe.start(list)
          @probe_started = names
          @audio_t0 = @clock.call
        end

        private def stop_probe
          return unless @probe_started.is_a?(Array)
          names = @probe_started
          secs = [@clock.call - @audio_t0, 1e-6].max
          @audio = { seconds: secs }
          names.each_with_index do |n, i|
            @audio[n] = FastUI::GVLProbe.waits(i)
          end
          @audio[:blockers] = FastUI::GVLProbe.blockers(0).map { |w, slot| [w, slot < 0 ? :other : names[slot]] }
          FastUI::GVLProbe.stop
          @probe_started = true
        end

        ### Results

        # Values of field +f+ in recording order.
        def values(f)
          n = [@count, @ring].min
          col = @cols.fetch(f)
          return col.first(n) if @count <= @ring
          s = @count % @ring
          col[s..] + col[0, s]
        end

        # Percentiles of +list+ (p50, p95, p99, max), in milliseconds when
        # +ms+.
        def self.stats(list, ms: true)
          return { n: 0 } if list.empty?
          v = list.sort
          k = ms ? 1000.0 : 1.0
          q = ->(p) { (v[((v.length - 1) * p).round] * k).round(2) }
          { n: v.length, min: (v[0] * k).round(2), p50: q.(0.5), p95: q.(0.95), p99: q.(0.99), max: (v[-1] * k).round(2) }
        end

        # Everything as a Hash (the JSON file and the report read it).
        def summary
          now = @stopped_at || @clock.call
          secs = [now - @started_at, 1e-6].max
          n = [@count, @ring].min
          bytes = values(:bytes)
          written = bytes.select(&:positive?)
          gc = values(:gc_ms)
          panes = @panes.to_h do |name, (ring, cnt, _)|
            gaps = ring.first([cnt, PANE_RING].min)
            st = Perf.stats(gaps)
            [name, st.merge(draws: cnt + 1, rate: (cnt / secs).round(1), stale: gaps.count { |g| g > STALE })]
          end
          keys = @key_lat.first([@key_lat_count, KEY_RING].min)
          acks_s = @ack_from_start.first([@ack_count, ACK_RING].min)
          acks_e = @ack_from_end.first([@ack_count, ACK_RING].min)
          stalest = panes.max_by { |_, s| s[:max] || 0 }
          {
            label: @label,
            seconds: secs.round(2),
            frames: @count,
            kept: n,
            refreshes_per_s: (@count / secs).round(1),
            written_per_s: (written.length / secs).round(1),
            late_ms: Perf.stats(values(:late)),
            paint_ms: Perf.stats(values(:paint)),
            write_ms: Perf.stats(values(:write)),
            writes_over_2ms: values(:write).count { |w| w > 0.002 },
            bytes_per_written: Perf.stats(written, ms: false),
            kb_per_s: (written.sum / secs / 1000.0).round(1),
            full_redraws: values(:full).count(1),
            skipped: values(:skipped).sum.to_i,
            gc: { frames_with_gc: values(:gc_runs).count(&:positive?), runs: values(:gc_runs).sum.to_i, max_ms: gc.max || 0, total_ms: gc.sum },
            worst_written_gap: { ms: (@gap_max * 1000).round(1), at: (@gap_at - @started_at).round(2) },
            worst_start_gap: { ms: (@start_gap_max * 1000).round(1), at: (@start_gap_at - @started_at).round(2) },
            panes: panes,
            stalest_pane: stalest && { name: stalest[0], max_ms: stalest[1][:max], p95_ms: stalest[1][:p95] },
            keys: Perf.stats(keys).merge(no_change: @key_unseen),
            acks: { kind: @ack_kind, queries: @ack_queries, answered: @ack_count, lost: @ack_lost,
                    from_write_end_ms: Perf.stats(acks_e), from_write_start_ms: Perf.stats(acks_s) },
            audio: audio_summary,
            identity: @identity,
          }
        end

        private def audio_summary
          return nil unless @audio
          min = @audio[:seconds] / 60.0
          out = { seconds: @audio[:seconds].round(1) }
          @audio.each do |k, v|
            next unless v.is_a?(Array) && k != :blockers
            st = Perf.stats(v)
            st[:p999] = (v.sort[((v.length - 1) * 0.999).round] * 1000).round(3) unless v.empty?
            st[:over_2ms_per_min] = (v.count { |x| x > 0.002 } / min).round(1)
            out[k] = st
          end
          by = Hash.new(0)
          @audio[:blockers].each { |_, who| by[who] += 1 }
          out[:render_blockers_over_1ms] = by
          out
        end

        # The three lines (worst stall, stalest pane, key-to-frame p95).
        def headline(s = summary)
          w = s[:worst_written_gap]
          sp = s[:stalest_pane]
          k = s[:keys]
          [
            "worst stall: #{w[:ms]} ms between written frames at #{w[:at]} s (frame lateness p99 #{s[:late_ms][:p99] || '-'} ms, max #{s[:late_ms][:max] || '-'} ms)",
            sp ? "stalest pane: #{sp[:name]} went #{sp[:max_ms]} ms without a redraw (p95 #{sp[:p95_ms]} ms)" : 'stalest pane: (no pane redraws recorded)',
            k[:n].to_i > 0 ? "key to frame: p95 #{k[:p95]} ms (p50 #{k[:p50]}, max #{k[:max]}, #{k[:n]} keys)" : 'key to frame: (no keys typed while recording)',
          ]
        end

        # The report as a Help::Doc page.
        def report(s = summary)
          require_relative '../help' # (console help loads on first use)
          d = Help::Doc.new
          d.title 'UI frame instruments', 'ui.perf :report'
          d.para "#{s[:seconds]} s, #{s[:frames]} refreshes (#{s[:refreshes_per_s]}/s), #{s[:written_per_s]} written/s, " \
                 "#{s[:kb_per_s]} kB/s.  Times in ms.  An answer to the terminal query bounds its parse time, not its paint."
          d.lines headline(s).map { |l| "  #{l}" }
          d.heading 'Frames'
          rows = [
            ['lateness', fmt(s[:late_ms])], ['paint', fmt(s[:paint_ms])], ['write', "#{fmt(s[:write_ms])}  (#{s[:writes_over_2ms]} over 2 ms)"],
            ['bytes/frame', fmt(s[:bytes_per_written])],
            ['worst gaps', "written #{s[:worst_written_gap][:ms]} at #{s[:worst_written_gap][:at]} s; starts #{s[:worst_start_gap][:ms]} at #{s[:worst_start_gap][:at]} s"],
            ['redraws', "#{s[:full_redraws]} full, #{s[:skipped]} deadlines skipped"],
            ['GC', "#{s[:gc][:runs]} runs in #{s[:gc][:frames_with_gc]} frames, longest #{s[:gc][:max_ms]} ms"],
          ]
          d.rows rows, max_label: 12
          unless s[:panes].empty?
            d.heading "Panes (update age: ms between redraws; stale: over #{(STALE * 1000).round} ms)"
            d.lines(s[:panes].sort_by { |_, v| -(v[:max] || 0) }.map do |name, v|
              format('  %-14s %6.1f/s  p50 %7s  p95 %7s  max %7s  stale %d', name, v[:rate], v[:p50] || '-', v[:p95] || '-', v[:max] || '-', v[:stale])
            end)
          end
          d.heading 'Keys and the terminal'
          a = s[:acks]
          d.rows [
            ['key to frame', "#{fmt(s[:keys])}  (#{s[:keys][:no_change]} showed no change)"],
            ["#{a[:kind] || 'no'} answers", a[:kind] ? "#{fmt(a[:from_write_end_ms])} after the write; #{a[:answered]} of #{a[:queries]} answered, #{a[:lost]} lost" : 'off'],
          ], max_label: 12
          if (au = s[:audio])
            d.heading 'Audio (GVL waits: the render thread\'s wake delay)'
            d.lines(au.filter_map do |k, v|
              next unless v.is_a?(Hash) && v.key?(:n) && v[:n].to_i > 0
              format('  %-9s p50 %s  p99 %s  p99.9 %s  max %s  >2 ms/min %s', k, v[:p50], v[:p99], v[:p999], v[:max], v[:over_2ms_per_min])
            end)
          end
          id = s[:identity]
          d.heading 'Terminal'
          d.rows [
            ['version', id[:xtversion] || '(no XTVERSION answer)'],
            ['DA1 / DA2', "#{id[:da1].inspect} / #{id[:da2].inspect}"],
            ['probe', id[:features].inspect],
            ['env', id[:env].inspect],
          ], max_label: 12
          d
        end

        private def fmt(st)
          return '-' if st.nil? || st[:n].to_i == 0
          "p50 #{st[:p50]}  p95 #{st[:p95]}  p99 #{st[:p99]}  max #{st[:max]}  (n #{st[:n]})"
        end

        # Raw frame records ({field => [values]}, seconds and bytes).
        def records
          FIELDS.to_h { |f| [f, values(f)] }
        end

        # Writes report.txt, summary.json, and frames.json to +dir+
        # (default: a new folder under Perf.captures_dir named for the
        # machine, the terminal, and the time).  Returns the directory.
        def save(dir = nil, extra: {})
          s = summary
          dir ||= File.join(Perf.captures_dir, Perf.folder_name(@identity))
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'report.txt'), MB::U.remove_ansi(report(s).to_s) + "\n")
          File.write(File.join(dir, 'summary.json'), JSON.pretty_generate(s.merge(machine: Perf.machine, **extra)))
          File.write(File.join(dir, 'frames.json'), JSON.generate(records.merge(panes: @panes.to_h { |n, (r, c, _)| [n, r.first([c, PANE_RING].min)] })))
          dir
        end

        # "<machine>-<terminal>-<YYYY-MM-DD-HHMMSS>" (local time).
        def self.folder_name(identity)
          cpu = machine[:host_cpu].to_s
          m = cpu[/7950X/] ? 'linux' : cpu[/i9-9880H/] ? 'mac' : cpu.split.last.to_s
          m = "#{m}-native" unless File.exist?('/.dockerenv') || !RUBY_PLATFORM.include?('darwin')
          t = identity[:xtversion] || identity.dig(:env, 'TERM_PROGRAM') || (identity.dig(:env, 'KONSOLE_VERSION') && 'konsole') || identity.dig(:env, 'TERM') || 'terminal'
          "#{m}-#{t.to_s.downcase.gsub(/[^a-z0-9.]+/, '_')[0, 30]}-#{Time.now.strftime('%Y-%m-%d-%H%M%S')}"
        end
      end

      class Perf
        # Scheduler run delay in seconds (time runnable but waiting for a
        # CPU: /proc/self/schedstat's second field, or a thread's under
        # /proc/self/task), or nil without /proc.  A run whose delay is
        # small against its wall time was clean whatever the load average.
        def self.run_delay(thread = nil)
          path = thread&.native_thread_id ? "/proc/self/task/#{thread.native_thread_id}/schedstat" : '/proc/self/schedstat'
          File.read(path).split[1].to_i / 1e9
        rescue SystemCallError, NoMethodError
          nil
        end

        # Run delays of the process and the named threads ({name => s}).
        def self.run_delays(threads = {})
          { process: run_delay }.merge(threads.compact.transform_values { |t| run_delay(t) })
        end

        # `ui.perf :capture`: about a minute of what the maintainer
        # normally has on screen, recorded in his real terminal and saved
        # where agents read it: phase 1 the tiles with the set playing
        # (keys typed then are timed), phase 2 the sound-design screen
        # with a knob swept by scripted arrow keys.  Runs on a thread of
        # its own (the console stays usable) and prints three lines.
        module Capture
          SECONDS = 60

          # Scripted knob steps: seconds between arrow keys, and steps
          # each way.
          STEP = 0.12
          SWEEP = 8

          class << self
            attr_reader :thread
          end

          def self.start(seconds: SECONDS, design: nil, dir: nil, out: $stdout)
            if @thread&.alive?
              out.puts "\e[33mui.perf :capture is running already\e[0m"
              return nil
            end
            out.puts "\e[1mui.perf :capture\e[0m: #{seconds.round} s.  Phase 1: the tiles with the set playing (type a few keys, scroll, NAV around).  " \
                     'Phase 2: the sound-design screen with a knob moving.  Results print here.'
            @thread = Thread.new do
              Thread.current.name = 'MB::Sound::UI perf capture'
              run(seconds: seconds, design: design, dir: dir, out: out)
            rescue => e
              out.puts "\e[31mui.perf :capture failed: #{e.class}: #{e.message}\e[0m"
              out.puts e.backtrace.first(5).map { |l| "  #{l}" }
            end
            nil
          end

          # Steps the sound screen's inspector down (as typed: Down) until
          # its picked row has a knob to turn, at most +tries+ rows (the
          # inspector opens on a node row, which turns nothing).  Returns
          # the knob's name, or nil.
          def self.pick_knob(tiles, tries: 24)
            insp = tiles.pane_object(:inspector) or return nil
            return nil unless insp.respond_to?(:picked, true)
            tries.times do
              # (Inspector#picked is the pane's own private helper: read,
              # never changed, from here)
              state = tiles.pane_state(:inspector) or return nil # (not on this screen)
              if (kn = insp.__send__(:picked, state))
                return kn[0]
              end
              tiles.type_scripted("\e[B")
              sleep 0.05
            end
            nil
          end

          # The capture itself (on the calling thread).  Returns the
          # directory it saved.
          def self.run(seconds: SECONDS, design: nil, dir: nil, out: $stdout)
            notes = []
            session = Session.current
            started_demo = false
            if session.players.empty? && session.arrangement.tracks.empty?
              # (console lines, journaled as if typed: UI.run_line)
              UI.run_line('demo', session)
              scene = session.arrangement.scenes.keys[1] || session.arrangement.scenes.keys[0]
              UI.run_line("go #{scene.inspect}", session) if scene
              started_demo = true
              notes << "nothing played: loaded demo :night_bus and went to #{scene.inspect}"
            end
            tiles = UI.tiles
            unless tiles&.active? && tiles.layout_name != :sound
              UI.show(:tiles)
              tiles = UI.tiles
              notes << 'phase 1 opened ui :tiles'
            end
            # (a set just started, or a screen just opened: its first walks,
            # warm-ups, and pane rates stepped down by them settle first; in
            # a pty run they were a 120-160 ms stall at 0.3 s and the list
            # panes at their slowest rate, 2026-11-16)
            sleep 2.0 if started_demo || notes.include?('phase 1 opened ui :tiles')
            half = seconds / 2.0
            loads = [Perf.loadavg]
            delays0 = Perf.run_delays(render: session.render_thread, painter: tiles&.thread)

            # Phase 1: the tiles
            p1 = tiles.start_perf(label: "tiles #{tiles.layout_name}")
            sleep half
            tiles.stop_perf
            id = p1.identity
            dir ||= File.join(Perf.captures_dir, Perf.folder_name(id)) # (named for the terminal, once it answered)
            p1.save(File.join(dir, 'tiles'), extra: { notes: notes })

            # Phase 2: the sound-design screen with a knob sweeping
            p2 = nil
            target = design || Design.last
            made = false
            begin
              unless target
                target = :ui_perf
                made = true
              end
              UI.run_line("design #{target.inspect}", session)
              tiles = UI.tiles
              sleep 1.0 # (the screen settles: first walks, warm-up frames)
              knob = Capture.pick_knob(tiles)
              notes << (knob ? "phase 2 turns #{knob.inspect}" : 'phase 2 found no knob row in the inspector: its arrows turn nothing (key times are frames, not changes)')
              p2 = tiles.start_perf(label: "design #{target.inspect}")
              t_end = MB::U.clock_now + half - 1.0
              k = 0
              while MB::U.clock_now < t_end
                tiles.type_scripted((k / SWEEP).even? ? "\e[C" : "\e[D")
                k += 1
                sleep STEP
              end
              tiles.stop_perf
              p2.save(File.join(dir, 'design'), extra: { notes: notes, scripted_keys: k, knob: knob })
            rescue => e
              notes << "phase 2 skipped: #{e.class}: #{e.message} (run `design :name` once, then ui.perf :capture)"
            ensure
              UI.run_line('design off', session) rescue nil
              if made
                UI.run_line('stop :ui_perf, fade: 0', session) rescue nil
                UI.run_line('untrack :ui_perf', session) rescue nil
              end
            end
            UI.run_line('stop :all', session) if started_demo
            loads << Perf.loadavg
            delays1 = Perf.run_delays(render: session.render_thread, painter: UI.tiles&.thread)
            File.write(File.join(dir, 'capture.json'), JSON.pretty_generate({ seconds: seconds, notes: notes, loadavg: loads, run_delay_s: { before: delays0, after: delays1 },
                                                                              machine: Perf.machine, identity: id }))
            lines = p1.headline
            lines += p2.headline.drop(0).map { |l| "design: #{l}" } if p2
            out.puts "\e[1mui.perf :capture\e[0m saved #{dir}"
            lines.first(p2 ? 6 : 3).each { |l| out.puts "  #{l}" }
            notes.each { |n| out.puts "\e[2m  #{n}\e[0m" }
            out.puts "\e[2m  terminal: #{id[:xtversion] || 'did not answer XTVERSION'}; acks #{p1.summary[:acks][:answered]}/#{p1.summary[:acks][:queries]}\e[0m"
            dir
          end
        end
      end
    end
  end
end
