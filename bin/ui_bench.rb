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
      File.write(out, JSON.generate({ frames: frames, keys_sent: sent, replies: replies,
                                      cpu: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu0 }))
    end

    # Keys the sink types for +scenario+: [[seconds from the start, bytes]].
    def keys_for(scenario, warm, seconds)
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
        t = warm + 0.3
        list = []
        k = 0
        while t < warm + seconds
          list << [t, (k / 8).even? ? "\e[C" : "\e[D"]
          t += 0.12
          k += 1
        end
        list
      else
        []
      end
    end

    # Percentiles of +v+ in ms.
    def stats(v) = UI::Perf.stats(v)

    # The sink's findings for the screen's +rects+ ({name => Rect}).
    def sink_report(data, rects, t_from)
      frames = data['frames'].select { |f| f[0] >= t_from }
      times = frames.map(&:first)
      intervals = times.each_cons(2).map { |a, b| b - a }
      shape = %w[bytes esc cup sgr cells].each_with_index.to_h { |k, i| [k, UI::Perf.stats(frames.map { |f| f[i + 1].to_f }, ms: false)] }
      panes = rects.to_h do |name, r|
        hits = frames.select { |f| f[6].any? { |y, x0, x1| y >= r.y && y < r.y + r.h && x1 >= r.x && x0 < r.x + r.w } }.map(&:first)
        gaps = hits.each_cons(2).map { |a, b| b - a }
        span = times.empty? ? 1.0 : [times.last - times.first, 1e-6].max
        [name, stats(gaps).merge(visible_per_s: (hits.length / span).round(1))]
      end
      { frames: frames.length, intervals_ms: stats(intervals), shape: shape, panes: panes, replies: data['replies'], cpu_s: data['cpu'].round(3) }
    end
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
      sink_cpus: [nil, 'Pin the sink process to these CPUs (taskset list, e.g. 30,31)', String],
      every_buffer: [false, 'Snapshots at every render buffer the painter took the last one in (UI::Feed.every_buffer; an option)'],
      deadlines: [false, 'Panes due by the painter\'s frame deadlines (UI::PaneRates.on_deadlines; an option)'],
      file_watch: [false, 'Record file system calls from the screen\'s threads (UI::FileWatch)'],
      quiet_header: [false, 'Skip the header line (one scenario of a multi-scenario run)'],
    ) { |_args, p|
      ENV['AUDIO_PROFILE'] = p.latency.to_s if p.latency
      UI::Feed.every_buffer = true if p.every_buffer
      UI::PaneRates.on_deadlines = true if p.deadlines
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
          { bps: '--bps', esc_us: '--esc-us', cell_us: '--cell-us', frame_us: '--frame-us', latency: '-L', sink_cpus: '--sink-cpus' }.each do |k, flag|
            v = p.public_send(k)
            args.push(flag, v.to_s) unless v.nil?
          end
          args << '--every-buffer' if p.every_buffer
          args << '--deadlines' if p.deadlines
          args << '--file-watch' if p.file_watch
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
      warm = p.warm
      results = []
      tmp = Dir.mktmpdir('ui_bench')

      scenarios.each do |sc|
        session = nil
        master, slave = PTY.open
        slave.winsize = [rows, cols]
        t0 = UIBench.now
        sink_out = File.join(tmp, "sink_#{sc}.json")
        keys = UIBench.keys_for(sc, warm, p.seconds)
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
          UI.instance_variable_set(screen.is_a?(UI::Tiles) ? :@tiles : :@band, screen)
        end
        if sc == :design
          MB::Sound.module_eval("design :bass, L.inst.acid, seq(E1, E1, G1, A1).n8.loop.legato(0.5)")
          Thread.pass until session.running?
        end
        sleep warm
        if sc == :flood
          screen.host.write("40000.times { |i| pry_instance.output.puts \"flood line \#{i} \#{'=' * 60}\" }; :flood_done\r")
        end

        load0 = UI::Perf.loadavg
        named = -> { { painter: screen&.thread || plot_thread, render: session.render_thread } }
        d0 = UI::Perf.run_delays(named.call)
        wall0 = UIBench.now
        cpu0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
        the_feed = screen ? screen.feed : feed
        pub0 = the_feed.published
        bufs = 0
        tap = session.add_tap { |_| bufs += 1 }
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
        sleep p.seconds
        file_calls = p.file_watch ? UI::FileWatch.stop : nil
        screen ? screen.stop_perf : perf.stop
        wall = UIBench.now - wall0
        published = the_feed.published - pub0
        session.remove_tap(tap) rescue nil
        cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu0
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
        s = perf.summary
        delay = d0.to_h { |k, v| [k, v && d1[k] ? ((d1[k] - v) * 1000).round(1) : nil] }
        row = {
          scenario: sc, every_buffer: UI::Feed.every_buffer, deadlines: UI::PaneRates.on_deadlines, sink: cfg, size: [rows, cols], buffer: session.buffer_size, seconds: p.seconds, loadavg: [load0, load1],
          run_delay_ms: delay, clean: delay[:process] && delay[:process] < wall * 1000 * 0.01, cpu_s: cpu.round(2), wall_s: wall.round(2),
          snapshots_per_s: (published / wall).round(1), buffers_per_s: (bufs / wall).round(1),
          file_calls: file_calls && file_calls.map { |m, path, loc, th| [m, path, loc, th] },
          perf: s, sink_report: UIBench.sink_report(sink, rects, warm), machine: machine,
        }
        results << row

        a = s[:audio] || {}
        r = a[:render] || {}
        sr = row[:sink_report]
        puts
        puts "== #{sc} (#{kind} sink, #{session.buffer_size}-frame buffers#{UI::Feed.every_buffer ? ', every-buffer snapshots' : ''}#{UI::PaneRates.on_deadlines ? ', deadline due' : ''}): load #{load0&.first}->#{load1&.first}, run delay ms #{delay.map { |k, v| "#{k} #{v}" }.join(' ')} (#{row[:clean] ? 'clean' : 'contended'}), CPU #{row[:cpu_s]} s of #{row[:wall_s]} s"
        perf.headline(s).each { |l| puts "  #{l}" }
        puts "  feed: #{row[:snapshots_per_s]} snapshots/s published, #{row[:buffers_per_s]} render buffers/s"
        puts "  frames: #{s[:refreshes_per_s]}/s refreshed, #{s[:written_per_s]}/s written; lateness p50/p99/max #{s[:late_ms].values_at(:p50, :p99, :max).join('/')} ms; " \
             "write p99/max #{s[:write_ms].values_at(:p99, :max).join('/')} ms (#{s[:writes_over_2ms]} over 2 ms); bytes p50/p95/max #{s[:bytes_per_written].values_at(:p50, :p95, :max).join('/')}; full #{s[:full_redraws]}; GC #{s[:gc][:runs]} (max #{s[:gc][:max_ms]} ms)"
        puts "  sink: #{sr[:frames]} frames, intervals p50/p95/p99/max #{sr[:intervals_ms].values_at(:p50, :p95, :p99, :max).join('/')} ms; per frame: " +
             %w[bytes esc cup sgr cells].map { |k| "#{k} #{sr[:shape][k].values_at(:p50, :max).join('/')}" }.join(', ') + " (p50/max); answers #{s[:acks][:from_write_end_ms].values_at(:p50, :p95, :max).join('/')} ms after the write"
        sr[:panes].sort_by { |_, v| -(v[:max] || 0) }.each do |name, v|
          pa = s[:panes][name] || {}
          puts format('  %-12s visible %5.1f/s, visible gaps p50/p95/max %s/%s/%s ms; painter draws %s/s, age p95/max %s/%s ms',
                      name, v[:visible_per_s], v[:p50] || '-', v[:p95] || '-', v[:max] || '-', pa[:rate] || '-', pa[:p95] || '-', pa[:max] || '-')
        end
        if file_calls
          puts "  file calls from the screen's threads: #{file_calls.length}#{file_calls.empty? ? '' : " (#{(file_calls.length / wall).round(1)}/s)"}"
          file_calls.group_by { |m, _, loc, th| [m, loc, th] }.sort_by { |_, v| -v.length }.first(12).each do |(m, loc, th), v|
            puts format('    %5d  %-8s %-40s %s  e.g. %s', v.length, m, loc, th, v[0][1].to_s[-60..] || v[0][1])
          end
        end
        puts "  keys: #{s[:keys].values_at(:n, :p50, :p95, :max).then { |n, *q| n.to_i > 0 ? "#{n} keys, p50/p95/max #{q.join('/')} ms" : 'none' }}"
        puts "  render wake delay p50/p99/p99.9/max #{r.values_at(:p50, :p99, :p999, :max).join('/')} ms, >2 ms #{r[:over_2ms_per_min]}/min; painter GVL waits p99/max #{(a[:painter] || {}).values_at(:p99, :max).join('/')} ms" if r[:n].to_i > 0
      end

      File.write(p.json, JSON.pretty_generate(results)) if p.json
      puts "\nJSON: #{p.json}" if p.json && !p.quiet_header
      FileUtils.rm_rf(tmp)
    }
  end
end
