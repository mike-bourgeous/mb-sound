#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Counts the Ruby objects allocated per audio buffer in a live-like
# performance, by category and by source line (the 2026-10-19 allocation
# audit, kept as a tool; workbench research/alloc-audit/allocations-128.md).
#
# Scenario: a non-realtime Session (NullOutput, #process_buffer) plays the
# Night Bus flow (`demo`, `play_form`, `seek 21`) while the terminal
# keyboard's path (UI::Keyboard::Link -> the Session's MIDI input, its
# default 8-voice patch) gets a note-on every 6 x 128 frames (2-3 notes
# held), CC1 every 4, pitch bend every 5 (the same rate in time at any
# buffer size).  After a warm-up, a window of buffers is traced in chunks:
# GC off for each chunk, ObjectSpace.trace_object_allocations on, then the
# objects allocated in the chunk (this GC generation) are counted by
# file:line, and GC runs between chunks (so memory stays bounded).
# Totals come from GC.stat(:total_allocated_objects); the walk misses
# internal objects (imemo, hidden Numo/VM objects), shown as "hidden".
#
# --ui attaches a terminal UI feed (master meters + scope, as `ui :studio`
# shows; a snapshot taken every 12 buffers like a 30 fps painter), so its
# render-thread cost shows as the "UI feed" category.
#
# Categories are by allocating file (approximate; a C method allocating on
# behalf of Ruby code counts at the calling line, gem files by their gem):
# UI feed (lib/mb/sound/ui/, Numo concatenate), MIDI input
# (session/midi_input, midi/live_source, midi/virtual_input,
# ui/keyboard), scheduler (session/scheduler), and render (the rest).
#
# --time measures time per buffer instead (no tracing, GC on): mean,
# median, 90th/99th percentile, and worst #process_buffer time over the
# window, against the buffer's real-time budget.
#
# Usage: bin/alloc_audit.rb [options]
#     bin/alloc_audit.rb                    # 128 frames, 4 s warm-up, 24 s window
#     bin/alloc_audit.rb -n 512 -w 8 --top 30 --json /tmp/a.json
#     bin/alloc_audit.rb --ui
#     bin/alloc_audit.rb --time             # microseconds per buffer
#
# Compare branches by running the same command in each worktree.  Run
# without YJIT (`ruby bin/alloc_audit.rb`) to see Array#map callers instead
# of <internal:array>.

require 'bundler/setup'
require 'optparse'
require 'json'
require 'objspace'
require 'mb-sound'
require 'mb/sound/ui'

module MB::Sound
  # The allocation audit (loadable for specs).
  class AllocAudit
    CATEGORIES = [
      ['UI feed', %r{lib/mb/sound/ui/(?!keyboard)|numo/narray/extra\.rb}],
      ['MIDI input', %r{session/midi_input\.rb|midi/live_source\.rb|midi/virtual_input\.rb|ui/keyboard}],
      ['scheduler', %r{session/scheduler\.rb}],
    ].freeze

    NOTES = [57, 60, 64, 67, 69, 72].freeze

    Site = Struct.new(:file, :line, :klass, :method, :count, :bytes)

    attr_reader :buffers, :total, :sites, :session, :times

    def initialize(buffer_size: 128, warm: 4.0, window: 24.0, seek: 21, chunk: 250, ui: false, quiet: true)
      @buffer_size = buffer_size
      @warm = warm
      @window = window
      @seek = seek
      @chunk = chunk
      @ui = ui
      @quiet = quiet
      @tick = 0
      @held = []
    end

    def run
      setup
      warm = (@warm * 48000 / @buffer_size).round
      win = (@window * 48000 / @buffer_size).round
      warm.times { step }
      GC.start

      sites = Hash.new { |h, k| h[k] = [0, 0] }
      total = 0
      done = 0
      while done < win
        n = [@chunk, win - done].min
        GC.start
        GC.disable
        gen = GC.count
        a0 = GC.stat(:total_allocated_objects)
        ObjectSpace.trace_object_allocations do
          n.times { step }
        end
        total += GC.stat(:total_allocated_objects) - a0
        ObjectSpace.each_object do |o|
          next unless ObjectSpace.allocation_generation(o) == gen
          f = ObjectSpace.allocation_sourcefile(o)
          next unless f
          s = sites[[f, ObjectSpace.allocation_sourceline(o), ObjectSpace.allocation_class_path(o), ObjectSpace.allocation_method_id(o)]]
          s[0] += 1
          s[1] += ObjectSpace.memsize_of(o)
        end
        ObjectSpace.trace_object_allocations_clear
        GC.enable
        done += n
      end

      @buffers = win
      @total = total
      @sites = sites.map { |(f, l, c, m), (n, b)| Site.new(short(f), l, c, m, n, b) }.sort_by { |s| -s.count }
      self
    ensure
      @session&.close
    end

    # Times each buffer of the window (seconds per #process_buffer, GC
    # on, nothing traced) into #times.
    def run_times
      setup
      warm = (@warm * 48000 / @buffer_size).round
      win = (@window * 48000 / @buffer_size).round
      warm.times { step }
      GC.start
      @times = Array.new(win)
      win.times do |i|
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        step
        @times[i] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      end
      @buffers = win
      self
    ensure
      @session&.close
    end

    # Mean, median, 90th and 99th percentile, and worst buffer time in
    # microseconds (see #run_times).
    def time_stats
      t = @times.sort
      us = ->(x) { x * 1e6 }
      {
        mean: us[t.sum / t.length], p50: us[t[t.length / 2]], p90: us[t[(t.length * 0.9).floor]],
        p99: us[t[(t.length * 0.99).floor]], max: us[t[-1]], budget: @buffer_size * 1e6 / 48000,
      }
    end

    def time_report(io = $stdout)
      st = time_stats
      io.puts format('%d-frame buffers, %d timed (%.1f s), YJIT %s%s', @buffer_size, @buffers, @buffers * @buffer_size / 48000.0, yjit? ? 'on' : 'off', @ui ? ', UI feed on' : '')
      io.puts format('us/buffer: mean %.1f  p50 %.1f  p90 %.1f  p99 %.1f  max %.1f  (budget %.1f, mean %.1f%%)',
        st[:mean], st[:p50], st[:p90], st[:p99], st[:max], st[:budget], 100 * st[:mean] / st[:budget])
    end

    # Objects and bytes per buffer by category, plus the hidden remainder.
    def categories
      out = Hash.new { |h, k| h[k] = [0.0, 0.0] }
      %w[render scheduler MIDI\ input UI\ feed].each { |c| out[c] }
      @sites.each do |s|
        c = category(s.file)
        out[c][0] += s.count.to_f / @buffers
        out[c][1] += s.bytes.to_f / @buffers
      end
      walked = @sites.sum(&:count)
      out['hidden'] = [(@total - walked).to_f / @buffers, 0.0]
      out
    end

    def category(file)
      CATEGORIES.each { |name, re| return name if file.match?(re) }
      'render'
    end

    def report(io = $stdout, top: 25)
      io.puts format('%d-frame buffers, %d traced (%.1f s), YJIT %s%s',
        @buffer_size, @buffers, @buffers * @buffer_size / 48000.0, yjit? ? 'on' : 'off', @ui ? ', UI feed on' : '')
      io.puts format('total: %.1f objects/buffer', @total.to_f / @buffers)
      categories.each { |c, (n, b)| io.puts format('  %-12s %8.1f objects/buffer %9.0f B/buffer', c, n, b) }
      io.puts "top #{top} lines (objects/buffer, bytes/buffer, allocating methods):"
      lines.first(top).each do |(file, line), list|
        n = list.sum(&:count)
        b = list.sum(&:bytes)
        who = list.map { |s| [s.klass, s.method].compact.join('#') }.uniq.first(3).join(', ')
        io.puts format('  %8.2f %8.0f  %s:%d %s', n.to_f / @buffers, b.to_f / @buffers, file, line, who)
      end
    end

    # Sites grouped by file and line, most objects first.
    def lines
      @sites.group_by { |s| [s.file, s.line] }.sort_by { |_k, list| -list.sum(&:count) }
    end

    def to_h
      {
        buffer_size: @buffer_size, buffers: @buffers, yjit: yjit?, ui: @ui,
        total_per_buffer: @total.to_f / @buffers,
        categories: categories.transform_values { |n, b| { objects: n, bytes: b } },
        sites: @sites.first(200).map { |s| s.to_h.merge(per_buffer: s.count.to_f / @buffers) },
      }
    end

    private

    def yjit?
      defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? true : false
    end

    def short(f)
      f.sub(%r{\A.*/gems/}, 'gem ').sub(%r{\A#{Regexp.escape(File.expand_path('..', __dir__))}/}, '')
    end

    def setup
      out = MB::Sound::NullOutput.new(channels: 2, buffer_size: @buffer_size, sleep: false)
      @session = MB::Sound::Session.new(realtime: false, output: out, buffer_size: @buffer_size, channels: 2,
        transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      MB::Sound::Session.with_context(session: @session) do
        old = $stdout
        $stdout = File.open(File::NULL, 'w') if @quiet
        begin
          doc = MB::Sound.demo
          MB::Sound.play_form(doc.form, warm_up: false)
          MB::Sound.seek(@seek)
          @link = MB::Sound::UI::Keyboard::Link.new(session: @session)
          @link.ensure_monitor
        ensure
          $stdout = old
        end
      end

      if @ui
        @feed = MB::Sound::UI::Feed.new
        @feed.needs = [:meters, :scope]
        @session.ui_feed = @feed
      end
      @ticks = [@buffer_size / 128, 1].max
      @buf_count = 0
    end

    def step
      @ticks.times { feed_keys }
      MB::Sound::Session.with_context(session: @session) { @session.process_buffer }
      @buf_count += 1
      @feed.take if @feed && @buf_count % 12 == 0
    end

    def feed_keys
      @tick += 1
      t = @tick
      if t % 6 == 0
        k = NOTES[(t / 6) % NOTES.length]
        @link.note_on(k, 0.8)
        @held << k
      end
      @link.note_off(@held.shift) if t % 6 == 3 && @held.length > 2
      @link.cc(1, (t % 128) / 127.0) if t % 4 == 1
      if t % 5 == 2
        b = 8192 + ((t * 97) % 4000) - 2000
        @link.virtual.send_bytes([0xE0, b & 0x7f, b >> 7])
      end
    end
  end
end

if MB::Sound.main_script?(__FILE__) # (not $0 == __FILE__: SIMPLECOV=1 loads scripts by their full path)
  opts = { buffer_size: 128, warm: 4.0, window: 24.0, seek: 21, ui: false }
  top = 25
  json = nil
  time = false
  OptionParser.new do |o|
    o.banner = "Usage: #{$0} [options]"
    o.on('-n', '--buffer N', Integer, 'Buffer size (128)') { |v| opts[:buffer_size] = v }
    o.on('-W', '--warm SECONDS', Float, 'Warm-up (4)') { |v| opts[:warm] = v }
    o.on('-w', '--window SECONDS', Float, 'Traced window (24)') { |v| opts[:window] = v }
    o.on('-s', '--seek BAR', Integer, 'Bar to start from (21)') { |v| opts[:seek] = v }
    o.on('--ui', 'Attach a terminal UI feed (meters, scope)') { opts[:ui] = true }
    o.on('-t', '--top N', Integer, 'Sites to list (25)') { |v| top = v }
    o.on('--time', 'Measure time per buffer instead of allocations') { time = true }
    o.on('--json PATH', 'Also write the results as JSON') { |v| json = v }
  end.parse!

  if time
    audit = MB::Sound::AllocAudit.new(**opts).run_times
    audit.time_report
    File.write(json, JSON.pretty_generate(audit.time_stats)) if json
  else
    audit = MB::Sound::AllocAudit.new(**opts).run
    audit.report(top: top)
    File.write(json, JSON.pretty_generate(audit.to_h)) if json
  end
end
