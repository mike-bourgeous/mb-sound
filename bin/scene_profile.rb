#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
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
#
# Every buffer also gets the render thread's own CPU time (wall time
# above it is time the thread waited, e.g. for the GVL while the scheduler
# thread built a scene) and its time outside the players (changes
# landing, catch-up and sleep bookkeeping, master and bus chains: the
# Session's own work), with the buffers that spent most outside the
# players listed apart (how ux-fix-2 found scene-change work on the
# render thread; omnibus10).
# - realtime (-R): played in a realtime Session on an emulated sound card
#   (a 48 kHz clock draining a queue of --latency ms; writes wait while it
#   is full, like DeviceOutput), with blocks on the scheduler thread as
#   live; reports underruns (where and how long), render times, and each
#   slow block's slack (how long before its time it finished).  Takes
#   real time: about two seconds per bar.
#
# YJIT counters (compile time, invalidations) are shown with YJIT on (the
# shebang turns it on; `ruby bin/scene_profile.rb` runs without it).
# Every report has the buffers over 10/20/50/80 ms (an output queue
# shorter than that runs dry there), YJIT compile per buffer and block
# (new methods and basic blocks, invalidations, code GC), and GC counts
# with the reasons for major GCs; with RUBYOPT='--yjit-disable
# --yjit-log=quiet' (--yjit-disable keeps Ruby from starting YJIT itself,
# which would fix Ruby's call threshold of 30 instead of MB::Sound::JIT's), the
# slowest buffers also list what compiled in them ("blocks for new types
# or shapes" are YJIT chain versions; SCENE_PROFILE_JIT_TOP=N lists N
# methods instead of 6).  The profiler's own hooks compile in the first
# live buffers too (the sandboxes skip them), so read past
# bin/scene_profile.rb lines there.  Offline renders play once with
# loudness: false, as live (a mastered song's targeted render would play
# it twice, recording every buffer).  -R --band also paints the terminal
# UI's deck (to /dev/null) as a song's --ui does.  Container realtime
# runs see outside stalls (on the Mac's Docker VM, ~0.3-0.8 s of 5-10x
# slower CPU at the top of every wall-clock minute, scene-jit-1): check
# underrun times against a probe process before blaming the code.
#
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
#     bin/scene_profile.rb -R --band -n 512 -l 50 bin/songs/memory_card.rb -- --ui
#     RUBYOPT='--yjit-disable --yjit-log=quiet' bin/scene_profile.rb -n 128 bin/songs/memory_card.rb
#     MB_SOUND_YJIT_CALL_THRESHOLD=30 bin/scene_profile.rb -n 128 bin/songs/memory_card.rb  # Ruby's default threshold

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
    attr_accessor :landed, :players, :buffer_size, :realtime

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # This thread's CPU seconds.
    def cpu = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)

    YJIT_KEYS = %i[compile_time_ns compiled_iseq_count compiled_block_count invalidation_count invalidate_everything code_gc_count inline_code_size outlined_code_size].freeze

    def yjit
      return {} unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      RubyVM::YJIT.runtime_stats.slice(*YJIT_KEYS)
    end

    # The YJIT log's entries ([Time, "method@file:line (index: n)"], the
    # last 1024) since wall-clock +t0+ (seconds), or nil without
    # --yjit-log (see --jit-log).
    def jit_log_since(t0)
      log = RubyVM::YJIT.log if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:log)
      log&.select { |t, _| t.to_f >= t0 }&.map(&:last)
    end

    def wall = Process.clock_gettime(Process::CLOCK_REALTIME)

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
      # (the form warm-up's rehearsal sandbox: timed as the warm-up)
      return super if Thread.current[:scene_profile]&.[](:key) == :warm_up

      b = { id: SceneProfile.blocks.length, desc: entry.description.delete_prefix('form: '), bar: @transport.bar_at(time).to_f, gc0: GC.stat(:time), a0: GC.stat(:total_allocated_objects), y0: SceneProfile.yjit, w0: SceneProfile.wall, t0: SceneProfile.clock, c0: SceneProfile.cpu }
      SceneProfile.blocks << b
      SceneProfile.recording(b[:id]) { super }
    ensure
      finish(b, time) if b
    end

    private

    def finish(b, time)
      b[:secs] = SceneProfile.clock - b[:t0]
      b[:cpu] = SceneProfile.cpu - b[:c0]
      b[:gc] = GC.stat(:time) - b[:gc0]
      b[:alloc] = GC.stat(:total_allocated_objects) - b[:a0]
      b[:yjit] = SceneProfile.ydelta(b[:y0], SceneProfile.yjit)
      b[:jit] = SceneProfile.jit_log_since(b[:w0]) if b[:yjit][:compile_time_ns].to_i > 1_000_000
      b[:slack] = @transport.seconds_of(time - @transport.position).to_f
    end
  end

  # Times render buffers (without scheduled blocks run inline or the
  # output's write) and each player in them.
  module SessionHook
    def process_buffer(count = buffer_size, **kw)
      return super unless output.is_a?(EmuOutput) || output.is_a?(CountingOutput)

      nb = SceneProfile.blocks.length
      # (in a module variable, not an instance variable of the Session: a
      # variable only the profiled Session had changed its shape, and YJIT
      # compiled new versions of the Session's code in the first live
      # buffers; alloc-2)
      SceneProfile.players = players = {}
      SceneProfile.landed = 0
      gc0 = GC.stat(:time)
      a0 = GC.stat(:total_allocated_objects)
      majors = GC.stat(:major_gc_count)
      y0 = SceneProfile.yjit
      w0 = SceneProfile.wall
      t0 = SceneProfile.clock
      c0 = SceneProfile.cpu
      r = super
      # Offline, scheduled blocks run inside the buffer (realtime, on the
      # scheduler thread)
      offline = output.instance_of?(CountingOutput)
      inline = offline ? SceneProfile.blocks[nb..].sum { |b| b[:secs] || 0 } : 0
      inline_cpu = offline ? SceneProfile.blocks[nb..].sum { |b| b[:cpu] || 0 } : 0
      secs = SceneProfile.clock - t0 - inline - output.write_secs
      cpu = SceneProfile.cpu - c0 - inline_cpu - output.write_cpu
      yd = SceneProfile.ydelta(y0, SceneProfile.yjit)
      # (offline, the scheduled blocks' own compiling is theirs)
      yd[:compile_time_ns] -= SceneProfile.blocks[nb..].sum { |b| b[:yjit]&.[](:compile_time_ns).to_i } if offline && yd[:compile_time_ns]
      SceneProfile.buffers << {
        secs: secs, cpu: cpu, other: secs - players.sum { |_, v| v },
        gc: GC.stat(:time) - gc0, yjit: yd, landed: SceneProfile.landed,
        # (objects allocated during the buffer, scheduled blocks run inline
        # left out; realtime, other threads' allocations meanwhile count)
        alloc: GC.stat(:total_allocated_objects) - a0 - (offline ? SceneProfile.blocks[nb..].sum { |b| b[:alloc] || 0 } : 0),
        major: (GC.latest_gc_info(:major_by) if GC.stat(:major_gc_count) != majors),
        players: players, bar: transport.bar_at(transport.position).to_f,
        jit: (SceneProfile.jit_log_since(w0) if yd[:compile_time_ns].to_i > 1_000_000),
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
      SceneProfile.players["#{p.name}#{first ? '*' : ''}"] = SceneProfile.clock - t0 if SceneProfile.players
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
    def write_cpu = 0
    def close; end
    def closed? = false
  end

  # An emulated sound card: a 48 kHz clock drains a queue; #write waits
  # while more than +latency+ seconds are queued (like DeviceOutput) and
  # counts underruns (the queue running dry).
  class EmuOutput < CountingOutput
    attr_reader :write_secs, :write_cpu, :min_level, :latency

    # Each underrun: [bar, seconds of silence].
    attr_reader :underrun_list

    # How many underruns (as DeviceOutput#underruns, which the UI shows).
    def underruns = @underrun_list.length

    def initialize(buffer_size, latency, transport)
      super(buffer_size)
      @latency = latency
      @transport = transport
      @t0 = nil
      @frames = 0
      @underrun_list = []
      @min_level = Float::INFINITY
      @write_secs = 0
      @write_cpu = 0
    end

    def write(data)
      w0 = SceneProfile.clock
      c0 = SceneProfile.cpu
      if @t0
        level = @frames / @sample_rate - (w0 - @t0)
        if level < 0
          @underrun_list << [@transport.bar_at(@transport.position).to_f, -level]
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
      @write_cpu = SceneProfile.cpu - c0
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

    def rehearse(*a, **k)
      t0 = SceneProfile.clock
      result = SceneProfile.recording(:warm_up) { super }
      SceneProfile.rehearsed = [result, SceneProfile.clock - t0] if result
      result
    end
  end

  class << self
    attr_accessor :form_warm_up, :warmed, :rehearsed, :gc

    # "8 tracks in 2.0 s" and the rehearsal's sections, for the reports.
    def warm_up_text
      text = format('%d tracks in %.1f s', *@warmed)
      text += format(' (%d sections rehearsed in %.1f s of it)', *@rehearsed) if @rehearsed
      text
    end

    def ms(s) = format('%.1f', s * 1000)

    def yjit_text(y)
      return '' if y.nil? || y.empty?
      text = "YJIT compile #{(y[:compile_time_ns] / 1e6).round} ms"
      text += " (#{y[:compiled_iseq_count]} new methods, #{y[:compiled_block_count]} blocks)" if y[:compiled_block_count].to_i > 0
      text += ", #{y[:invalidation_count]} invalidations" if y[:invalidation_count].to_i > 0
      text += ", invalidated everything #{y[:invalidate_everything]}x" if y[:invalidate_everything].to_i > 0
      text += ", code GC #{y[:code_gc_count]}x" if y[:code_gc_count].to_i > 0
      text
    end

    # The methods the YJIT log saw compiled in +entries+ (log lines), most
    # blocks first: "name@file:line xN".
    def jit_text(entries, top)
      return nil unless entries&.any?
      chained = entries.count { |e| e.include?('chain_depth') }
      counts = entries.map { |e| e.sub(/ \(index: \d+(, chain_depth: \d+)?\)\z/, '').sub(%r{\A(.*@)(?:.*/)?(lib|bin|gems)/}, '\\1\\2/') }.tally
      list = counts.sort_by { |_, c| -c }.first(top).map { |n, c| c > 1 ? "#{n} x#{c}" : n }
      more = counts.length > top ? ", ... (#{counts.length} methods, #{entries.length} blocks)" : ''
      chain = chained > 0 ? " [#{chained} blocks for new types or shapes]" : ''
      "compiled: #{list.join(', ')}#{more}#{chain}"
    end

    # Buffer-time thresholds (ms) for the distribution: an output queue
    # shorter than a buffer's time runs dry there.
    THRESHOLDS = [10, 20, 50, 80].freeze

    def report_distribution(where)
      return if @buffers.empty?
      parts = THRESHOLDS.map { |ms|
        over = @buffers.select { |b| b[:secs] * 1000 > ms }
        jit = over.count { |b| b[:yjit][:compile_time_ns].to_i > 1_000_000 }
        gc = over.count { |b| b[:gc] > 1 }
        "> #{ms} ms: #{over.length} (#{jit} compiling, #{gc} with GC)"
      }
      puts "  buffers #{parts.join('; ')}"
      return unless @buffers.first[:yjit].key?(:compile_time_ns)
      total = @buffers.sum { |b| b[:yjit][:compile_time_ns].to_i } / 1e6
      busy = @buffers.count { |b| b[:yjit][:compile_time_ns].to_i > 1_000_000 }
      landing = @buffers.select { |b| b[:landed] > 0 }.sum { |b| b[:yjit][:compile_time_ns].to_i } / 1e6
      gcs = @buffers.sum { |b| b[:yjit][:code_gc_count].to_i }
      puts format('  YJIT compile %s: %.0f ms in all, %d buffers over 1 ms, %.0f ms where changes landed; code GC %dx',
        where, total, busy, landing, gcs)
      if @gc
        gcb = @buffers.select { |b| b[:gc] > 10 }
        puts format('  GC from the song\'s start: %d minor, %d major, %d ms in all (warm-up included); buffers with over 10 ms of GC: %d%s',
          @gc[:minor_gc_count], @gc[:major_gc_count], @gc[:time], gcb.length, gcb.empty? ? '' : " (longest #{gcb.map { |b| b[:gc] }.max} ms)")
        music = @buffers.length * (@buffer_size || 512) / 48000.0
        puts format('  objects allocated from the song\'s start: %.2f M (every thread, warm-up included; %.0f k per second of the %.0f s rendered)',
          @gc[:total_allocated_objects] / 1e6, @gc[:total_allocated_objects] / 1e3 / music, music) if @gc[:total_allocated_objects] && music > 0
        al = @buffers.drop(@buffers.length / 8).map { |b| b[:alloc] }.compact.sort
        unless al.empty?
          puts format('  objects allocated in render buffers (after the first eighth): mean %.0f, p50 %d, p99 %d, max %d per buffer; %.0f k per second%s',
            al.sum.to_f / al.length, al[al.length / 2], al[(al.length * 0.99).floor], al[-1], al.sum.to_f / al.length * 48000 / (@buffer_size || 512) / 1e3,
            @buffers.first.key?(:players) && SceneProfile.realtime ? ' (with what other threads allocated meanwhile)' : '')
        end
        why = @buffers.filter_map { |b| b[:major] }.tally
        puts "  major GCs started in buffers, by reason (GC.latest_gc_info :major_by): #{why.map { |k, v| "#{k} #{v}" }.join(', ')}" unless why.empty?
      end
      st = RubyVM::YJIT.runtime_stats
      kinds = st.select { |k, v| k.start_with?('invalidate_') && v.to_i > 0 }.map { |k, v| "#{k.to_s.delete_prefix('invalidate_')} #{v}" }
      puts format('  YJIT at the end: %d methods compiled, %.1f MB of code (%.1f MB of exec memory used), invalidations %s',
        st[:compiled_iseq_count], (st[:inline_code_size] + st[:outlined_code_size]) / 1e6, st[:code_region_size] / 1e6, kinds.empty? ? 'none' : kinds.join(', '))
      puts format('  YJIT memory: %.1f MB of metadata; process RSS %s', st[:yjit_alloc_size].to_i / 1e6, rss_text)
    end

    # Where YJIT's call threshold came from (Ruby fixes it when YJIT starts).
    def threshold_text
      t = MB::Sound::JIT.threshold
      t ? "YJIT call threshold #{t} (MB::Sound::JIT)" : "YJIT started by Ruby's own options (call threshold 30 unless --yjit-call-threshold)"
    end

    # Current and peak resident memory from /proc (Linux), else ps.
    def rss_text
      status = File.read('/proc/self/status')
      mb = ->(key) { status[/^#{key}:\s+(\d+) kB/, 1].to_i / 1024.0 }
      format('%.0f MB (peak %.0f MB)', mb.('VmRSS'), mb.('VmHWM'))
    rescue SystemCallError
      format('%.0f MB', `ps -o rss= -p #{Process.pid}`.to_i / 1024.0)
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
        jit = jit_text(b[:jit], (ENV["SCENE_PROFILE_JIT_TOP"] || 6).to_i)
        puts "      #{jit}" if jit
      end
    end

    # (+realtime+: the YJIT counters, process-wide, count every thread's
    # compiling while a buffer rendered: the scheduler's, the painter's)
    def report_buffers(top, buffer, realtime: false)
      where = realtime ? 'while buffers rendered (any thread)' : 'on the render thread'
      return if @buffers.empty?
      stats = ->(key) {
        t = @buffers.map { |b| b[key] }.sort
        [t.sum / t.length, t[(0.99 * (t.length - 1)).round], t.last]
      }
      mean, p99, max = stats.(:secs)
      puts format('render buffers: %d, mean %s ms, p99 %s ms, max %s ms (a buffer is %.2f ms)',
        @buffers.length, ms(mean), ms(p99), ms(max), buffer * 1000.0 / 48000)
      puts format('  render thread CPU: mean %s ms, p99 %s ms, max %s ms (wall above CPU: waiting, e.g. for the GVL)', *stats.(:cpu).map { |v| ms(v) })
      puts format('  outside the players (changes, catch-up, master and bus chains): mean %s ms, p99 %s ms, max %s ms', *stats.(:other).map { |v| ms(v) })
      report_distribution(where)
      landing = @buffers.select { |b| b[:landed] > 0 }
      unless landing.empty?
        puts format('  where changes landed: %d buffers, mean %s ms, max %s ms', landing.length, ms(landing.sum { |b| b[:secs] } / landing.length), ms(landing.map { |b| b[:secs] }.max))
      end
      puts '  slowest (* a player\'s first buffer):'
      @buffers.sort_by { |b| -b[:secs] }.first(top).each do |b|
        players = b[:players].sort_by { |_, v| -v }.first(4).map { |n, v| "#{n} #{ms(v)}" }.join(', ')
        extra = [("GC #{b[:gc]} ms" if b[:gc] > 0), yjit_text(b[:yjit]).then { |t| t.empty? || b[:yjit][:compile_time_ns] < 1e6 ? nil : t }, ("#{b[:landed]} change#{b[:landed] == 1 ? "" : "s"} landed" if b[:landed] > 0)].compact.join('; ')
        puts format('    bar %6.2f %7s ms (CPU %s, outside players %s)%s  %s', b[:bar], ms(b[:secs]), ms(b[:cpu]), ms(b[:other]), extra.empty? ? '' : " (#{extra})", players)
        jit = jit_text(b[:jit], (ENV["SCENE_PROFILE_JIT_TOP"] || 6).to_i)
        puts "        #{jit}" if jit
      end
      compiling = @buffers.select { |b| b[:yjit][:compile_time_ns].to_i > 1_000_000 }
      unless compiling.empty?
        puts "  most YJIT compile #{where}:"
        compiling.sort_by { |b| -b[:yjit][:compile_time_ns] }.first(top).each do |b|
          puts format('    bar %6.2f %7s ms of %s ms%s', b[:bar], ms(b[:yjit][:compile_time_ns] / 1e9), ms(b[:secs]),
                      b[:landed] > 0 ? " (#{b[:landed]} change#{b[:landed] == 1 ? '' : 's'} landed)" : '')
          jit = jit_text(b[:jit], 4)
          puts "        #{jit}" if jit
        end
      end
      puts '  most time outside the players:'
      @buffers.sort_by { |b| -b[:other] }.first(top).each do |b|
        puts format('    bar %6.2f %7s ms outside players of %s ms (CPU %s)%s', b[:bar], ms(b[:other]), ms(b[:secs]), ms(b[:cpu]),
                    b[:landed] > 0 ? " (#{b[:landed]} change#{b[:landed] == 1 ? '' : 's'} landed)" : '')
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
    band: [false, 'With -R, also paint the terminal UI\'s deck (to /dev/null, as with a song\'s --ui) while it plays'],
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
    startup = MB::Sound.warm_up # as live scripts do
    SceneProfile.buffer_size = p.buffer
    SceneProfile.realtime = p.realtime
    # The profiler's own hooks run only for the profiled Session, so they
    # compiled in its first buffers (half of bar 1's compiling at 128
    # frames, counted as the song's; alloc-2): run them on a throwaway
    # Session first, and forget what it recorded
    begin
      box = MB::Sound::Session.new(realtime: false, output: SceneProfile::CountingOutput.new(p.buffer), buffer_size: p.buffer, channels: 2,
        transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      MB::Sound::Session.with_context(session: box) do
        box.add(0.constant, on: :now)
        60.times { box.process_buffer }
      end
    ensure
      box&.close
      SceneProfile.buffers.clear
    end
    quiet = File.open(File::NULL, 'w')

    if p.realtime
      transport = MB::Sound.transport
      out = SceneProfile::EmuOutput.new(p.buffer, p.latency / 1000.0, transport)
      MB::Sound::Session.use_output(out)
      session = MB::Sound::Session.default
      t0 = SceneProfile.clock
      band = nil
      begin
        $stdout = quiet
        if p.band
          MB::Sound::UI.warm_up # (as ScriptRunner does before a song's --ui screen)
          band = MB::Sound::UI::Band.new(layout: MB::Sound::UI.layouts[:deck], io: quiet, size: [40, 160], session: session)
        end
        gc0 = GC.stat.slice(:minor_gc_count, :major_gc_count, :time, :total_allocated_objects)
        SceneProfile.recording(:setup) { runner.send(:arrange_song, &block) }
        band&.start
        play0 = [GC.stat.slice(:total_allocated_objects, :minor_gc_count, :major_gc_count, :time), SceneProfile.clock]
        end_pos = session.transport.bar_position(bars + 1)
        sleep 0.05 until session.transport.position >= end_pos || (session.idle? && !session.schedule_due?)
        play1 = [GC.stat.slice(:total_allocated_objects, :minor_gc_count, :major_gc_count, :time), SceneProfile.clock]
      ensure
        band&.stop
        $stdout = STDOUT
        late = session.late_blocks
        session.close
      end
      SceneProfile.gc = GC.stat.slice(:minor_gc_count, :major_gc_count, :time, :total_allocated_objects).to_h { |k, v| [k, v - gc0[k]] } if gc0
      elapsed = SceneProfile.clock - t0

      puts format('%s: realtime, %d-frame buffers, emulated card with a %.0f ms queue, %d bars in %.1f s, YJIT %s, form warm-up %s',
        File.basename(song), p.buffer, p.latency, bars, elapsed, yjit ? 'on' : 'off', p.warm_up)
      puts format('MB::Sound.warm_up: %.2f s; %s', startup, SceneProfile.threshold_text) if startup
      gap = out.underrun_list.sum(&:last)
      puts format('underruns: %d (%s ms of silence)%s, smallest queue before a write %s ms',
        out.underrun_list.length, SceneProfile.ms(gap),
        out.underrun_list.empty? ? '' : ", at bars #{out.underrun_list.first(10).map { |b, g| format('%.2f (%s ms)', b, SceneProfile.ms(g)) }.join(', ')}",
        out.min_level.finite? ? SceneProfile.ms(out.min_level) : '-')
      if play0 && play1
        d = play1[0].to_h { |k, v| [k, v - play0[0][k]] }
        secs = play1[1] - play0[1]
        puts format('while playing (%.1f s, every thread): %.0f k objects allocated per second; GC %d minor, %d major, %d ms (%.1f%% of the time)',
          secs, d[:total_allocated_objects] / 1e3 / secs, d[:minor_gc_count], d[:major_gc_count], d[:time], 100.0 * d[:time] / 1000 / secs)
      end
      puts "form warm-up: #{SceneProfile.warm_up_text}" if SceneProfile.warmed
      warm = SceneProfile.phase_text(:warm_up, 6)
      puts "  warm-up phases: #{warm}" unless warm.empty?
      SceneProfile.report_blocks(p.top, realtime: true)
      puts "late blocks: #{late.map { |l| format('%s %.0f ms late', l[:description], l[:late] * 1000) }.join(', ')}" unless late.empty?
      SceneProfile.report_buffers(p.top, p.buffer, realtime: true)
    else
      out = SceneProfile::CountingOutput.new(p.buffer)
      t0 = SceneProfile.clock
      gc0 = GC.stat.slice(:minor_gc_count, :major_gc_count, :time, :total_allocated_objects)
      begin
        $stdout = quiet
        # (loudness: false: one pass, as live; a mastered song's targeted
        # render would play it twice, the first pass recording every buffer)
        MB::Sound.render(out, bars: bars, buffer_size: p.buffer, loudness: false) {
          SceneProfile.recording(:setup) { runner.send(:arrange_song, &block) }
        }
      ensure
        $stdout = STDOUT
      end
      SceneProfile.gc = GC.stat.slice(:minor_gc_count, :major_gc_count, :time, :total_allocated_objects).to_h { |k, v| [k, v - gc0[k]] }
      elapsed = SceneProfile.clock - t0

      puts format('%s: offline render, %d-frame buffers, %d bars in %.1f s, YJIT %s, form warm-up %s',
        File.basename(song), p.buffer, bars, elapsed, yjit ? 'on' : 'off', p.warm_up)
      puts format('MB::Sound.warm_up: %.2f s; %s', startup, SceneProfile.threshold_text) if startup
      setup = SceneProfile.phase_text(:setup, 6)
      puts "form warm-up: #{SceneProfile.warm_up_text}" if SceneProfile.warmed
      warm = SceneProfile.phase_text(:warm_up, 6)
      puts "  warm-up phases: #{warm}" unless warm.empty?
      puts "before the first buffer: #{setup}" unless setup.empty?
      SceneProfile.report_blocks(p.top, realtime: false)
      SceneProfile.report_buffers(p.top, p.buffer)
    end
  }
end
