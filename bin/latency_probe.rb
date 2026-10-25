#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Detects system stalls for as long as it runs (minutes to hours) with
# MB::Sound::LatencyProbe: a C thread outside the GVL wakes every --period
# and times a little memory-touching and CPU-only work, a Ruby thread does
# the same with the GVL (so GC, YJIT, and GVL holds show apart from system
# stalls), and per-second GC, YJIT, free memory, load, CPU busy/steal, and
# PSI are recorded alongside.  Prints a live status line; at the end (or
# Ctrl-C) writes report.txt, time/histogram/phase plots (.svg, .png, .txt),
# seconds.csv, events.csv, histograms.json, and meta.json to --output.
# Rows and events are flushed every --flush seconds, so a crash keeps them.
#
# Usage: $0 [options]
#
# Examples:
#     $0 -t 1h                         # an hour into tmp/latency_probe/probe-<time>/
#     $0 -t 15m -o /tmp/lat            # 15 minutes into /tmp/lat
#     $0 --period 0.5ms --threshold 1ms --memory 256MB
#     $0 --no-memory --no-cpu          # wake lateness only
#     $0 -t 10m --with-session         # also a realtime Session playing a pad
#     $0 --compare /tmp/a /tmp/b       # compare two saved runs
#
# Any live script can be probed too: MB_SOUND_LATENCY_PROBE=1 (or a
# directory) bin/songs/memory_card.rb watches the song's Session and lines
# its underruns and slow buffers up with system and Ruby stalls.

require 'bundler/setup'
require 'mb-sound'

# Parses "1h", "15m", "90s", "2ms", "500us", or plain seconds.
def duration(text)
  m = text.to_s.strip.match(/\A(\d+(?:\.\d+)?)\s*(us|µs|ms|s|sec|m|min|h)?\z/i)
  raise MB::Sound::ScriptRunner::InputError, "Can't read #{text.inspect} as a time (e.g. 1h, 15m, 90s, 2ms, 500us)" unless m

  v = m[1].to_f
  case m[2]&.downcase
  when 'us', 'µs' then v / 1e6
  when 'ms' then v / 1e3
  when 'm', 'min' then v * 60
  when 'h' then v * 3600
  else v
  end
end

# Parses "64MB", "128KB", "1GB", or plain bytes (binary units).
def bytes(text)
  m = text.to_s.strip.match(/\A(\d+(?:\.\d+)?)\s*([kmg]i?b?)?\z/i)
  raise MB::Sound::ScriptRunner::InputError, "Can't read #{text.inspect} as a size (e.g. 64MB, 128KB)" unless m

  scale = { 'k' => 1 << 10, 'm' => 1 << 20, 'g' => 1 << 30 }.fetch(m[2].to_s[0]&.downcase, 1)
  (m[1].to_f * scale).round
end

# Two saved runs side by side: their percentiles and counts tables.
def compare(dirs)
  dirs.each do |d|
    raise MB::Sound::ScriptRunner::InputError, "No report.txt in #{d}" unless File.exist?(File.join(d, 'report.txt'))
  end
  hists = dirs.map { |d| JSON.parse(File.read(File.join(d, 'histograms.json'))) }
  metas = dirs.map { |d| JSON.parse(File.read(File.join(d, 'meta.json'))) }
  h = MB::Sound::LatencyProbe::Histogram
  puts format('%-16s %-10s %10s %10s %10s %10s %8s %8s %8s', 'series', 'run', 'p50 ms', 'p99 ms', 'p99.9 ms', 'max ms', '>=5 ms', '>=20 ms', '>=50 ms')
  %w[late memory cpu stall ruby].each do |kind|
    hists.each_with_index do |hist, i|
      pairs = hist[kind]
      next if pairs.nil? || pairs.empty?

      counts = Array.new(h::BUCKETS, 0)
      pairs.each { |floor, c| counts[h.bucket(floor)] += c }
      hh = h.new(counts)
      puts format('%-16s %-10s %10.3f %10.3f %10.3f %10.3f %8d %8d %8d', kind, "run #{i + 1}",
        hh.percentile(0.5) / 1e6, hh.percentile(0.99) / 1e6, hh.percentile(0.999) / 1e6, hh.max_ns.to_f / 1e6,
        hh.count_at_least(5_000_000), hh.count_at_least(20_000_000), hh.count_at_least(50_000_000))
    end
  end
  metas.each_with_index do |m, i|
    puts "run #{i + 1}: #{dirs[i]}: #{m['started']} for #{m['seconds']} s on #{m.dig('host', 'cpu_model') || m.dig('host', 'platform')}, #{m.dig('probe', 'episodes')} episodes, priority #{m.dig('probe', 'priority')}"
  end
end

MB::Sound.script(
  args: 0,
  time: ['0', String, '-t', 'How long to run (e.g. 1h, 15m, 90s; 0 runs until Ctrl-C)'],
  output: [nil, String, '-o', 'Directory for the report, plots, and data (default tmp/latency_probe/probe-<time>)'],
  period: ['1ms', String, "The probe's tick (absolute deadlines)"],
  threshold: ['2ms', String, 'Stall size that makes an event'],
  memory: ['64MB', String, "The memory probe's buffer (larger than the caches)"],
  touch: ['128KB', String, 'Memory walked per tick'],
  cpu_iterations: [10_000, Integer, "The CPU probe's loop per tick", 0..100_000_000],
  no_memory: [false, 'No memory-touching probe'],
  no_cpu: [false, 'No CPU-only probe'],
  ruby_period: ['2ms', String, "The Ruby ticker's tick"],
  no_ruby: [false, 'No Ruby ticker'],
  no_boost: [false, "Leave the probe thread's priority alone (default: realtime where allowed)"],
  rt_priority: [10, Integer, 'SCHED_FIFO priority to try on Linux (0: skip realtime)', 0..99],
  pin: [nil, Integer, 'Pin the probe thread to a CPU (Linux)', 0..4095],
  mlock: [false, "Lock the probe's buffers in memory"],
  with_session: [false, 'Also run a realtime Session playing a quiet pad, and log its buffers and underruns'],
  flush: [10, Integer, 'Seconds between writes of the data files', 1..3600],
  status: [1.0, Float, 'Seconds between status lines', 0.1..3600.0],
  formats: ['svg,png,txt', String, 'Plot formats to write (svg, png, txt)'],
  compare: [nil, String, 'Compare saved runs: --compare DIR1,DIR2 (prints and exits)'],
  quiet: [false, '-q', 'No status lines'],
) { |_args, p|
  if p.compare
    compare(p.compare.split(','))
    next
  end

  dir = p.output || MB::Sound::LatencyProbe.default_dir
  work = []
  work << :memory unless p.no_memory
  work << :cpu unless p.no_cpu
  seconds = duration(p.time)

  probe = MB::Sound::LatencyProbe.new(
    dir: dir, period: duration(p.period), threshold: duration(p.threshold), work: work,
    memory: bytes(p.memory), memory_touch: bytes(p.touch), cpu_iterations: p.cpu_iterations,
    ruby: !p.no_ruby, ruby_period: duration(p.ruby_period),
    boost: !p.no_boost, rt_priority: p.rt_priority, pin_cpu: p.pin, mlock: p.mlock, flush_every: p.flush,
  )

  session = nil
  if p.with_session
    session = MB::Sound::Session.current
    pad = MB::Sound.stereo(110.hz.saw.at(-30.db), 165.hz.triangle.at(-30.db)).lp4(800.hz).reverb(:room, mix: 0.2)
    session.add(pad, name: :latency_pad)
  end

  probe.start
  probe.watch(session) if session
  puts "Latency probe: #{probe.stats[:priority]}; writing to #{dir}#{seconds > 0 ? " for #{MB::Sound::LatencyProbe::Report.duration(seconds)}" : ' until Ctrl-C'}"

  tty = $stdout.tty?
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  next_status = started + p.status
  begin
    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if seconds > 0 && now - started >= seconds

      if !p.quiet && now >= next_status
        line = probe.status_line
        tty ? print("\r\e[K#{line}") : puts(line)
        $stdout.flush
        # (pipes and files: one line per 10 status periods)
        next_status += tty ? p.status : p.status * 10
      end
      sleep([0.05, seconds > 0 ? seconds - (now - started) : 0.05].select(&:positive?).min || 0.05)
    end
  rescue Interrupt
    nil
  ensure
    puts if tty && !p.quiet
    probe.stop
    paths = probe.save(formats: p.formats.split(','))
    puts probe.report
    puts "Report and plots: #{paths.values.join(', ')}"
  end
}
