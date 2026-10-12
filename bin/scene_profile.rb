#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Profiles the scene changes of a song script: how long each scheduled
# block (a form section's scene launch, at_bar blocks) takes and where the
# time goes, and how long each render buffer takes, especially where
# changes land and new players render their first buffer.  Written for the
# scene-build work (design/notes/arrangement.md, "Scene builds").
#
# The song runs as it would live (after MB::Sound.warm_up, and with the
# form's track warm-up, Arrangement#warm_up), captured where the song
# script would play or render, then either:
#
# - offline (default): rendered through a Session with scheduled blocks
#   run inline, so each block's time is its own; reported per block with
#   its phases (patch builds and Synth lanes, Plan.install and its parts,
#   graph traversals, Session#add; exclusive milliseconds and call
#   counts), GC time, and YJIT compile time, and the slowest render
#   buffers with each player's time (* marks a player's first buffer).
# - realtime (-R): played in a realtime Session on an emulated sound card
#   (a 48 kHz clock draining a queue of --latency ms; writes wait while it
#   is full, like DeviceOutput), with blocks on the scheduler thread as
#   live; reports underruns (where and how long), render times, and each
#   slow block's slack (how long before its time it finished).  Takes
#   real time: about two seconds per bar.
#
# YJIT counters (compile time, invalidations) are shown with YJIT on (the
# shebang turns it on; `ruby bin/scene_profile.rb` runs without it).
# Compare branches by running the same command in each worktree in
# alternating order, while nothing else runs on the machine.
#
# Usage: bin/scene_profile.rb [options] SONG_SCRIPT [-- song options]
#
# Examples:
#     bin/scene_profile.rb bin/songs/night_bus_flow.rb
#     bin/scene_profile.rb -n 128 --bars 60 bin/songs/small_talk.rb -- --seed 2
#     bin/scene_profile.rb -R -n 128 -l 20 --bars 60 bin/songs/night_bus_flow.rb
#     bin/scene_profile.rb -w off bin/songs/night_bus_flow.rb   # without the form's warm-up

require 'bundler/setup'
require 'mb-sound'

module SceneProfile
  # Phase timers: exclusive and inclusive seconds and calls per name, per
  # scheduled block (or :setup), on the thread running the block.
  @phases = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [0.0, 0] } }
  @blocks = []
  @buffers = []

  class << self
    attr_reader :phases, :blocks, :buffers
    attr_accessor :landed

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def yjit
      return {} unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      RubyVM::YJIT.runtime_stats.slice(:compile_time_ns, :invalidation_count, :invalidate_everything)
    end

    def ydelta(a, b) = b.to_h { |k, v| [k, v - (a[k] || 0)] }

    # Times the block as phase +name+ when this thread is recording.
    def time(name)
      st = Thread.current[:scene_profile]
      return yield unless st

      frame = [0.0]
      st[:stack] << frame
      t0 = clock
      begin
        yield
      ensure
        dt = clock - t0
        st[:stack].pop
        st[:stack].last[0] += dt if st[:stack].last
        e = @phases[st[:key]][name]
        e[0] += dt - frame[0]
        e[1] += 1
      end
    end

    # Records phases on this thread under +key+ while the block runs.
    def recording(key)
      old = Thread.current[:scene_profile]
      Thread.current[:scene_profile] = { key: key, stack: [] }
      yield
    ensure
      Thread.current[:scene_profile] = old
    end

    # Prepends a phase timer to +meth+ of +mod+ (its singleton if
    # +singleton+).
    def wrap(mod, meth, name, singleton: false)
      m = Module.new { define_method(meth) { |*a, **k, &b| SceneProfile.time(name) { super(*a, **k, &b) } } }
      singleton ? mod.singleton_class.prepend(m) : mod.prepend(m)
    end

    def install
      s = MB::Sound
      wrap(s::Arrangement, :start_track, 'patch build')
      wrap(s::Synth, :initialize, 'Synth lanes')
      wrap(s::Plan, :install, 'Plan.install', singleton: true)
      wrap(s::Plan::Installation, :build, 'plan regions')
      wrap(s::Plan::Region, :compile, 'plan compile')
      wrap(s::Plan::LaneGroups, :initialize, 'lane groups')
      wrap(s::GraphNode, :graph, 'graph traversal', singleton: true)
      wrap(s::Session, :add, 'Session#add')
      wrap(s::Session, :swap, 'Session#swap')
      wrap(s::GraphNodeInput, :initialize, 'GraphNodeInput')
      s::Session::Scheduler.prepend(SchedulerHook)
      s::Session.prepend(SessionHook)
    end
  end

  # Times scheduled blocks and records their phases.
  module SchedulerHook
    def run(entry, time, deadline)
      b = { id: SceneProfile.blocks.length, desc: entry.description.delete_prefix('form: '), bar: @transport.bar_at(time).to_f, gc0: GC.stat(:time), y0: SceneProfile.yjit, t0: SceneProfile.clock }
      SceneProfile.blocks << b
      SceneProfile.recording(b[:id]) { super }
    ensure
      b[:secs] = SceneProfile.clock - b[:t0]
      b[:gc] = GC.stat(:time) - b[:gc0]
      b[:yjit] = SceneProfile.ydelta(b[:y0], SceneProfile.yjit)
      b[:slack] = ((time - @transport.position) / @transport.whole_notes_per_second).to_f
    end
  end

  # Times render buffers (without scheduled blocks run inline or the
  # output's write) and each player in them.
  module SessionHook
    def process_buffer(count = buffer_size)
      return super unless output.is_a?(EmuOutput) || output.is_a?(CountingOutput)

      nb = SceneProfile.blocks.length
      @scene_players = {}
      SceneProfile.landed = 0
      gc0 = GC.stat(:time)
      y0 = SceneProfile.yjit
      t0 = SceneProfile.clock
      r = super
      # Offline, scheduled blocks run inside the buffer (realtime, on the
      # scheduler thread)
      inline = output.instance_of?(CountingOutput) ? SceneProfile.blocks[nb..].sum { |b| b[:secs] || 0 } : 0
      secs = SceneProfile.clock - t0 - inline - output.write_secs
      SceneProfile.buffers << {
        secs: secs, gc: GC.stat(:time) - gc0, yjit: SceneProfile.ydelta(y0, SceneProfile.yjit), landed: SceneProfile.landed,
        players: @scene_players, bar: transport.bar_at(transport.position).to_f,
      }
      r
    end

    private

    def commit_change(c, **kw)
      SceneProfile.landed += 1 if SceneProfile.landed
      super
    end

    def render_player(p, *rest)
      first = !p.started
      t0 = SceneProfile.clock
      super
    ensure
      @scene_players["#{p.name}#{first ? '*' : ''}"] = SceneProfile.clock - t0 if @scene_players
    end
  end

  # An output that discards the mix (offline), timing nothing.
  class CountingOutput
    attr_reader :channels, :buffer_size, :sample_rate

    def initialize(buffer_size)
      @channels = 2
      @buffer_size = buffer_size
      @sample_rate = 48000.0
    end

    def write(_data) = nil
    def write_secs = 0
    def close; end
    def closed? = false
  end

  # An emulated sound card: a 48 kHz clock drains a queue; #write waits
  # while more than +latency+ seconds are queued (like DeviceOutput) and
  # counts underruns (the queue running dry).
  class EmuOutput < CountingOutput
    attr_reader :underruns, :write_secs, :min_level, :latency

    def initialize(buffer_size, latency, transport)
      super(buffer_size)
      @latency = latency
      @transport = transport
      @t0 = nil
      @frames = 0
      @underruns = []
      @min_level = Float::INFINITY
      @write_secs = 0
    end

    def write(data)
      w0 = SceneProfile.clock
      if @t0
        level = @frames / @sample_rate - (w0 - @t0)
        if level < 0
          @underruns << [@transport.bar_at(@transport.position).to_f, -level]
          @t0 = w0
          @frames = 0
        else
          @min_level = level if level < @min_level
        end
      else
        @t0 = w0
      end
      @frames += data[0].length
      level = @frames / @sample_rate - (SceneProfile.clock - @t0)
      sleep(level - @latency) if level > @latency
      @write_secs = SceneProfile.clock - w0
    end
  end

  # Raised to stop a song script where it would play or render.
  module SongCapture
    def run_song(bars: nil, &block)
      throw :scene_profile_song, [self, bars, block]
    end
  end

  # Forces (or skips) the form's track warm-up (Arrangement#warm_up), and
  # times it apart from the song's setup.
  module FormWarmUp
    def play_form(form, warm_up: :auto, **kw)
      super(form, **kw, warm_up: SceneProfile.form_warm_up.nil? ? warm_up : SceneProfile.form_warm_up)
    end

    def warm_up(*tracks, **kw)
      t0 = SceneProfile.clock
      result = SceneProfile.recording(:warm_up) { super }
      SceneProfile.warmed = [result&.length || 0, SceneProfile.clock - t0] if result
      result
    end
  end

  class << self
    attr_accessor :form_warm_up, :warmed

    def ms(s) = format('%.1f', s * 1000)

    def yjit_text(y)
      return '' if y.nil? || y.empty?
      text = "YJIT compile #{(y[:compile_time_ns] / 1e6).round} ms"
      text += ", invalidated everything #{y[:invalidate_everything]}x" if y[:invalidate_everything].to_i > 0
      text
    end

    def phase_text(key, top)
      @phases[key].sort_by { |_, (s, _)| -s }.first(top).select { |_, (s, _)| s >= 0.0005 }.map { |n, (s, c)|
        "#{n} #{ms(s)}#{c > 1 ? " x#{c}" : ''}"
      }.join(', ')
    end

    def report_blocks(top, realtime:)
      slow = @blocks.select { |b| b[:secs] }.sort_by { |b| -b[:secs] }.first(top)
      puts "scheduled blocks: #{@blocks.length}, slowest (ms; phases exclusive):"
      slow.each do |b|
        extra = [("GC #{b[:gc]} ms" if b[:gc] > 0), yjit_text(b[:yjit]).then { |t| t.empty? ? nil : t }, ("finished #{ms(b[:slack])} ms before its time" if realtime)].compact.join('; ')
        puts format('  bar %6.2f %-18s %7s ms%s', b[:bar], b[:desc][0, 18], ms(b[:secs]), extra.empty? ? '' : " (#{extra})")
        phases = phase_text(b[:id], 6)
        puts "      #{phases}" unless phases.empty?
      end
    end

    def report_buffers(top, buffer)
      return if @buffers.empty?
      times = @buffers.map { |b| b[:secs] }.sort
      pct = ->(q) { times[(q * (times.length - 1)).round] }
      puts format('render buffers: %d, mean %s ms, p99 %s ms, max %s ms (a buffer is %.2f ms)',
        times.length, ms(times.sum / times.length), ms(pct[0.99]), ms(times.last), buffer * 1000.0 / 48000)
      landing = @buffers.select { |b| b[:landed] > 0 }
      unless landing.empty?
        puts format('  where changes landed: %d buffers, mean %s ms, max %s ms', landing.length, ms(landing.sum { |b| b[:secs] } / landing.length), ms(landing.map { |b| b[:secs] }.max))
      end
      puts '  slowest (* a player\'s first buffer):'
      @buffers.sort_by { |b| -b[:secs] }.first(top).each do |b|
        players = b[:players].sort_by { |_, v| -v }.first(4).map { |n, v| "#{n} #{ms(v)}" }.join(', ')
        extra = [("GC #{b[:gc]} ms" if b[:gc] > 0), yjit_text(b[:yjit]).then { |t| t.empty? || b[:yjit][:compile_time_ns] < 1e6 ? nil : t }, ("#{b[:landed]} change#{b[:landed] == 1 ? "" : "s"} landed" if b[:landed] > 0)].compact.join('; ')
        puts format('    bar %6.2f %7s ms%s  %s', b[:bar], ms(b[:secs]), extra.empty? ? '' : " (#{extra})", players)
      end
    end
  end
end

if MB::Sound.main_script?(__FILE__)
  MB::Sound.script(
    args: 1..,
    buffer: [512, Integer, '-n', 'Buffer size in frames', 16..8192],
    bars: [nil, Integer, 'Bars to play (default: the whole song offline, 32 realtime)', 1..],
    realtime: [false, '-R', 'Play in a realtime Session on an emulated sound card (takes real time) instead of rendering'],
    latency: [50.0, Float, '-l', 'The emulated card\'s queue in ms (realtime)', 1.0..1000.0],
    warm_up: ['on', String, '-w', 'The form\'s track warm-up (Arrangement#warm_up): on, off, or auto (what play_form does: realtime with YJIT only)', ['on', 'off', 'auto']],
    top: [8, Integer, '-t', 'How many blocks and buffers to list', 1..100],
  ) { |args, p|
    song, *song_args = args
    raise ArgumentError, "No such song script: #{song}" unless File.file?(song)
    raise ArgumentError, "#{song} isn't a song script (song_script)" unless File.read(song).include?('song_script')

    SceneProfile.install
    SceneProfile.form_warm_up = { 'on' => true, 'off' => false, 'auto' => nil }.fetch(p.warm_up)
    MB::Sound::Arrangement.prepend(SceneProfile::FormWarmUp)
    MB::Sound::ScriptRunner.prepend(SceneProfile::SongCapture)

    ARGV.replace(song_args + ['-q'])
    program = $PROGRAM_NAME
    $PROGRAM_NAME = song
    runner, song_bars, block = catch(:scene_profile_song) { load song; nil }
    $PROGRAM_NAME = program
    raise ArgumentError, "#{song} isn't a song script (song_script)" unless block

    bars = p.bars || (p.realtime ? [32, song_bars || 32].min : song_bars) or raise ArgumentError, "#{song} has no length; give --bars"
    yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
    MB::Sound.warm_up # as live scripts do
    quiet = File.open(File::NULL, 'w')

    if p.realtime
      transport = MB::Sound.transport
      out = SceneProfile::EmuOutput.new(p.buffer, p.latency / 1000.0, transport)
      MB::Sound::Session.use_output(out)
      session = MB::Sound::Session.default
      t0 = SceneProfile.clock
      begin
        $stdout = quiet
        SceneProfile.recording(:setup) { runner.send(:arrange_song, &block) }
        end_pos = session.transport.bar_position(bars + 1)
        sleep 0.05 until session.transport.position >= end_pos || (session.idle? && !session.schedule_due?)
      ensure
        $stdout = STDOUT
        late = session.late_blocks
        session.close
      end
      elapsed = SceneProfile.clock - t0

      puts format('%s: realtime, %d-frame buffers, emulated card with a %.0f ms queue, %d bars in %.1f s, YJIT %s, form warm-up %s',
        File.basename(song), p.buffer, p.latency, bars, elapsed, yjit ? 'on' : 'off', p.warm_up)
      gap = out.underruns.sum(&:last)
      puts format('underruns: %d (%s ms of silence)%s, smallest queue before a write %s ms',
        out.underruns.length, SceneProfile.ms(gap),
        out.underruns.empty? ? '' : ", at bars #{out.underruns.first(10).map { |b, g| format('%.2f (%s ms)', b, SceneProfile.ms(g)) }.join(', ')}",
        out.min_level.finite? ? SceneProfile.ms(out.min_level) : '-')
      puts format('form warm-up: %d tracks in %.1f s', *SceneProfile.warmed) if SceneProfile.warmed
      SceneProfile.report_blocks(p.top, realtime: true)
      puts "late blocks: #{late.map { |l| format('%s %.0f ms late', l[:description], l[:late] * 1000) }.join(', ')}" unless late.empty?
      SceneProfile.report_buffers(p.top, p.buffer)
    else
      out = SceneProfile::CountingOutput.new(p.buffer)
      t0 = SceneProfile.clock
      begin
        $stdout = quiet
        MB::Sound.render(out, bars: bars, buffer_size: p.buffer) {
          SceneProfile.recording(:setup) { runner.send(:arrange_song, &block) }
        }
      ensure
        $stdout = STDOUT
      end
      elapsed = SceneProfile.clock - t0

      puts format('%s: offline render, %d-frame buffers, %d bars in %.1f s, YJIT %s, form warm-up %s',
        File.basename(song), p.buffer, bars, elapsed, yjit ? 'on' : 'off', p.warm_up)
      setup = SceneProfile.phase_text(:setup, 6)
      puts format('form warm-up: %d tracks in %.1f s', *SceneProfile.warmed) if SceneProfile.warmed
      puts "before the first buffer: #{setup}" unless setup.empty?
      SceneProfile.report_blocks(p.top, realtime: false)
      SceneProfile.report_buffers(p.top, p.buffer)
    end
  }
end
