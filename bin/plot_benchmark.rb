#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Measures MB::Sound::Plot frames for live UI panes: ms per frame and allocations.
#
# Each pane draws fresh data every frame, the way a live scope or spectrum
# pane would: a two-channel scope of 800-sample buffers (Plot.waveform,
# fixed -1..1 range), a spectrum of 2048-sample windows (Plot.spectrum, log
# frequency, -90..0 dB), and a 120x45 two-channel vis pane (play's -P
# size).  A frame is building the chart plus rendering it to ANSI text
# (Plot::Text.render joined into one String), or, with --api live, a
# Plot::Live pane's redraw.  Reported per pane, look, and color mode: ms per
# frame (median, p99, max), frames per second at the median, objects
# allocated per frame, GC runs per 1000 frames, and terminal bytes per
# frame (DEC 2026 synchronized output): a full redraw, rows that changed,
# and (with Plot::Live) cells that changed, plus the median ms of a
# Live#frame (draw + terminal bytes of the changed cells).
#
# --tty draws in the real terminal instead (end to end: drawing, encoding,
# writing, and the terminal's own parsing and drawing, closed by a cursor
# position query the terminal must answer), for every look and color mode
# given, and prints frames per second, bytes per frame, and this process's
# CPU per frame.  Run it natively in iTerm2, Konsole, etc. (see
# bin/plot_benchmark_native.sh).
#
# Usage: $0 [options]
#
# Try:
#     bin/plot_benchmark.rb                          # every pane, look, color mode
#     bin/plot_benchmark.rb -p scope -l scope -c truecolor -n 2000
#     bin/plot_benchmark.rb --yjit both -j tmp/plot_bench.json
#     bin/plot_benchmark.rb --baseline tmp/plot_bench_master.json   # before/after columns
#     bin/plot_benchmark.rb --api render             # the plain render path only
#     bin/plot_benchmark.rb --tty -p vis -l scope,blocks -c truecolor -n 600

require 'bundler/setup'
require 'json'
require 'rbconfig'
require 'io/console'
require 'mb-sound'

# Fixture data and frame functions for the benchmark.
module PlotBenchmark
  PANES = {
    scope: { width: 60, height: 16, title: 'scope 60x16, 2 ch' },
    spectrum: { width: 120, height: 30, title: 'spectrum 120x30' },
    vis: { width: 120, height: 45, title: 'vis 120x45, 2 ch' },
  }.freeze
  LOOKS = %i[scope blocks mosaic quad spark ascii].freeze
  COLORS = %i[truecolor ansi256 ansi16 none].freeze
  BUFFERS = 24

  module_function

  # BUFFERS frames of stereo data (two Numo::SFloats each) for waveforms:
  # an A minor chord of saws and a slowly beating sine, moving each frame
  def stereo_frames(len)
    rng = Random.new(1)
    Array.new(BUFFERS) { |k|
      t = (Numo::DFloat.new(len).seq + k * len) / 48000.0
      l = Numo::DFloat.zeros(len)
      [110.0, 130.81, 164.81].each { |f| l += ((t * f) % 1.0 - 0.5) * 0.5 }
      r = Numo::NMath.sin(t * 2 * Math::PI * 220.0) * (0.4 + 0.3 * Math.sin(k * 0.3)) +
        Numo::DFloat.new(len).rand(-0.05, 0.05)
      l += rng.rand(-0.02..0.02)
      [Numo::SFloat.cast(l), Numo::SFloat.cast(r)]
    }
  end

  def mono_frames(len)
    stereo_frames(len).map { |l, r| l + r * 0.5 }
  end

  # A Proc that draws frame +i+ and returns its text (one String of lines
  # joined by newlines).
  def frame_proc(pane, look, color, api)
    plot = MB::Sound::Plot
    w = PANES[pane][:width]
    h = PANES[pane][:height]
    data = pane == :spectrum ? mono_frames(2048) : stereo_frames(800)
    build =
      if pane == :spectrum
        ->(d) { plot.spectrum(d, title: 'spectrum', range: -90..0, floor: -90) }
      else
        ->(d) { plot.waveform(d, title: 'waveform', range: -1.0..1.0) }
      end

    if api == :live
      live = plot::Live.new(width: w, height: h, look: look, color: color)
      ->(i) { live.redraw(build.(data[i % BUFFERS])) }
    else
      ->(i) { plot::Text.render(build.(data[i % BUFFERS]), width: w, height: h, look: look, color: color).join("\n") }
    end
  end

  # The chart for frame +i+ of +pane+ (data from #pane_data).
  def chart(pane, data, i)
    plot = MB::Sound::Plot
    d = data[i % BUFFERS]
    if pane == :spectrum
      plot.spectrum(d, title: 'spectrum', range: -90..0, floor: -90)
    else
      plot.waveform(d, title: 'waveform', range: -1.0..1.0)
    end
  end

  def pane_data(pane)
    pane == :spectrum ? mono_frames(2048) : stereo_frames(800)
  end

  # Terminal bytes for a full redraw of +lines+ and for a row diff against
  # +prev+ (nil for none), each in synchronized output with cursor moves.
  def terminal_bytes(lines, prev)
    full = "\e[?2026h".bytesize + "\e[?2026l".bytesize
    diff = full
    lines.each_with_index do |l, r|
      row = "\e[#{r + 1};1H".bytesize + l.bytesize
      full += row
      diff += row if prev.nil? || prev[r] != l
    end
    [full, diff]
  end

  def percentile(sorted, q)
    sorted[((sorted.length - 1) * q).round]
  end

  # Measures one case: a Hash of results.
  def measure(pane, look, color, api, frames)
    f = frame_proc(pane, look, color, api)
    warm = [frames / 5, 20].max
    warm.times { |i| f.(i) }

    times = Array.new(frames)
    GC.start
    gc0 = GC.count
    alloc0 = GC.stat(:total_allocated_objects)
    clock = Process::CLOCK_MONOTONIC
    frames.times do |i|
      t0 = Process.clock_gettime(clock)
      f.(i)
      times[i] = Process.clock_gettime(clock) - t0
    end
    alloc = GC.stat(:total_allocated_objects) - alloc0
    gcs = GC.count - gc0

    # Terminal output for a stretch of frames (outside the timing)
    prev = nil
    full = diff = 0
    n = [frames, 50].min
    n.times do |i|
      lines = f.(i).split("\n")
      a, b = terminal_bytes(lines, prev)
      full += a
      diff += b if prev
      prev = lines
    end

    # Live#frame: the cells that changed, as a pane sends them
    cell_diff = frame_ms = nil
    if defined?(MB::Sound::Plot::Live)
      data = pane_data(pane)
      live = MB::Sound::Plot::Live.new(width: PANES[pane][:width], height: PANES[pane][:height], look: look, color: color)
      warm.times { |i| live.frame(chart(pane, data, i)) }
      ft = Array.new(frames) { |i|
        t0 = Process.clock_gettime(clock)
        cell_diff = (cell_diff || 0) + live.frame(chart(pane, data, i)).bytesize
        Process.clock_gettime(clock) - t0
      }.sort
      cell_diff /= frames
      frame_ms = (percentile(ft, 0.5) * 1000).round(3)
    end

    t = times.sort
    med = percentile(t, 0.5) * 1000
    {
      pane: pane, look: look, color: color, api: api, yjit: yjit?,
      ms_median: med.round(3), ms_p99: (percentile(t, 0.99) * 1000).round(3), ms_max: (t[-1] * 1000).round(3),
      fps: (1000 / med).round, alloc_per_frame: (alloc.to_f / frames).round, gc_per_1000: (gcs * 1000.0 / frames).round(1),
      bytes_full: full / n, bytes_diff: n > 1 ? diff / (n - 1) : 0, bytes_cells: cell_diff, frame_ms: frame_ms,
    }
  end

  def yjit?
    defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false
  end

  def format_table(rows, baseline)
    base = {}
    (baseline || []).each { |r| base[[r['pane'], r['look'], r['color'], r['yjit']].join(' ')] = r }
    head = %w[pane look color yjit median p99 max fps alloc gc/1k full_B rows_B cells_B frame_ms]
    head += %w[before x_faster alloc_before] if baseline
    out = [head.join(' | '), head.map { '---' }.join(' | ')]
    rows.each do |r|
      cols = [r[:pane], r[:look], r[:color], r[:yjit] ? 'on' : 'off', r[:ms_median], r[:ms_p99], r[:ms_max], r[:fps], r[:alloc_per_frame], r[:gc_per_1000], r[:bytes_full], r[:bytes_diff], r[:bytes_cells], r[:frame_ms]]
      if baseline
        b = base[[r[:pane], r[:look], r[:color], r[:yjit]].join(' ')]
        cols += b ? [b['ms_median'], (b['ms_median'] / r[:ms_median]).round(1), b['alloc_per_frame']] : ['', '', '']
      end
      out << cols.join(' | ')
    end
    out.join("\n")
  end

  # Asks the terminal for the cursor position and waits for its answer
  # (so everything written before was parsed); false after +timeout+ s.
  def terminal_sync(timeout = 2)
    $stdout.write("\e[6n")
    $stdout.flush
    reply = +''
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    $stdin.raw do |io|
      loop do
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if left <= 0
        next unless io.wait_readable(left)

        reply << io.read_nonblock(64, exception: false).to_s
        return true if reply.include?('R')
      end
    end
  end

  # Draws +frames+ frames of +pane+ in the terminal for each look and color
  # mode; returns result Hashes.
  def tty(panes, looks, colors, frames, full: false, sync: true)
    abort 'plot_benchmark: --tty needs a terminal on stdin and stdout' unless $stdin.tty? && $stdout.tty?
    plot = MB::Sound::Plot
    results = []
    $stdout.write("\e[?1049h\e[?25l\e[2J")
    panes.each do |pane|
      data = pane_data(pane)
      looks.each do |look|
        (look == :ascii ? [:none] : colors).each do |color|
          live = plot::Live.new(width: PANES[pane][:width], height: PANES[pane][:height], look: look, color: color)
          $stdout.write("\e[2J")
          20.times { |i| live.write($stdout, chart(pane, data, i), row: 1, col: 1, full: full, sync: sync) }
          answered = terminal_sync
          bytes = 0
          cpu0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          frames.times { |i| bytes += live.write($stdout, chart(pane, data, i), row: 1, col: 1, full: full, sync: sync) }
          answered &&= terminal_sync(10)
          t = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu0
          results << {
            pane: pane, look: look, color: color, yjit: yjit?, full: full, sync: sync,
            fps: (frames / t).round, ms_per_frame: (t * 1000 / frames).round(3), cpu_ms_per_frame: (cpu * 1000 / frames).round(3),
            bytes_per_frame: bytes / frames, mb_per_s: (bytes / t / 1e6).round(2), answered: answered,
          }
        end
      end
    end
    results
  ensure
    $stdout.write("\e[?25h\e[?1049l")
    $stdout.flush
  end

  def format_tty(rows)
    head = %w[pane look color yjit diff fps ms/frame cpu_ms bytes MB/s answered]
    out = [head.join(' | '), head.map { '---' }.join(' | ')]
    rows.each do |r|
      out << [r[:pane], r[:look], r[:color], r[:yjit] ? 'on' : 'off', r[:full] ? 'full' : 'cells', r[:fps], r[:ms_per_frame], r[:cpu_ms_per_frame], r[:bytes_per_frame], r[:mb_per_s], r[:answered] ? 'yes' : 'NO'].join(' | ')
    end
    out.join("\n")
  end
end

MB::Sound.script(
  panes: ['scope,spectrum,vis', '-p', String, "Panes to measure (#{PlotBenchmark::PANES.keys.join(', ')})"],
  looks: [PlotBenchmark::LOOKS.join(','), '-l', String, 'Text looks to measure'],
  colors: [PlotBenchmark::COLORS.join(','), '-c', String, 'Color modes to measure'],
  frames: [300, '-n', Integer, 'Timed frames per case', 1..100_000],
  api: [:auto, '-a', Symbol, 'render (Plot::Text.render), live (Plot::Live#redraw), or auto (live when Plot::Live exists)', %i[auto render live]],
  yjit: [:current, Symbol, 'current, on, off, or both (both reruns this script in two child processes)', %i[current on off both]],
  json: [nil, '-j', String, 'Write the results as JSON to this file'],
  baseline: [nil, '-B', String, 'A JSON file from an earlier run, for before/after columns'],
  tty: [false, '-t', 'Draw in this terminal (end to end, with the terminal\'s own drawing); see the header'],
  full: [false, 'With --tty, redraw every cell each frame instead of only the changed cells'],
  sync: [true, 'With --tty, wrap frames in DEC 2026 synchronized output (--no-sync to leave it out)'],
  report: [nil, '-R', String, 'Also append the results table to this file'],
) { |_, p|
  if p.tty
    rows = PlotBenchmark.tty(p.panes.split(',').map(&:to_sym), p.looks.split(',').map(&:to_sym), p.colors.split(',').map(&:to_sym), p.frames, full: p.full, sync: p.sync)
    term = [ENV['TERM_PROGRAM'], ENV['TERM'], ENV['KONSOLE_VERSION'] && "Konsole #{ENV['KONSOLE_VERSION']}"].compact.join(', ')
    text = "Plot panes drawn in the terminal (#{term}) on #{RUBY_PLATFORM}, Ruby #{RUBY_VERSION}, #{p.frames} frames per case\n#{PlotBenchmark.format_tty(rows)}"
    puts text
    File.open(p.report, 'a') { |f| f.puts(text, '') } if p.report
    File.write(p.json, JSON.pretty_generate(rows)) if p.json
    next
  end

  if p.yjit != :current
    modes = p.yjit == :both ? %w[off on] : [p.yjit.to_s]
    rows = []
    modes.each do |m|
      tmp = File.join(Dir.tmpdir, "plot_benchmark_#{Process.pid}_#{m}.json")
      args = ['--panes', p.panes, '--looks', p.looks, '--colors', p.colors, '-n', p.frames.to_s, '--api', p.api.to_s, '-j', tmp]
      args << '--tty' if p.tty
      env = { 'RUBY_YJIT_ENABLE' => m == 'on' ? '1' : '0' }
      ok = system(env, RbConfig.ruby, __FILE__, *args, out: File::NULL)
      abort "plot_benchmark: the YJIT #{m} run failed" unless ok
      rows.concat(JSON.parse(File.read(tmp), symbolize_names: true))
      File.delete(tmp)
    end
  else
    api = p.api == :auto ? (defined?(MB::Sound::Plot::Live) ? :live : :render) : p.api
    rows = []
    p.panes.split(',').map(&:to_sym).each do |pane|
      abort "Unknown pane #{pane}" unless PlotBenchmark::PANES.key?(pane)
      p.looks.split(',').map(&:to_sym).each do |look|
        colors = look == :ascii ? [:none] : p.colors.split(',').map(&:to_sym)
        colors.each do |color|
          rows << PlotBenchmark.measure(pane, look, color, api, p.frames)
          $stderr.print '.' if $stderr.tty?
        end
      end
    end
    $stderr.puts if $stderr.tty?
  end

  baseline = p.baseline && JSON.parse(File.read(p.baseline))
  cpu = File.exist?('/proc/cpuinfo') ? File.foreach('/proc/cpuinfo').grep(/model name/).first.to_s.split(':', 2)[1].to_s.strip : RUBY_PLATFORM
  text = "Plot frames on #{cpu}, Ruby #{RUBY_VERSION}, #{p.frames} frames per case\n#{PlotBenchmark.format_table(rows, baseline)}"
  puts text
  File.open(p.report, 'a') { |f| f.puts(text, '') } if p.report
  File.write(p.json, JSON.pretty_generate(rows)) if p.json
}
