#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Measures how this terminal times chords against fast arpeggios (step entry's chord window).
#
# The virtual keyboard's step entry joins notes typed within
# UI::Keyboard::StepEntry::CHORD (80 ms) into one chord step.  Whether a
# window can tell chords from fast arpeggios depends on the terminal, the
# OS, and Ruby's wake-ups, so this asks you to play some of each and
# measures the gaps between key presses as the console reads them:
#
#     bin/keyboard_timing.rb                 # 6 chords, 6 arpeggios, 6 fast runs (about a minute)
#     bin/keyboard_timing.rb -n 10 --json /tmp/timing.json
#     bin/keyboard_timing.rb --simulate      # no terminal: a synthetic player (the smoke run)
#
# Each key's time is Process.clock_gettime(CLOCK_MONOTONIC) when the read
# loop gets it (terminals send no event times, the kitty protocol
# included; keys that arrive in one read share a time, which the report
# counts).  It also measures the read loop's wake latency (a pipe written
# from another thread) and the OS timer granularity (1 ms sleeps), then
# prints the inter-onset gaps of chords, arpeggios, and runs (min, median,
# p95, max), how much they overlap, and a suggested chord window, or "can't
# separate on this terminal".  The window stays at 80 ms until results
# come in from real terminals.

require 'bundler/setup'
require 'mb-sound'
require 'json'

module MB::Sound
  # The measurements and the report (loadable for specs).
  module KeyboardTiming
    # What each trial asks for: [kind, prompt].
    TRIALS = {
      chord: 'press z c b together, as one chord',
      arp: 'play z c b as a fast arpeggio (one after another, as fast as you can)',
      run: 'play z x c v b as a fast run',
    }.freeze

    # Seconds of no keys that end a trial.
    IDLE = 0.6

    module_function

    # min/median/p95/max of +list+ (seconds) in milliseconds, or nil.
    def stats(list)
      return nil if list.empty?
      s = list.sort
      at = ->(q) { s[((s.length - 1) * q).round] }
      { n: s.length, min: s.first * 1000, median: at.(0.5) * 1000, p95: at.(0.95) * 1000, max: s.last * 1000 }
    end

    # The gaps between consecutive key presses in each trial of +trials+
    # ({ kind => [[t, t, ...], ...] }), as { kind => [gaps] }.
    def gaps(trials)
      trials.transform_values { |list| list.flat_map { |times| times.each_cons(2).map { |a, b| b - a } } }
    end

    # A chord window between the chords' slowest gaps and the arpeggios'
    # and runs' fastest (p95 of chords against p5 of the others), or nil
    # when they overlap.  Returns [window seconds or nil, overlap count].
    def suggest(g)
      chords = g[:chord].sort
      others = (g[:arp] + g[:run]).sort
      return [nil, 0] if chords.empty? || others.empty?
      hi = chords[((chords.length - 1) * 0.95).round]
      lo = others[((others.length - 1) * 0.05).round]
      overlap = chords.count { |x| x >= others.first } + others.count { |x| x <= chords.last }
      [hi < lo ? (hi + lo) / 2 : nil, overlap]
    end

    # The read loop's wake latency: +n+ times, another thread writes to a
    # pipe after a short sleep and the loop records how late it woke.
    def wake_latency(n = 100)
      r, w = IO.pipe
      lat = []
      n.times do
        sent = nil
        t = Thread.new { sleep 0.002; sent = MB::U.clock_now; w.write('.') }
        r.wait_readable(1)
        got = MB::U.clock_now
        r.read_nonblock(16, exception: false)
        t.join
        lat << got - sent if sent
      end
      lat
    ensure
      r&.close
      w&.close
    end

    # How long 1 ms sleeps really take, +n+ times (seconds).
    def timer_grain(n = 100)
      Array.new(n) { t0 = MB::U.clock_now; sleep 0.001; MB::U.clock_now - t0 }
    end

    # Reads one trial's key presses from +io+ (raw) until IDLE seconds
    # pass after the first key.  Returns [times, keys arriving in a read
    # with others].
    def read_trial(io, dec)
      times = []
      shared = 0
      loop do
        wait = times.empty? ? 30 : IDLE
        ready = io.wait_readable(dec.pending? ? [dec.esc_timeout, wait].min : wait)
        now = MB::U.clock_now
        break if !ready && !dec.pending? && !times.empty?
        return [times, shared, :timeout] if !ready && times.empty?
        events = ready ? dec.feed(io.read_nonblock(4096, exception: false).to_s) : dec.flush
        keys = events.select { |e| e.is_a?(UI::Input::Key) && e.press? }
        return [times, shared, :quit] if keys.any? { |k| k.key == 'q' || k.key == :escape || (k.key == 'c' && k.mods.include?(:ctrl)) }
        shared += keys.length if keys.length > 1
        keys.each { times << now }
      end
      [times, shared, :ok]
    end

    # A synthetic player (seeded): chords 3-25 ms apart, arpeggios 45-130
    # ms, runs 35-110 ms, each with +jitter+ seconds of read jitter.
    def simulate(n, seed: 1, jitter: 0.002)
      rng = Random.new(seed)
      gen = ->(count, lo, hi) { t = 0.0; Array.new(count) { |i| t += i == 0 ? 0 : lo + rng.rand * (hi - lo); t + rng.rand * jitter } }
      { chord: Array.new(n) { gen.(3, 0.003, 0.025) }, arp: Array.new(n) { gen.(3, 0.045, 0.13) }, run: Array.new(n) { gen.(5, 0.035, 0.11) } }
    end

    # The report's lines.
    def report(trials, wake:, grain:, shared: 0, res: Process.clock_getres(Process::CLOCK_MONOTONIC))
      g = gaps(trials)
      f = ->(s) { s ? format('n %3d  min %6.1f  median %6.1f  p95 %6.1f  max %6.1f ms', s[:n], s[:min], s[:median], s[:p95], s[:max]) : 'no data' }
      window, overlap = suggest(g)
      ws = stats(wake)
      gs = stats(grain)
      lines = []
      lines << "Clock resolution:   #{format('%.3f', res * 1e6)} us (CLOCK_MONOTONIC)"
      lines << "Timer (1 ms sleeps): #{gs ? format('median %.2f  p95 %.2f  max %.2f ms', gs[:median], gs[:p95], gs[:max]) : 'not measured'}"
      lines << "Read-loop wake:     #{ws ? format('median %.3f  p95 %.3f  max %.3f ms', ws[:median], ws[:p95], ws[:max]) : 'not measured'}"
      lines << "Keys sharing a read: #{shared}"
      lines << ''
      lines << "Gaps between key presses:"
      %i[chord arp run].each { |k| lines << "  #{k.to_s.ljust(6)} #{f.(stats(g[k] || []))}" }
      lines << ''
      lines << "Overlap: #{overlap} gap#{overlap == 1 ? '' : 's'} on the wrong side of the other kind's extreme"
      cur = UI::Keyboard::StepEntry::CHORD * 1000
      lines << if window
                 "Suggested chord window: #{format('%.0f', window * 1000)} ms (between the chords' p95 and the arpeggios' and runs' p5; now #{cur.round} ms)"
               else
                 "Can't separate chords from fast arpeggios on this terminal by time alone (now #{cur.round} ms)"
               end
      lines
    end
  end

  if main_script?(__FILE__)
    MB::Sound.script(
      count: [6, 'Trials of each kind', '-n', Integer, 1..50],
      json: [nil, 'Also write the raw times and the report to this JSON file', '-j', String],
      simulate: [false, 'No terminal: a synthetic player (for the smoke run)'],
    ) { |_args, p|
      kt = KeyboardTiming
      shared = 0
      if p.simulate
        trials = kt.simulate(p.count)
      else
        unless $stdin.tty? && $stdout.tty?
          puts 'Not a terminal: run bin/keyboard_timing.rb in the terminal to measure it (or --simulate).'
          next
        end
        trials = { chord: [], arp: [], run: [] }
        puts 'Play on the lower row (z x c v b ...).  Each trial ends 0.6 s after your last key; q or Esc stops early.'
        dec = UI::Input::Decoder.new
        quit = false
        $stdin.raw(intr: true) do |io|
          kt::TRIALS.each do |kind, prompt|
            break if quit
            p.count.times do |i|
              $stdout.write("\r\n#{kind} #{i + 1}/#{p.count}: #{prompt}\r\n")
              times, sh, how = kt.read_trial(io, dec)
              quit = true if how == :quit
              break if quit
              shared += sh
              trials[kind] << times if times.length > 1
              $stdout.write("  #{times.length} keys#{times.length > 1 ? ", gaps #{times.each_cons(2).map { |a, b| format('%.0f', (b - a) * 1000) }.join(' ')} ms" : ''}\r\n")
            end
          end
        end
        puts
      end
      wake = kt.wake_latency
      grain = kt.timer_grain
      lines = kt.report(trials, wake: wake, grain: grain, shared: shared)
      puts lines
      if p.json
        File.write(p.json, JSON.pretty_generate(trials: trials, wake: wake, grain: grain, shared: shared, report: lines, terminal: ENV.slice(*TerminalInfo::ENV_KEYS)))
        puts "Wrote #{p.json}"
      end
    }
  end
end
