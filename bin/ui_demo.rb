#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Plays a demo song with the terminal UI's dashboard band on and measures its cost.
#
# The song is "Last Stop" (bin/songs/night_bus_flow.rb: a form with scenes,
# knobs, buses, and a master chain).  At the end it prints what the band cost
# the audio: the render thread's wake delay (how long it waited for the GVL
# each time it woke, from FastUI::GVLProbe, with which thread held it for the
# waits over 1 ms), the painter's GVL holds, CPU per refresh, and slowest
# refreshes, bytes per frame, GC runs, and underruns.
# See design/notes/terminal_ui.md.
#
# In iTerm2 or Konsole (natively on the Mac, or in the container):
#
#     bin/ui_demo.rb                        # 30 s with the default band
#     bin/ui_demo.rb -l deck -s 60          # the taller band with knobs and CPU
#     bin/ui_demo.rb --compare -s 60        # band on and off in turns: wake delay with vs without
#     bin/ui_demo.rb --no-ui                # the baseline alone
#     bin/ui_demo.rb --look scope           # Braille scope instead of quadrants
#     bin/ui_demo.rb --at bottom            # band under the scrolling text
#     bin/ui_demo.rb -L low                 # the :low latency profile (256-frame writes)
#     bin/ui_demo.rb --seek 41              # from the drop
#
# Expected: the band at the top shows bar:beat moving, the form's section
# and what comes next, tracks lighting up as scenes change, queued changes
# just before each section, master meters around -12..-6 dBFS peak, and a
# moving scope; the text below keeps scrolling (one line per second) under
# the band.  At the end, a table of wake delays: with the band, p99 should
# stay well under a millisecond (the spike measured 0.26 ms p99 at 60 fps on
# the Linux desktop) and underruns should match --no-ui.
#
# Without a terminal (CI, `| cat`) the band is drawn to /dev/null at
# --size, so the numbers are still measured.  --capture DIR writes the band
# as ANSI (.ans) and HTML once a second.

require 'bundler/setup'
require 'mb-sound'
require_relative 'songs/night_bus_flow'

module MB::Sound
  # Statistics line for wake delays or holds (seconds).
  def self.ui_demo_line(label, values)
    return "#{label.ljust(26)} (none)" if values.empty?
    v = values.sort
    q = ->(f) { format('%.3f', v[((v.length - 1) * f).round] * 1000) }
    over = values.count { |x| x > 0.002 }
    "#{label.ljust(26)} n=#{v.length.to_s.ljust(6)} p50 #{q.(0.5)}  p99 #{q.(0.99)}  p99.9 #{q.(0.999)}  max #{format('%.3f', v[-1] * 1000)} ms  >2 ms: #{over}"
  end

  if main_script?(__FILE__)
    MB::Sound.script(
      seconds: [30.0, 'Seconds to play', '-s', 1.0..3600.0],
      layout: [:band, 'Band layout: band, deck, mini, or a saved one', '-l'],
      ui: [true, 'Show the band (--no-ui measures the baseline)'],
      compare: [false, 'Turn the band on and off every 5 seconds and compare wake delays'],
      at: [:top, 'Band position', %i[top bottom]],
      look: [:quad, 'Scope look (quad, scope for Braille, blocks, ...)', Symbol],
      color: [:ansi256, 'Color mode', %i[ansi256 truecolor ansi16 none]],
      seek: [nil, 'Bar to start from (e.g. 41)', Integer],
      size: ['30x120', 'Band size when not on a terminal (ROWSxCOLS)', String],
      capture: [nil, 'Write ANSI and HTML captures of the band to this directory', String],
      latency: [nil, 'Latency profile: default, low, video, safe', '-L', Symbol],
      quiet: [false, 'Print only the summary', '-q'],
    ) { |_args, p|
      ENV['AUDIO_PROFILE'] = p.latency.to_s if p.latency
      tty = $stdout.tty?
      rows, cols = p.size.split('x').map(&:to_i)
      io = tty ? $stdout : File.open(File::NULL, 'w')

      MB::Sound.warm_up
      UI.warm_up
      MB::Sound.last_stop(perform: true, seed: 1)
      session = Session.current
      MB::Sound.seek(p.seek) if p.seek
      Thread.pass until session.running?
      out = session.output
      underruns = -> { out.respond_to?(:underruns) ? out.underruns : nil }

      band = UI::Band.new(layout: UI.layout_named(p.layout), io: io, at: p.at, look: p.look, color: p.color, size: tty ? nil : [rows, cols])
      UI.instance_variable_set(:@band, band) # (so Reline's guard and `now` see it)

      waits = { on: [], off: [] }
      holds = []
      blockers = { on: Hash.new(0), off: Hash.new(0) }
      gcs = { on: [0, 0.0], off: [0, 0.0] }
      xruns = { on: 0, off: 0 }
      loads = { on: [], off: [] }
      session.add_tap { |_| (band.active? ? loads[:on] : loads[:off]) << session.render_load if session.render_load }

      # Windows of band on/off (one window unless --compare)
      window = p.compare ? 5.0 : p.seconds
      start = MB::U.clock_now
      on = p.ui
      captured = 0
      while (elapsed = MB::U.clock_now - start) < p.seconds
        state = on ? :on : :off
        band.start if on && !band.active?
        band.stop if !on && band.active?
        scheduler = Thread.list.find { |th| th.name == 'MB::Sound::Session scheduler' }
        names = [:render, :painter, :scheduler, :main]
        threads = [session.render_thread, band.thread || Thread.current, scheduler || Thread.current, Thread.current]
        FastUI::GVLProbe.start(threads)
        x0 = underruns.call
        gc0 = [GC.count, GC.stat(:time)]
        stop_at = [start + elapsed + window, start + p.seconds].min
        t = MB::U.clock_now
        while (now = MB::U.clock_now) < stop_at
          sleep([1.0, stop_at - now].min)
          puts "#{format('%5.1f', now - start)} s  #{session.transport_record&.then { |r| Session::Stamp.at(r[:pos], session.transport).to_s }}  load #{((session.render_load || 0) * 100).round}%  band #{band.active? ? 'on' : 'off'}" unless p.quiet
          if p.capture && band.active? && now - t >= 1.0
            t = now
            band.invalidate
            frame = band.refresh
            if frame
              screen = UI::Screen.new(band.rows, band.cols)
              screen << frame
              text = screen.lines(p.color == :none ? :none : p.color)
              lines = band.top? ? text.first(band.height) : text.last(band.height)
              FileUtils.mkdir_p(p.capture)
              File.write(File.join(p.capture, format('band_%03d.ans', captured)), lines.join("\n") + "\e[0m\n")
              File.write(File.join(p.capture, format('band_%03d.html', captured)), Plot::AnsiHtml.page(lines.join("\n"), title: "ui_demo #{p.layout}"))
              captured += 1
            end
          end
        end
        FastUI::GVLProbe.stop
        waits[state].concat(FastUI::GVLProbe.waits(0))
        holds.concat(FastUI::GVLProbe.holds(1)) if on
        FastUI::GVLProbe.blockers(0).each do |_wait, slot|
          who = slot < 0 ? :'other (GC, unwatched)' : names[slot]
          who = :main if slot >= 0 && threads[slot].equal?(Thread.current) # (placeholders)
          blockers[state][who] += 1
        end
        gcs[state][0] += GC.count - gc0[0]
        gcs[state][1] += GC.stat(:time) - gc0[1]
        x1 = underruns.call
        xruns[state] += x1 - x0 if x0 && x1
        on = !on if p.compare
      end
      band_stats = band.stats
      band.stop
      MB::Sound.stop(:all, fade: 0)

      puts
      puts "Render thread wake delay (GVL wait after each wake), #{session.buffer_size}-frame buffers, #{p.layout} band at #{band.rows}x#{band.cols} #{p.color} #{p.look}#{tty ? '' : ' (to /dev/null)'}:"
      puts ui_demo_line('  band on', waits[:on]) if waits[:on].any? || p.ui
      puts ui_demo_line('  band off', waits[:off]) if waits[:off].any? || !p.ui
      puts ui_demo_line('Painter GVL holds', holds) if holds.any?
      s = band_stats
      puts "Painter per refresh: #{s[:frames]} refreshes, CPU p50 #{s[:cpu_ms][:p50]} p99 #{s[:cpu_ms][:p99]} max #{s[:cpu_ms][:max]} ms (refreshes that drew: p50 #{s[:busy_cpu_ms][:p50]} p99 #{s[:busy_cpu_ms][:p99]}), #{MB::M.sigfigs(s[:panes], 3)} panes per refresh, #{s[:bytes][:mean]} bytes per written frame (max #{s[:bytes][:max]})" if s[:frames] > 0
      s[:slowest].each { |e| puts "  slow refresh at #{e[:at]}: #{e[:cpu_ms]} ms CPU #{e[:parts].map { |k, v| "#{k} #{v}" }.join(', ')}" } if s[:frames] > 0
      %i[on off].each do |k|
        next if loads[k].empty?
        l = loads[k].sort
        puts "Render load with band #{k}: p50 #{(l[l.length / 2] * 100).round(1)}%  p99 #{(l[((l.length - 1) * 0.99).round] * 100).round(1)}%"
      end
      %i[on off].each do |k|
        next if blockers[k].empty?
        puts "Waits over 1 ms with band #{k}, by the thread holding the GVL: #{blockers[k].sort_by { |_, n| -n }.map { |w, n| "#{w} #{n}" }.join(', ')}"
      end
      %i[on off].each do |k|
        puts "GC with band #{k}: #{gcs[k][0]} runs, #{gcs[k][1]} ms" if gcs[k][0] > 0
      end
      if underruns.call
        puts "Underruns: band on #{xruns[:on]}, band off #{xruns[:off]}"
      else
        puts "Underruns: n/a (#{out.class.name.split('::').last} output)"
      end
      puts "Captures: #{captured} in #{p.capture}" if p.capture
    }
  end
end
