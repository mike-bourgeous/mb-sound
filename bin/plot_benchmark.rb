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
# frame for a full redraw and for a row diff against the previous frame
# (each wrapped in DEC 2026 synchronized output).
#
# Usage: $0 [options]
#
# Try:
#     bin/plot_benchmark.rb                          # every pane, look, color mode
#     bin/plot_benchmark.rb -p scope -l scope -c truecolor -n 2000
#     bin/plot_benchmark.rb --yjit both -j tmp/plot_bench.json
#     bin/plot_benchmark.rb --baseline tmp/plot_bench_master.json   # before/after columns
#     bin/plot_benchmark.rb --api render             # the plain render path only

require 'bundler/setup'
require 'json'
require 'rbconfig'
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

    t = times.sort
    med = percentile(t, 0.5) * 1000
    {
      pane: pane, look: look, color: color, api: api, yjit: yjit?,
      ms_median: med.round(3), ms_p99: (percentile(t, 0.99) * 1000).round(3), ms_max: (t[-1] * 1000).round(3),
      fps: (1000 / med).round, alloc_per_frame: (alloc.to_f / frames).round, gc_per_1000: (gcs * 1000.0 / frames).round(1),
      bytes_full: full / n, bytes_diff: n > 1 ? diff / (n - 1) : 0,
    }
  end

  def yjit?
    defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false
  end

  def format_table(rows, baseline)
    base = {}
    (baseline || []).each { |r| base[[r['pane'], r['look'], r['color'], r['yjit']].join(' ')] = r }
    head = %w[pane look color yjit median p99 max fps alloc gc/1k full_B diff_B]
    head += %w[before x_faster alloc_before] if baseline
    out = [head.join(' | '), head.map { '---' }.join(' | ')]
    rows.each do |r|
      cols = [r[:pane], r[:look], r[:color], r[:yjit] ? 'on' : 'off', r[:ms_median], r[:ms_p99], r[:ms_max], r[:fps], r[:alloc_per_frame], r[:gc_per_1000], r[:bytes_full], r[:bytes_diff]]
      if baseline
        b = base[[r[:pane], r[:look], r[:color], r[:yjit]].join(' ')]
        cols += b ? [b['ms_median'], (b['ms_median'] / r[:ms_median]).round(1), b['alloc_per_frame']] : ['', '', '']
      end
      out << cols.join(' | ')
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
) { |_, p|
  if p.yjit != :current
    modes = p.yjit == :both ? %w[off on] : [p.yjit.to_s]
    rows = []
    modes.each do |m|
      tmp = File.join(Dir.tmpdir, "plot_benchmark_#{Process.pid}_#{m}.json")
      args = ['--panes', p.panes, '--looks', p.looks, '--colors', p.colors, '-n', p.frames.to_s, '--api', p.api.to_s, '-j', tmp]
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
  puts "Plot frames on #{cpu}, Ruby #{RUBY_VERSION}, #{p.frames} frames per case"
  puts PlotBenchmark.format_table(rows, baseline)
  File.write(p.json, JSON.pretty_generate(rows)) if p.json
}
