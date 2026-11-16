#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Runs a terminal UI scenario on a pty read by a model terminal and reports what a person would see.
#
# The screen (the band, the tiles with "Last Stop" playing, a console
# flood, the sound-design screen with a knob swept by arrow keys, typing in
# the REPL, or a standalone Plot::Live scope as the live plots of the ui-2
# step wrote it) draws to a pty.  A SINK process reads the pty the way a
# terminal does: unlimited, throttled to --bps bytes per second, with a
# parse cost per escape sequence (--esc-us), per cell (--cell-us), and per
# frame (--frame-us), answering queries (DA1, cursor reports, DECRQM 2026)
# only after it has consumed the bytes before them, and typing the
# scenario's keys.  It keeps a MB::Term::VT of the screen and notes which
# cells changed in each frame (DEC 2026 brackets), so each pane's VISIBLE
# update rate is measured at the terminal's end, not the painter's.
#
# Reported per run: the ui.perf instruments (frame lateness, paint, write
# and blocked writes, the worst stall, bytes per frame, each pane's update
# age, key-to-frame, the sink's answer time), the byte stream's shape per
# frame (escapes, cursor moves, SGR changes, cells), the sink's frame
# intervals and each pane's visible update intervals, the render thread's
# wake delay (FastUI::GVLProbe), the load average and the scheduler run
# delays (time runnable but not running) of the process, painter, and
# render thread, so a run on a loaded machine says so.  Numbers are
# "harness" numbers: a real terminal's parse and paint differ (Konsole
# repaints on its own timer; see design/notes/terminal_ui.md, Frame
# instruments).
#
# Try:
#     bin/ui_bench.rb                                   # tiles with the song, unlimited sink, 10 s
#     bin/ui_bench.rb -S band,tiles,flood,design,typing,plot -s 8
#     bin/ui_bench.rb -S tiles --sink konsole           # a terminal with a per-sequence and per-cell cost
#     bin/ui_bench.rb -S tiles --sink throttle --bps 200000
#     bin/ui_bench.rb -S tiles,plot --size 40x140 -j /tmp/ui_bench.json
#     bin/ui_bench.rb -S tiles -L low                   # 256-frame writes (the :low profile)
#
# Runs the same on the Mac container (it prints the machine it ran on).

require 'bundler/setup'
require 'json'
require 'pty'
require 'io/console'
require 'mb-sound'
require_relative 'songs/night_bus_flow'

module MB::Sound
  # The model terminal and scenarios of bin/ui_bench.rb.
  module UIBench
    # Sink kinds: their default parameters.
    SINKS = {
      unlimited: { bps: nil, esc_us: 0.0, cell_us: 0.0, frame_us: 0.0 },
      throttle: { bps: 250_000, esc_us: 0.0, cell_us: 0.0, frame_us: 0.0 },
      parse: { bps: nil, esc_us: 0.0, cell_us: 0.0, frame_us: 4000.0 },
      # A guess at a Qt terminal's costs (stated, varied with the options):
      # 2 us per escape sequence, 0.3 us per cell, 1 ms per frame
      konsole: { bps: nil, esc_us: 2.0, cell_us: 0.3, frame_us: 1000.0 },
    }.freeze

    SCENARIOS = %i[band tiles flood design typing plot].freeze

    # Escape sequences the sink counts (CSI, ESC 7/8 and other two-byte
    # escapes, DCS/OSC strings).
    ESCAPE = /\e\[[0-?]*[ -\/]*[@-~]|\e[P\]][^\e\a]*(?:\a|\e\\)|\e[^\[P\]]/n

    module_function

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The sink: reads +master+ until EOF or +stop_at+, modelling a terminal
    # (see the file's header), and writes its findings as JSON to +out+.
    # Runs in a forked process.
    def sink(master, rows, cols, cfg, keys, out, t0)
      vt = MB::Term::VT.new(rows, cols, scrollback: 0)
      prev = vt.lines
      frames = []
      cur = { bytes: 0, esc: 0, cup: 0, sgr: 0, cells: 0 }
      debt = 0.0
      key_i = 0
      sent = []
      replies = 0
      cpu0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      pay = lambda do
        if debt > 0.0005
          sleep debt
          debt = 0.0
        end
      end
      loop do
        t = now
        while key_i < keys.length && t - t0 >= keys[key_i][0]
          master.write(keys[key_i][1])
          sent << t - t0
          key_i += 1
        end
        wait = key_i < keys.length ? (keys[key_i][0] - (t - t0)).clamp(0.0, 0.05) : 0.05
        ready = IO.select([master], nil, nil, wait)
        next unless ready
        data = begin
          master.read_nonblock(cfg[:chunk] || 65_536)
        rescue IO::WaitReadable
          next
        rescue EOFError, Errno::EIO
          break
        end
        debt += data.bytesize.to_f / cfg[:bps] if cfg[:bps]
        cur[:bytes] += data.bytesize
        pos = 0 # (scanned up to)
        fed = 0 # (fed to the VT up to)
        cells = lambda do |a, b|
          n = data.byteslice(a, b - a).force_encoding(Encoding::UTF_8).scrub.length
          cur[:cells] += n
          debt += n * cfg[:cell_us] * 1e-6
        end
        data.scan(ESCAPE) do
          m = Regexp.last_match
          cells.call(pos, m.begin(0))
          seq = m[0]
          pos = m.end(0)
          cur[:esc] += 1
          debt += cfg[:esc_us] * 1e-6
          case seq[-1]
          when 'H' then cur[:cup] += 1 if seq.start_with?("\e[")
          when 'm' then cur[:sgr] += 1
          end
          answer =
            case seq
            when "\e[c", "\e[0c" then "\e[?62;22c"
            when "\e[6n" then "\e[1;2R"
            when "\e[?2026$p" then "\e[?2026;2$y"
            when "\e[>0q" then "\eP>|ui_bench sink(#{cfg[:kind]})\e\\"
            when "\e[>c" then "\e[>0;0;0c"
            end
          if answer
            pay.call
            master.write(answer)
            replies += 1
          end
          next unless seq == "\e[?2026l"

          # A frame ends: the model's parse cost, then what changed on screen
          vt.feed(data.byteslice(fed, pos - fed))
          fed = pos
          debt += cfg[:frame_us] * 1e-6
          pay.call
          lines = vt.lines
          changed = []
          lines.each_with_index do |l, y|
            a = prev[y] || ''
            next if l == a
            w = [l.length, a.length].max
            x0 = (0...w).find { |x| l[x] != a[x] } || 0
            x1 = w - 1
            x1 -= 1 while x1 > x0 && l[x1] == a[x1]
            changed << [y, x0, x1]
          end
          prev = lines
          rem = data.bytesize - pos
          frames << [now - t0, cur[:bytes] - rem, cur[:esc], cur[:cup], cur[:sgr], cur[:cells], changed]
          cur = { bytes: rem, esc: 0, cup: 0, sgr: 0, cells: 0 }
        end
        cells.call(pos, data.bytesize)
        vt.feed(data.byteslice(fed, data.bytesize - fed)) if fed < data.bytesize
        pay.call
      end
    ensure
      File.write(out, JSON.generate({ frames: frames, keys_sent: sent, replies: replies, screen: prev, # (the last frame's screen)
                                      cpu: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu0 }))
    end

    # Keys the sink types for +scenario+: [[seconds from the start, bytes]].
    def keys_for(scenario, warm, seconds, key_rate: nil)
      case scenario
      when :typing
        t = warm + 0.3
        list = []
        k = 0
        while t < warm + seconds
          list << [t, (k % 20 == 19) ? "\x15" : 'x'] # (Ctrl-U clears the line now and then)
          t += 0.15
          k += 1
        end
        list
      when :design
        # (the inspector opens on a node row, which has no knob: the bench
        # picks a knob row during --warm, UI::Perf::Capture.pick_knob, and
        # the sink's Right/Left turn it)
        list = []
        return list if key_rate && key_rate <= 0
        dt = key_rate ? 1.0 / key_rate : 0.12
        t = warm + 0.3
        k = 0
        while t < warm + seconds
          list << [t, (k / 8).even? ? "\e[C" : "\e[D"]
          t += dt
          k += 1
        end
        list
      else
        []
      end
    end

    # --late: the late handovers grouped by thread and innermost frames, and
    # the render waits over 2 ms and late handovers that overlap a GC step
    # (from the probe's log: [kind, slot, holder, a, b, c, gc_count]).
    def late_report(names, late, log)
      log = log.map { |k, slot, holder, a, b, c, n| [k, slot, holder, a.to_i / 1e9, b.to_i / 1e9, c.to_i / 1e9, n] }
      gcs = log.select { |r| r[0] == :gc }.map { |r| [r[3], r[4]] }
      overlap = ->(a, b) { gcs.any? { |x, y| x < b && y > a } }
      waits = log.select { |r| r[0] == :thread && r[1] == 0 && r[5] > 0 && r[4] > 0 && r[5] - r[4] > 0.002 }
      th = names.each_with_index.to_h { |n, i| [i, n] }
      by = Hash.new { |h, k| h[k] = [0, 0.0, 0.0] }
      over_gc = 0
      late.each do |at, by_s, thread, frames|
        over_gc += 1 if overlap.call(at - by_s, at)
        tn = (thread.name || 'thread').sub(/\AMB::Sound::/, '')
        site = frames.first(3).map { |label, path, line| "#{label} #{File.basename(path.to_s)}:#{line}" }.join(' < ')
        e = by[[tn, site]]
        e[0] += 1
        e[1] += by_s * 1000
        e[2] = by_s * 1000 if by_s * 1000 > e[2]
      end
      {
        n: late.length, over_gc: over_gc, gc_steps: gcs.length, waits: waits.length,
        waits_gc: waits.count { |r| overlap.call(r[4], r[5]) },
        waits_by_holder: waits.group_by { |r| th[r[2]] || :other }.transform_values(&:length),
        sites: by.map { |(t, at), (n, ms, mx)| { thread: t, at: at, n: n, ms: ms.round(1), max_ms: mx.round(2) } }.sort_by { |x| -x[:ms] },
      }
    end

    # YJIT's compile counters (nil without YJIT): compiling holds the GVL
    # with no interrupt check, so a screen's first seconds hold it long.
    def yjit_stats
      return nil unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      RubyVM::YJIT.runtime_stats.slice(:compiled_block_count, :compile_time_ns, :invalidation_count, :code_gc_count, :invalidate_method_lookup, :invalidate_bop_redefined, :invalidate_constant_state_bump, :invalidate_constant_ic_fill, :invalidate_no_singleton_class, :invalidate_ep_escape, :invalidate_everything)
    end

    # --holders: per render buffer, from the output's #write (a module
    # prepended to that one output's singleton class, for the run): when
    # each write began and returned, and GC and YJIT counters at both, so
    # a buffer's render (the previous write's return to this write's call,
    # on the render thread) is told apart from its write's wait for the
    # output.  Preallocated Arrays of Integers and flonums: nothing
    # allocates on the render path.
    class BufferLog
      FIELDS = %i[t_in t_out gc_in gc_out gcn_in gcn_out maj_in maj_out jit_in jit_out blk_in blk_out inv_in inv_out].freeze

      # Prepended to the output's singleton class.
      module Hook
        def write(data)
          l = @ui_bench_log
          l&.enter
          r = super
          l&.leave
          r
        end
      end

      def initialize(output, session, size = 20_000)
        @output = output
        @session = session
        @n = size
        FIELDS.each { |f| instance_variable_set(:"@#{f}", Array.new(size, 0)) }
        @pos = Array.new(size)
        @i = 0
        @jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
        @transport = session.transport
        output.instance_variable_set(:@ui_bench_log, nil)
        output.singleton_class.prepend(Hook) unless output.singleton_class.include?(Hook)
      end

      def start = @output.instance_variable_set(:@ui_bench_log, self)
      def stop = @output.instance_variable_set(:@ui_bench_log, nil)

      def enter
        i = @i
        return if i >= @n
        @t_in[i] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @gc_in[i] = GC.total_time
        @gcn_in[i] = GC.count
        @maj_in[i] = GC.stat(:major_gc_count)
        if @jit
          @jit_in[i] = RubyVM::YJIT.runtime_stats(:compile_time_ns)
          @blk_in[i] = RubyVM::YJIT.runtime_stats(:compiled_block_count)
          @inv_in[i] = RubyVM::YJIT.runtime_stats(:invalidation_count)
        end
        @pos[i] = @transport.position
      end

      def leave
        i = @i
        return if i >= @n
        @t_out[i] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @gc_out[i] = GC.total_time
        @gcn_out[i] = GC.count
        @maj_out[i] = GC.stat(:major_gc_count)
        if @jit
          @jit_out[i] = RubyVM::YJIT.runtime_stats(:compile_time_ns)
          @blk_out[i] = RubyVM::YJIT.runtime_stats(:compiled_block_count)
          @inv_out[i] = RubyVM::YJIT.runtime_stats(:invalidation_count)
        end
        @i = i + 1
      end

      # Per buffer after the first: its render window (ms), GC and YJIT
      # time inside it, and whether its write returned without waiting.
      def report(period, t0)
        n = @i
        wall = Time.now.to_f - Process.clock_gettime(Process::CLOCK_MONOTONIC) # (the wall clock at a monotonic time: YJIT's --yjit-log stamps)
        rows = (1...n).map { |i|
          {
            i: i, at_s: (@t_in[i] - t0).round(3), wall: Time.at(@t_out[i - 1] + wall).strftime('%H:%M:%S.%6N'), render_ms: ((@t_in[i] - @t_out[i - 1]) * 1000).round(3),
            gc_ms: ((@gc_in[i] - @gc_out[i - 1]) / 1e6).round(2), gcs: @gcn_in[i] - @gcn_out[i - 1], majors: @maj_in[i] - @maj_out[i - 1],
            gc_in_write_ms: ((@gc_out[i] - @gc_in[i]) / 1e6).round(2), gcs_in_write: @gcn_out[i] - @gcn_in[i],
            jit_ms: ((@jit_in[i] - @jit_out[i - 1]) / 1e6).round(2), blocks: @blk_in[i] - @blk_out[i - 1], inv: @inv_in[i] - @inv_out[i - 1], inv_before: @inv_out[i - 1] - @inv_in[i - 1],
            write_ms: ((@t_out[i] - @t_in[i]) * 1000).round(3),
            jit_in_write_ms: ((@jit_out[i] - @jit_in[i]) / 1e6).round(2),
            bar: (@transport.bar_at(@pos[i]).to_f.round(3) rescue nil),
          }
        }
        r = rows.map { |x| x[:render_ms] / 1000.0 }
        p_ms = period * 1000
        over = rows.select { |x| x[:render_ms] > p_ms }
        {
          n: rows.length, period_ms: p_ms.round(3), render_ms: UI::Perf.stats(r),
          over_period: over.length, over_half: rows.count { |x| x[:render_ms] > p_ms / 2 },
          over_per_min: rows.empty? ? 0 : (over.length * 60.0 / (rows.length * period)).round(1),
          no_wait_writes: rows.count { |x| x[:write_ms] < 0.2 },
          render_jit_ms: rows.sum { |x| x[:jit_ms] }.round(1), write_jit_ms: rows.sum { |x| x[:jit_in_write_ms] }.round(1),
          render_gc_ms: rows.sum { |x| x[:gc_ms] }.round(1),
          # GC on the render thread: buffers whose render ran a GC step
          # (their render window holds the GVL: a step there is the render
          # thread's own), and steps elsewhere while it waited
          gc_steps: {
            render: rows.count { |x| x[:gcs] > 0 }, render_majors: rows.count { |x| x[:majors] > 0 },
            render_per_min: rows.empty? ? 0 : (rows.count { |x| x[:gcs] > 0 } * 60.0 / (rows.length * period)).round(1),
            render_max_ms: rows.map { |x| x[:gcs] > 0 ? x[:gc_ms] : 0 }.max.to_f.round(2),
            render_ms: rows.sum { |x| x[:gcs] > 0 ? x[:gc_ms] : 0 }.round(1),
            elsewhere: rows.sum { |x| x[:gcs_in_write] }, elsewhere_ms: rows.sum { |x| x[:gc_in_write_ms] }.round(1),
            list: rows.select { |x| x[:gcs] > 0 }.map { |x| x.slice(:i, :at_s, :bar, :render_ms, :gc_ms, :majors) },
          },
          worst: rows.max_by(8) { |x| x[:render_ms] },
        }
      end
    end

    # Percentiles of +v+ in ms.
    def stats(v) = UI::Perf.stats(v)

    # The sink's findings for the screen's +rects+ ({name => Rect}).
    def sink_report(data, rects, t_from, key_panes: [])
      frames = data['frames'].select { |f| f[0] >= t_from }
      times = frames.map(&:first)
      intervals = times.each_cons(2).map { |a, b| b - a }
      shape = %w[bytes esc cup sgr cells].each_with_index.to_h { |k, i| [k, UI::Perf.stats(frames.map { |f| f[i + 1].to_f }, ms: false)] }
      hit = ->(f, r) { f[6].any? { |y, x0, x1| y >= r.y && y < r.y + r.h && x1 >= r.x && x0 < r.x + r.w } }
      panes = rects.to_h do |name, r|
        hits = frames.select { |f| hit.(f, r) }.map(&:first)
        gaps = hits.each_cons(2).map { |a, b| b - a }
        span = times.empty? ? 1.0 : [times.last - times.first, 1e-6].max
        [name, stats(gaps).merge(visible_per_s: (hits.length / span).round(1))]
      end
      # Key to visible: a typed key's send to the first frame changing a
      # cell of the panes it acts on (the terminal's end of key-to-frame;
      # a key whose change never shows before the next key is "unseen")
      kr = key_panes.filter_map { |n| rects[n] }
      sent = (data['keys_sent'] || []).select { |t| t >= t_from }
      lat = []
      unseen = 0
      unless kr.empty?
        sent.each_with_index do |t, i|
          limit = [sent[i + 1] || Float::INFINITY, t + 1.0].min
          f = frames.find { |fr| fr[0] >= t && fr[0] < limit && kr.any? { |r| hit.(fr, r) } }
          f ? lat << f[0] - t : unseen += 1
        end
      end
      # (which panes the frames right after keys change, counted: where a
      # key's effect shows)
      after = Hash.new(0)
      sent.each_with_index do |t, i|
        limit = [sent[i + 1] || Float::INFINITY, t + 0.2].min
        frames.select { |fr| fr[0] >= t && fr[0] < limit }.each do |fr|
          rects.each { |n, r| after[n] += 1 if hit.(fr, r) }
        end
      end
      { frames: frames.length, intervals_ms: stats(intervals), shape: shape, panes: panes, replies: data['replies'], cpu_s: data['cpu'].round(3),
        key_to_visible: stats(lat).merge(unseen: unseen, panes: key_panes, each_ms: lat.map { |v| (v * 1000).round(1) }), changed_after_keys: after }
    end

    # --alloc: every object the process allocates for +seconds+ (GC off,
    # ObjectSpace.trace_object_allocations: a TracePoint, fine in this
    # diagnostic, never in lib/), from ObjectSpace.dump_all (imemos
    # included), by site and by file: the first seconds of the recording,
    # whose timing numbers then include the cost.
    def self.alloc_map(seconds)
      require 'objspace'
      root = File.expand_path('..', __dir__) + '/'
      GC.start
      GC.disable
      gen = GC.count
      a0 = GC.stat(:total_allocated_objects)
      ObjectSpace.trace_object_allocations { sleep seconds }
      total = GC.stat(:total_allocated_objects) - a0
      sites = Hash.new(0)
      Dir.mktmpdir('ui_bench_alloc') do |dir|
        path = File.join(dir, 'dump.json')
        File.open(path, 'w') { |f| ObjectSpace.dump_all(output: f, since: gen) }
        File.foreach(path) do |l|
          o = JSON.parse(l) rescue next
          type = o['type'] == 'IMEMO' ? "imemo_#{o['imemo_type']}" : o['type']
          file = o['file'] ? o['file'].sub(root, '').sub(%r{\A.*/gems/}, 'gem ') : '(no site)'
          sites["#{file}:#{o['line']} #{type}"] += 1
        end
      end
      files = Hash.new(0)
      sites.each { |k, v| files[k.sub(/:\d* \S+\z/, '')] += v }
      per_s = ->(h) { h.sort_by { -_2 }.first(25).map { |k, v| [k, (v / seconds).round] } }
      { seconds: seconds, objects_per_s: (total / seconds).round, sites: per_s.(sites), files: per_s.(files) }
    ensure
      ObjectSpace.trace_object_allocations_clear
      GC.enable
    end

    # The panes a scenario's keys act on (for the sink's key-to-visible).
    KEY_PANES = { design: %i[inspector], typing: %i[repl] }.freeze
  end

  if main_script?(__FILE__)
    MB::Sound.script(
      scenarios: ['tiles', "Scenarios, comma-separated: #{UIBench::SCENARIOS.join(', ')}", '-S', String],
      seconds: [10.0, 'Seconds recorded per scenario (after --warm)', '-s', 0.5..600.0],
      warm: [2.0, 'Seconds the screen runs before recording', 0.0..60.0],
      size: ['40x140', 'Terminal size (ROWSxCOLS)', String],
      sink: [:unlimited, "Sink: #{UIBench::SINKS.keys.join(', ')}", Symbol],
      bps: [nil, 'Sink bytes per second (throttle)', Integer],
      esc_us: [nil, 'Sink parse cost per escape sequence (microseconds)', Float],
      cell_us: [nil, 'Sink parse cost per cell (microseconds)', Float],
      frame_us: [nil, 'Sink parse cost per frame (microseconds)', Float],
      latency: [nil, 'Latency profile: default, low, video, safe', '-L', Symbol],
      look: [:auto, 'Plot look for the scope panes and the standalone plot', Symbol],
      fps: [60, 'Target frame rate', Integer],
      json: [nil, 'Write every result as JSON to this file', '-j', String],
      screen: [nil, 'Write the sink\'s last frame as text to this file (one scenario)', String],
      sink_cpus: [nil, 'Pin the sink process to these CPUs (taskset list, e.g. 30,31)', String],
      buffer: [nil, 'Render buffer size in frames for the null output (default 800; 128, 256, ...)', Integer],
      design_line: [nil, 'design: the console line that opens the sound-design screen (default: the acid bass)', String],
      key_rate: [nil, 'design: knob turns per second by arrow keys (default 8.3; 0 for none, e.g. an LFO patch held)', Float],
      out_latency: [nil, 'Output latency the null output reports, in buffers (a device\'s queue: meters and scopes show what is heard)', Float],
      smooth: [false, 'ui.smooth :on: every-buffer snapshots, snapshot-timed frames, and echo wake (off by default)'],
      live_waves: [false, 'ui.waves :live (MB_SOUND_UI_WAVES=live, passed to each scenario)'],
      every_buffer: [false, 'Snapshots at every render buffer the painter took the last one in (UI::Feed.every_buffer; an option)'],
      echo_wake: [false, 'The REPL\'s echo wakes the painter once after each key (UI::Tiles.echo_wake; an option)'],
      snapshot_timed: [false, 'Frames timed to the render thread\'s snapshots (UI::FrameRate.snapshot_timed; an option)'],
      file_watch: [false, 'Record file system calls from the screen\'s threads (UI::FileWatch)'],
      gc_off: [false, 'Diagnosis: GC disabled while recording (what the garbage collector costs the waits; memory grows)'],
      late: [false, 'With --holders: which calls hand the GVL to the render thread late (FastUI::GVLYield.late_log), and the render waits over 2 ms that overlap a GC step'],
      alloc: [0.0, 'Trace the first this many seconds of the recording: allocation sites by file and site, per second (GC off and traced: the timing numbers include the cost)', 0.0..30.0],
      holders: [false,'Name who holds the GVL while the render thread waits (FastUI::GVLProbe on the render thread, the painter, and worker threads)'],
      quiet_header: [false, 'Skip the header line (one scenario of a multi-scenario run)'],
    ) { |_args, p|
      ENV['AUDIO_PROFILE'] = p.latency.to_s if p.latency
      UI::Feed.every_buffer = UI::FrameRate.snapshot_timed = UI::Tiles.echo_wake = true if p.smooth
      if p.live_waves
        ENV['MB_SOUND_UI_WAVES'] = 'live'
        UI::WaveView.mode = :live
      end
      UI::Feed.every_buffer = true if p.every_buffer
      UI::FrameRate.snapshot_timed = true if p.snapshot_timed
      UI::Tiles.echo_wake = true if p.echo_wake
      rows, cols = p.size.split('x').map(&:to_i)
      scenarios = p.scenarios.split(',').map { |s| s.strip.to_sym }
      bad = scenarios - UIBench::SCENARIOS
      raise ArgumentError, "Unknown scenario #{bad.map(&:inspect).join(', ')} (#{UIBench::SCENARIOS.join(', ')})" unless bad.empty?
      kind = p.sink
      raise ArgumentError, "Unknown sink #{kind.inspect} (#{UIBench::SINKS.keys.join(', ')})" unless UIBench::SINKS.key?(kind)
      cfg = UIBench::SINKS[kind].merge({ bps: p.bps, esc_us: p.esc_us, cell_us: p.cell_us, frame_us: p.frame_us }.compact).merge(kind: kind)
      machine = UI::Perf.machine
      puts "ui_bench: #{machine[:host_cpu]} (#{machine[:cores]} cores#{machine[:container] ? ', container' : ''}), Ruby #{machine[:ruby]}#{machine[:yjit] ? ' YJIT' : ''}; " \
           "sink #{kind} #{cfg.except(:kind).map { |k, v| "#{k}=#{v.inspect}" }.join(' ')}; #{rows}x#{cols}; harness numbers" unless p.quiet_header

      # More than one scenario: each in a process of its own (a fresh
      # Session; the song's set can't load twice into one), merged here
      if scenarios.length > 1
        results = []
        tmp = Dir.mktmpdir('ui_bench')
        scenarios.each do |sc|
          part = File.join(tmp, "#{sc}.json")
          # (the options parsed, passed on: ARGV is consumed by now)
          args = ['-s', p.seconds.to_s, '--warm', p.warm.to_s, '--size', p.size, '--sink', kind.to_s, '--look', p.look.to_s, '--fps', p.fps.to_s]
          { bps: '--bps', esc_us: '--esc-us', cell_us: '--cell-us', frame_us: '--frame-us', latency: '-L', sink_cpus: '--sink-cpus', buffer: '--buffer', out_latency: '--out-latency', design_line: '--design-line', key_rate: '--key-rate', alloc: '--alloc' }.each do |k, flag|
            v = p.public_send(k)
            args.push(flag, v.to_s) unless v.nil?
          end
          args << '--smooth' if p.smooth
          args << '--every-buffer' if p.every_buffer
          args << '--snapshot-timed' if p.snapshot_timed
          args << '--echo-wake' if p.echo_wake
          args << '--file-watch' if p.file_watch
          args << '--holders' if p.holders
          args << '--late' if p.late
          args << '--gc-off' if p.gc_off
          ok = system(RbConfig.ruby, __FILE__, *args, '-S', sc.to_s, '-j', part, '--quiet-header')
          raise "ui_bench: scenario #{sc} failed (#{$?.inspect})" unless ok
          results.concat(JSON.parse(File.read(part)))
        end
        File.write(p.json, JSON.pretty_generate(results)) if p.json
        puts "\nJSON: #{p.json}" if p.json
        FileUtils.rm_rf(tmp)
        next
      end

      MB::Sound.warm_up
      UI.warm_up
      UI.warm_up_console
      if p.buffer || p.out_latency
        # (a null output of the asked size, optionally reporting a device's
        # latency, before the scenario starts the song)
        out = NullOutput.new(channels: 2, buffer_size: p.buffer || 800)
        lat = p.out_latency.to_f * out.buffer_size / 48000.0
        out.define_singleton_method(:latency) { lat } if p.out_latency
        Session.use_output(out)
      end
      warm = p.warm
      results = []
      tmp = Dir.mktmpdir('ui_bench')

      scenarios.each do |sc|
        session = nil
        knob = nil # (design: the knob the arrows turn)
        master, slave = PTY.open
        slave.winsize = [rows, cols]
        t0 = UIBench.now
        sink_out = File.join(tmp, "sink_#{sc}.json")
        keys = UIBench.keys_for(sc, warm, p.seconds, key_rate: p.key_rate)
        pid = fork do
          slave.close
          UIBench.sink(master, rows, cols, cfg, keys, sink_out, t0)
          exit!(0)
        end
        system('taskset', '-cp', p.sink_cpus, pid.to_s, out: File::NULL) if p.sink_cpus
        master.close

        if sc == :design
          session = Session.current
        else
          MB::Sound.last_stop(perform: true, seed: 1)
          session = Session.current
          Thread.pass until session.running?
        end

        screen = nil
        screen_epoch = nil
        plot_thread = nil
        stop_plot = false
        case sc
        when :band
          screen = UI::Band.new(layout: UI.layout_named(:band), io: slave, at: :top, look: p.look == :auto ? :quad : p.look, size: [rows, cols], fps: p.fps)
        when :plot
          # The standalone live plot (ui-2's path): Plot::Live#write of a
          # scope chart from the newest snapshot, at the target rate, the
          # bytes written by the C grid without the GVL
          feed = UI::Feed.new
          feed.needs = [:scope]
          session.ui_feed = feed
          w = cols
          h = rows
          scope = UI::Panes::Scope.new
          live = Plot::Live.new(width: w, height: h, look: p.look == :auto ? UI::Panes::Scope.auto_look(w, h) : p.look)
          pacer = UI::Pacer.new(p.fps, clock: -> { UIBench.now })
          last = nil
          scope_last = nil
          plot_thread = Thread.new do
            Thread.current.name = 'MB::Sound::UI'
            Thread.current.priority = -1
            pacer.run(-> { stop_plot }) do |_now|
              snap = feed.take || last
              last = snap
              data = snap&.scope
              data = [Numo::SFloat.zeros(256)] if data.nil? || data.empty?
              t = UIBench.now
              live.write(slave, scope.send(:chart, data, 48000), row: 1, col: 1, sync: true)
              t1 = UIBench.now
              pacer.note_write(t1 - t)
              if (pf = pacer.perf)
                pf.painted(1, false, false, 1) # (a frame written; its bytes are counted by the sink: the C grid writes them)
                pf.wrote(t, t1)
                pf.pane_drew(:scope, t1, scope_last)
              end
              scope_last = t1
              nil
            end
          end
        else
          layout = sc == :design ? :sound : :tiles
          screen = UI::Tiles.new(layout: UI.tiles_layout_named(layout), input: slave, output: slave, repl: :thread, look: p.look, fps: p.fps, probe: true)
        end

        if screen
          screen.start
          screen_epoch = Time.now.to_f # (for matching --yjit-log stamps: the screen's first seconds compile)
          UI.instance_variable_set(screen.is_a?(UI::Tiles) ? :@tiles : :@band, screen)
        end
        if sc == :design
          MB::Sound.module_eval(p.design_line || "design :bass, L.inst.acid, seq(E1, E1, G1, A1).n8.loop.legato(0.5)")
          Thread.pass until session.running?
          # A knob row picked before the sink's arrows start (on the Mac
          # two fixed Downs came before the inspector had its first
          # snapshot, and the arrows turned nothing; 2026-11-16)
          until (knob = UI::Perf::Capture.pick_knob(screen)) || UIBench.now - t0 > warm
            sleep 0.05
          end
          warn "ui_bench: design found no knob row in the inspector before the keys (its key times show no change)" unless knob
        end
        sleep [warm - (UIBench.now - t0), 0.0].max
        if sc == :flood
          screen.host.write("40000.times { |i| pry_instance.output.puts \"flood line \#{i} \#{'=' * 60}\" }; :flood_done\r")
        end

        load0 = UI::Perf.loadavg
        named = -> { { painter: screen&.thread || plot_thread, render: session.render_thread } }
        d0 = UI::Perf.run_delays(named.call)
        wall0 = UIBench.now
        rec_epoch = Time.now.to_f
        cpu0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
        gc0 = GC.stat.slice(:total_allocated_objects, :count, :minor_gc_count, :major_gc_count, :time) # (the whole process's garbage while recording)
        yjit0 = UIBench.yjit_stats
        the_feed = screen ? screen.feed : feed
        pub0 = the_feed.published
        bufs = 0
        tap = session.add_tap { |_| bufs += 1 }
        holders = nil
        blog = nil
        yield0 = nil
        if p.holders
          # Who holds the GVL while the render thread waits: the probe on
          # the render thread, the painter, and the worker threads by name
          # (the input thread, the REPL's Pry thread, then PatchRender's and
          # the previews' renders, the scheduler, the poll), at most 6;
          # ui.perf then leaves the probe alone
          th = { render: session.render_thread, painter: screen&.thread || plot_thread }
          if screen.is_a?(UI::Tiles)
            th[:input] = screen.instance_variable_get(:@reader)
            th[:repl] = screen.host&.thread
          end
          th.compact!
          Thread.list.each do |t|
            break if th.length >= 6
            n = t.name.to_s
            next if th.value?(t) || n.empty?
            th[n.sub(/\Amb-sound /i, '').tr(' ', '_').to_sym] = t if n.match?(/render|scheduler|poll|preview|worker/i) && !n.match?(/\AMB::Sound::Session render/)
          end
          FastUI::GVLProbe.start(th.values)
          holders = th.keys
          blog = UIBench::BufferLog.new(session.output, session)
          blog.start
          if p.late
            FastUI::GVLProbe.log_start(0.002, 0.0005)
            FastUI::GVLYield.late_log(true)
            yield0 = FastUI::GVLYield.stats
          end
        end
        GC.disable if p.gc_off
        if screen
          perf = screen.start_perf
        else
          perf = UI::Perf.new(ack: nil, label: 'plot (standalone)')
          pacer.perf = perf
          perf.start_probe(render: session.render_thread, painter: plot_thread)
        end
        if p.file_watch
          # File system calls from the screen's own threads (the painter,
          # input, the pty reader; the REPL's Pry thread is the console's)
          watched = [screen&.thread || plot_thread, screen.is_a?(UI::Tiles) ? screen.instance_variable_get(:@reader) : nil, screen.respond_to?(:pty_thread) ? screen.pty_thread : nil].compact
          UI::FileWatch.start(watched)
        end
        alloc_map = nil
        if p.alloc > 0
          # (the first seconds of the recording traced: the keys and the
          # song still running; the timing numbers then include the cost)
          a = [p.alloc, p.seconds].min
          alloc_map = UIBench.alloc_map(a)
          sleep p.seconds - a
        else
          sleep p.seconds
        end
        blog&.stop
        file_calls = p.file_watch ? UI::FileWatch.stop : nil
        screen ? screen.stop_perf : perf.stop
        GC.enable if p.gc_off
        wall = UIBench.now - wall0
        holder_table = nil
        if holders
          # Per watched thread: its GVL holds (total, longest, over 2 ms), and
          # the render thread's waits of 1 ms or more by who held the GVL
          by = Hash.new { |h, k| h[k] = [0, 0.0, 0.0] }
          FastUI::GVLProbe.blockers(0).each do |w, slot|
            who = slot < 0 ? :other : holders[slot]
            e = by[who]
            e[0] += 1
            e[1] += w
            e[2] = w if w > e[2]
          end
          waits = FastUI::GVLProbe.waits(0)
          late = p.late ? UIBench.late_report(holders, FastUI::GVLYield.late_log(false), FastUI::GVLProbe.log_drain) : nil
          late&.merge!(priority: [FastUI::GVLYield.priority&.name, FastUI::GVLYield.priority.equal?(session.render_thread)], yielders: FastUI::GVLYield.yielders.map { |t| t.name.to_s }, yield_stats: FastUI::GVLYield.stats.to_h { |k, v| [k, v - yield0.fetch(k, 0)] })
          FastUI::GVLProbe.log_stop if p.late
          holder_table = {
            render_waits: { n: waits.length, over_1ms: waits.count { |w| w >= 0.001 }, over_2ms: waits.count { |w| w > 0.002 }, max_ms: ((waits.max || 0) * 1000).round(2) },
            blockers: by.to_h { |k, (n, tot, mx)| [k, { waits_over_1ms: n, wait_ms_total: (tot * 1000).round(1), longest_wait_ms: (mx * 1000).round(2) }] },
            late: late,
            holds: holders.each_with_index.to_h { |n, i|
              h = FastUI::GVLProbe.holds(i)
              [n, { total_ms: (h.sum * 1000).round(1), longest_ms: ((h.max || 0) * 1000).round(2), over_2ms: h.count { |x| x > 0.002 }, n: h.length }]
            },
            buffers: blog.report(session.buffer_size.to_f / session.output.sample_rate, wall0),
          }
          FastUI::GVLProbe.stop
        end
        published = the_feed.published - pub0
        session.remove_tap(tap) rescue nil
        cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu0
        gc1 = GC.stat.slice(*gc0.keys)
        garbage = {
          objects_per_s: ((gc1[:total_allocated_objects] - gc0[:total_allocated_objects]) / wall).round,
          gc_per_min: ((gc1[:count] - gc0[:count]) * 60 / wall).round(1),
          minor: gc1[:minor_gc_count] - gc0[:minor_gc_count], major: gc1[:major_gc_count] - gc0[:major_gc_count],
          gc_ms_per_min: ((gc1[:time] - gc0[:time]) * 60 / wall).round(1),
        }
        yjit = yjit0 && UIBench.yjit_stats.to_h { |k, v| [k, v - yjit0[k]] }
        d1 = UI::Perf.run_delays(named.call)
        load1 = UI::Perf.loadavg
        rects = screen.is_a?(UI::Tiles) ? screen.tiler.rects.to_h { |n, r| [n, r] } : (screen ? {} : { scope: Struct.new(:x, :y, :w, :h).new(0, 0, cols, rows) })
        if screen.is_a?(UI::Band)
          rects = { band: Struct.new(:x, :y, :w, :h).new(0, 0, cols, screen.height) }
        end


        stop_plot = true
        plot_thread&.join(2)
        screen&.stop
        UI.instance_variable_set(:@tiles, nil)
        UI.instance_variable_set(:@band, nil)
        UI::Design.close rescue nil if sc == :design
        session.ui_feed = nil if sc == :plot
        MB::Sound.stop(:all, fade: 0)
        slave.close
        Process.wait(pid)
        sink = JSON.parse(File.read(sink_out))
        File.write(p.screen, (sink['screen'] || []).join("\n") + "\n") if p.screen
        s = perf.summary
        # (ms; a counter that moved by more than the wall time, or back, is
        # left out as nil: no thread waits longer than it ran)
        delay = d0.to_h { |k, v| [k, v && d1[k] && (d = (d1[k] - v) * 1000) >= 0 && d <= wall * 1000 ? d.round(1) : nil] }
        row = {
          scenario: sc, knob: knob, ui_waves: ENV['MB_SOUND_UI_WAVES'], holders: holder_table, every_buffer: UI::Feed.every_buffer, snapshot_timed: UI::FrameRate.snapshot_timed, echo_wake: UI::Tiles.echo_wake, out_latency: p.out_latency, sink: cfg, size: [rows, cols], buffer: session.buffer_size, seconds: p.seconds, loadavg: [load0, load1],
          yjit: yjit,
          garbage: garbage, alloc_map: alloc_map,
          run_delay_ms: delay, clean: %i[painter render].all? { |k| delay[k] && delay[k] < wall * 1000 * 0.01 }, cpu_s: cpu.round(2), wall_s: wall.round(2),
          snapshots_per_s: (published / wall).round(1), buffers_per_s: (bufs / wall).round(1),
          file_calls: file_calls && file_calls.map { |m, path, loc, th| [m, path, loc, th] },
          perf: s, sink_report: UIBench.sink_report(sink, rects, warm, key_panes: UIBench::KEY_PANES[sc] || []), machine: machine,
          pane_cpu_ms: screen.is_a?(UI::Tiles) ? screen.stats[:pane_cpu_ms] : nil, # (each pane's draws, the last 200)
        }
        results << row

        a = s[:audio] || {}
        r = a[:render] || {}
        sr = row[:sink_report]
        puts
        puts "== #{sc} (#{kind} sink, #{session.buffer_size}-frame buffers#{UI::Feed.every_buffer ? ', every-buffer snapshots' : ''}#{UI::FrameRate.snapshot_timed ? ', snapshot-timed' : ''}#{UI::Tiles.echo_wake ? ', echo wake' : ''}#{p.out_latency ? ", output latency #{p.out_latency} buffers" : ''}#{knob ? ", turning #{knob.inspect}" : ''}#{ENV['MB_SOUND_UI_WAVES'] ? ", MB_SOUND_UI_WAVES=#{ENV['MB_SOUND_UI_WAVES']}" : ''}): load #{load0&.first}->#{load1&.first}, run delay ms #{delay.map { |k, v| "#{k} #{v}" }.join(' ')} (#{row[:clean] ? 'clean' : 'contended'}), CPU #{row[:cpu_s]} s of #{row[:wall_s]} s"
        puts format('  clocks: screen started at %.6f, recording from %.6f (%.1f s after the screen; epoch seconds, as --yjit-log stamps)', screen_epoch, rec_epoch, rec_epoch - screen_epoch) if screen_epoch
        perf.headline(s).each { |l| puts "  #{l}" }
        puts "  feed: #{row[:snapshots_per_s]} snapshots/s published, #{row[:buffers_per_s]} render buffers/s"
        puts "  garbage (whole process): #{garbage[:objects_per_s]} objects/s, GC #{garbage[:gc_per_min]}/min (#{garbage[:minor]} minor, #{garbage[:major]} major), GC time #{garbage[:gc_ms_per_min]} ms/min"
        puts "  YJIT while recording: #{yjit[:compiled_block_count]} blocks compiled in #{(yjit[:compile_time_ns] / 1e6).round(1)} ms, #{yjit[:invalidation_count]} invalidations (#{yjit.select { |k, v| k.start_with?('invalidate_') && v.to_i > 0 }.map { |k, v| "#{k.to_s.delete_prefix('invalidate_')} #{v}" }.join(', ')}), #{yjit[:code_gc_count]} code GCs" if yjit
        puts "  frames: #{s[:refreshes_per_s]}/s refreshed, #{s[:written_per_s]}/s written; lateness p50/p99/max #{s[:late_ms].values_at(:p50, :p99, :max).join('/')} ms; " \
             "write p99/max #{s[:write_ms].values_at(:p99, :max).join('/')} ms (#{s[:writes_over_2ms]} over 2 ms); bytes p50/p95/max #{s[:bytes_per_written].values_at(:p50, :p95, :max).join('/')}; full #{s[:full_redraws]}; GC #{s[:gc][:runs]} (max #{s[:gc][:max_ms]} ms)"
        puts "  sink: #{sr[:frames]} frames, intervals p50/p95/p99/max #{sr[:intervals_ms].values_at(:p50, :p95, :p99, :max).join('/')} ms; per frame: " +
             %w[bytes esc cup sgr cells].map { |k| "#{k} #{sr[:shape][k].values_at(:p50, :max).join('/')}" }.join(', ') + " (p50/max); answers #{s[:acks][:from_write_end_ms].values_at(:p50, :p95, :max).join('/')} ms after the write"
        sr[:panes].sort_by { |_, v| -(v[:max] || 0) }.each do |name, v|
          pa = s[:panes][name] || {}
          pc = (row[:pane_cpu_ms] || {})[name] || {}
          puts format('  %-12s visible %5.1f/s, visible gaps p50/p95/max %s/%s/%s ms; painter draws %s/s, age p95/max %s/%s ms; draw CPU p50/p99/max %s/%s/%s ms',
                      name, v[:visible_per_s], v[:p50] || '-', v[:p95] || '-', v[:max] || '-', pa[:rate] || '-', pa[:p95] || '-', pa[:max] || '-',
                      pc[:p50] || '-', pc[:p99] || '-', pc[:max] || '-')
        end
        if file_calls
          puts "  file calls from the screen's threads: #{file_calls.length}#{file_calls.empty? ? '' : " (#{(file_calls.length / wall).round(1)}/s)"}"
          file_calls.group_by { |m, _, loc, th| [m, loc, th] }.sort_by { |_, v| -v.length }.first(12).each do |(m, loc, th), v|
            puts format('    %5d  %-8s %-40s %s  e.g. %s', v.length, m, loc, th, v[0][1].to_s[-60..] || v[0][1])
          end
        end
        puts "  keys: #{s[:keys].values_at(:n, :p50, :p95, :max).then { |n, *q| n.to_i > 0 ? "#{n} keys, p50/p95/max #{q.join('/')} ms" : 'none' }}"
        if (ht = row[:holders])
          rw = ht[:render_waits]
          puts "  GVL holders (render waits #{rw[:n]}, #{rw[:over_1ms]} of 1 ms or more, #{rw[:over_2ms]} over 2 ms, max #{rw[:max_ms]} ms):"
          ht[:holds].each do |n, h|
            b = ht[:blockers][n] || {}
            puts format('    %-22s holds %7.1f ms total, longest %6.2f ms, %3d over 2 ms; held the GVL in %3d render waits >= 1 ms (%6.1f ms, longest %5.2f)',
                        n, h[:total_ms], h[:longest_ms], h[:over_2ms], b[:waits_over_1ms] || 0, b[:wait_ms_total] || 0, b[:longest_wait_ms] || 0)
          end
          if (lt = ht[:late])
            puts "  priority #{lt[:priority].inspect}; yielders: #{lt[:yielders].join(', ')}; #{lt[:yield_stats].map { |k, v| "#{k} #{v}" }.join(', ')}"
            puts "  late handovers (more than 1 ms after the kick): #{lt[:n]}, #{lt[:over_gc]} overlapping a GC step; render waits over 2 ms: #{lt[:waits]}, #{lt[:waits_gc]} overlapping a GC step (#{lt[:gc_steps]} GC steps over 0.5 ms)"
            lt[:sites].first(10).each { |s| puts format('    %4d late, %7.1f ms, longest %5.2f ms  %-8s %s', s[:n], s[:ms], s[:max_ms], s[:thread], s[:at]) }
          end
          if (bf = ht[:buffers])
            rm = bf[:render_ms]
            puts "  render buffers: #{bf[:n]}, period #{bf[:period_ms]} ms; render p50/p95/p99/max #{rm.values_at(:p50, :p95, :p99, :max).join('/')} ms; over the period #{bf[:over_period]} (#{bf[:over_per_min]}/min), over half #{bf[:over_half]}; writes that did not wait #{bf[:no_wait_writes]}; YJIT #{bf[:render_jit_ms]} ms in renders, #{bf[:write_jit_ms]} ms while the render thread waited; GC #{bf[:render_gc_ms]} ms in renders"
            g = bf[:gc_steps]
            puts "  GC steps on the render thread: #{g[:render]} (#{g[:render_per_min]}/min, #{g[:render_majors]} major), #{g[:render_ms]} ms, longest #{g[:render_max_ms]} ms; elsewhere while it waited: #{g[:elsewhere]} (#{g[:elsewhere_ms]} ms)"
            g[:list].sort_by { -_1[:gc_ms] }.first(3).each { |x| puts format('    GC in buffer %5d at %6.2f s (bar %s): %5.2f ms of a %5.2f ms render%s', x[:i], x[:at_s], x[:bar].inspect, x[:gc_ms], x[:render_ms], x[:majors] > 0 ? ', major' : '') }
            bf[:worst].first(5).each { |x| puts format('    buffer %5d at %6.2f s (bar %s, from %s): render %6.2f ms (YJIT %5.2f ms %4d blocks, %d invalidations, %d during the wait before; GC %5.2f ms %d steps), write %5.2f ms', x[:i], x[:at_s], x[:bar].inspect, x[:wall], x[:render_ms], x[:jit_ms], x[:blocks], x[:inv], x[:inv_before], x[:gc_ms], x[:gcs], x[:write_ms]) }
          end
          if (o = ht[:blockers][:other])
            puts format('    %-22s (GC, unwatched threads) held the GVL in %3d render waits >= 1 ms (%6.1f ms, longest %5.2f)', 'other', o[:waits_over_1ms], o[:wait_ms_total], o[:longest_wait_ms])
          end
        end
        if (am = row[:alloc_map])
          puts "  allocations over the recording's first #{am[:seconds]} s (traced, so slower): #{am[:objects_per_s]} objects/s; by file:"
          am[:files].first(15).each { |f, n| puts format('    %7d/s  %s', n, f) }
          puts '  by site:'
          am[:sites].first(20).each { |f, n| puts format('    %7d/s  %s', n, f) }
        end
        kv = sr[:key_to_visible]
        puts "  key to visible (#{kv[:panes].join(', ')} at the sink): #{kv[:n]} keys, p50/p95/max #{kv.values_at(:p50, :p95, :max).join('/')} ms, #{kv[:unseen]} unseen" unless kv[:panes].empty?
        puts "  render wake delay p50/p99/p99.9/max #{r.values_at(:p50, :p99, :p999, :max).join('/')} ms, >2 ms #{r[:over_2ms_per_min]}/min; painter GVL waits p99/max #{(a[:painter] || {}).values_at(:p99, :max).join('/')} ms" if r[:n].to_i > 0
      end

      File.write(p.json, JSON.pretty_generate(results)) if p.json
      puts "\nJSON: #{p.json}" if p.json && !p.quiet_header
      FileUtils.rm_rf(tmp)
    }
  end
end
