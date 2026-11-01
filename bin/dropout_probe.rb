#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Plays a song live through the sound card and tells where its dropouts
# come from (dropout-probe-1, 2026-11-01; the maintainer's 2026-10-31 UI
# notes: xruns climbing about 5 a minute at 7-10% load, the adaptive queue
# going 50 <-> 75 ms).  MB::Sound::DropoutProbe logs every counted
# underrun with what was happening in the window before it: the render
# thread's writes (render time and CPU, its waits for room, how late it
# woke, the GVL back), its GVL waits and who held the GVL, times it was
# blocked off the GVL (the render lock), every GC step (major or minor,
# which thread), YJIT compile time, the adaptive queue (limit, shrinks,
# backoff), and a LatencyProbe's system stalls and load, CPU, and free
# memory.  Each dropout gets a likely cause: GC, render overrun, GVL
# (render thread starved), lock, system stall, YJIT, device side, queue
# shrink, startup, or unexplained.  At the end (--seconds, the song's end,
# or Ctrl-C; q with --ui): a report on stdout and, beside --json, a .json
# log, a .csv of dropouts, the report as .txt, and the LatencyProbe's
# report and plots in <base>-latency/.
#
# The probe adds clock reads and stores to the render and device threads
# (a C trace in FastAudio::Playback and GVLProbe's thread hook); its own
# thread reads them every 0.1 s.
#
# --song is a genre (techno, dnb, house, ambient, funk, jungle: its
# endless form, which plays until --seconds) or a song script in
# bin/songs (tunnel_vision, memory_card, ...; ends with the song) or a path.
# The usual song options work: --ui [LAYOUT] (the tiles, as in a live
# session), -L/--latency-profile, --master, --bpm.
#
# --inject KIND makes dropouts on purpose, every --every seconds, each
# --stall ms long, to check the report's causes: render (the render thread
# spins in a tap), gvl (another thread holds the GVL), gc (a full GC from
# another thread, with ballast so it takes --stall), lock (another thread
# holds the render lock, asleep), system (the whole process stopped with
# SIGSTOP from a helper process, so the probe's thread sees it too), or
# all (each in turn).  The report then lists each injection and the cause
# its dropout got.
#
# Usage: bin/dropout_probe.rb [options]
#
# On the Mac (natively, with the sound card):
#     bin/dropout_probe.rb --seconds 300 --json tmp/dropouts_mac.json
#     bin/dropout_probe.rb --seconds 300 --ui --json tmp/dropouts_mac_ui.json        # with the tiles up
#     bin/dropout_probe.rb --seconds 300 --gc quiet --json tmp/dropouts_mac_quiet.json
#     bin/dropout_probe.rb --song tunnel_vision --ui --json tmp/dropouts_tv.json
#     bin/dropout_probe.rb --seconds 60 --inject all --json tmp/dropouts_inject.json  # check the causes
# In the container (no sound card: miniaudio's null device):
#     OUTPUT_TYPE=device AUDIO_BACKEND=null bin/dropout_probe.rb --seconds 40 --inject all
#
# Any live script can be probed too: MB_SOUND_DROPOUT_PROBE=1 (or a .json
# path) bin/songs/memory_card.rb --ui.  In bin/sound.rb:
#     probe = MB::Sound::DropoutProbe.start(MB::Sound::Session.current, json: 'tmp/dropouts_console.json')
#     ...                                     # play, load things, take notes
#     probe.finish

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # Makes dropouts on purpose (--inject) so the probe's causes can be
  # checked: #marks lists [monotonic ns, kind] for each one.
  class DropoutInjector
    KINDS = %i[render gvl gc lock system].freeze

    attr_reader :marks

    def initialize(session, kinds, every:, stall:, first: 4.0)
      @session = session
      @kinds = kinds
      @every = every
      @stall = stall
      @first = first
      @marks = []
      @due = nil
      @tap = nil
      @thread = nil
      @ballast = nil
      @helper = nil
      @helper_in = nil
      @stopping = false
    end

    # Prepares what the kinds need (before playback: ballast for :gc, the
    # helper process for :system), then starts the thread that injects.
    def start
      prepare_gc if @kinds.include?(:gc)
      prepare_system if @kinds.include?(:system)
      if @kinds.include?(:render)
        stall = @stall
        @tap = @session.add_tap { |_| (@due = nil; FastLatency.spin(stall)) if @due }
      end
      @thread = Thread.new { run }
      @thread.name = 'dropout-inject'
      ExitClose.register(self)
      self
    end

    def close
      @stopping = true
      @thread&.kill
      @session.remove_tap(@tap) if @tap
      if @helper
        @helper_in&.close rescue nil
        Process.kill(:CONT, Process.pid)
        Process.wait(@helper) rescue nil
        @helper = nil
      end
      ExitClose.unregister(self)
    end

    private

    def run
      sleep @first
      i = 0
      until @stopping
        kind = @kinds[i % @kinds.length]
        i += 1
        @marks << [DropoutProbe.mono_ns, kind]
        inject(kind)
        sleep @every
      end
    end

    def inject(kind)
      case kind
      when :render then @due = true
      when :gvl then FastLatency.spin(@stall)
      when :gc then GC.start(full_mark: true, immediate_sweep: true)
      when :lock then @session.with_render_lock { sleep @stall }
      when :system then @helper_in.puts('stop') && @helper_in.flush
      end
    end

    # Grows a retained heap until a full GC takes at least --stall (twice
    # it measured here: collections while playing ran about half as long),
    # up to about 6 million objects.
    def prepare_gc
      @ballast = []
      loop do
        t = MB::U.clock_now
        2.times { GC.start(full_mark: true, immediate_sweep: true) }
        took = (MB::U.clock_now - t) / 2
        break if took >= 2 * @stall || @ballast.length >= 40

        @ballast << Array.new(50_000) { |j| [j, j.to_s] }
      end
    end

    # A shell that stops this process for --stall each time it reads a line
    # (started before playback: starting processes while a Session plays
    # holds the GVL through the fork).
    def prepare_system
      r, w = IO.pipe
      @helper = Process.spawn('sh', '-c', "while read x; do kill -STOP #{Process.pid}; sleep #{@stall}; kill -CONT #{Process.pid}; done", in: r)
      r.close
      @helper_in = w
    end
  end

  if main_script?(__FILE__)
    song_script(
      song: ['techno', String, '-S', 'A genre (its endless form: techno, dnb, house, ambient, funk, jungle), a song script in bin/songs (tunnel_vision, memory_card, ...), or a path'],
      seconds: [300.0, Float, '-s', 'How long to probe (0: until the song ends or Ctrl-C)', 0.0..86_400.0],
      json: [nil, String, '-J', 'The JSON log (the .csv and .txt go beside it; default tmp/dropout_probe/<song>-<time>.json)'],
      gc: [:normal, Symbol, 'GC mode while playing: normal, or quiet (majors held off, as the console\'s `gc :quiet`)', %i[normal quiet]],
      system: [true, 'Run the LatencyProbe beside it (system stalls, load, CPU, memory)'],
      ticker: [false, "The LatencyProbe's Ruby ticker too (adds GVL traffic of its own)"],
      inject: ['none', String, 'Make dropouts on purpose: render, gvl, gc, lock, system, all (each in turn), or a list (gvl,lock)'],
      every: [5.0, Float, 'Seconds between injected dropouts', 0.5..3600.0],
      stall: [150.0, Float, 'Milliseconds each injected stall lasts', 1.0..10_000.0],
      quiet_probe: [false, 'No line per dropout while playing'],
    ) { |p|
      session = Session.current
      raise ScriptRunner::InputError, 'The dropout probe plays live (a render has no dropouts): leave out -o' unless session.realtime?

      name = File.basename(p.song.to_s.delete_prefix(':'), '.rb')
      json = p.json || DropoutProbe.default_path(name)
      GCQuiet.hold if p.gc == :quiet

      injector = nil
      kinds = p.inject.split(',').map { |k| k.strip.delete_prefix(':').to_sym }
      kinds = DropoutInjector::KINDS if kinds == [:all]
      kinds = [] if kinds == [:none]
      bad = kinds - DropoutInjector::KINDS
      raise ScriptRunner::InputError, "Unknown --inject #{bad.join(', ')} (#{DropoutInjector::KINDS.join(', ')}, all, none)" unless bad.empty?
      injector = DropoutInjector.new(session, kinds, every: p.every, stall: p.stall / 1000.0, first: [p.every, 4.0].min) unless kinds.empty?

      DropoutProbe.arm(
        json: json, name: name, system: p.system, ticker: p.ticker, quiet: p.quiet_probe,
        seconds: p.seconds > 0 ? p.seconds : nil, on_done: -> { Thread.main.raise(Interrupt) },
        marks: injector, meta: { song: p.song, gc_mode: p.gc.to_s, inject: kinds.map(&:to_s), stall_ms: p.stall, every_s: p.every },
      )

      song = p.song.to_s.delete_prefix(':')
      if Genre.names.include?(song.to_sym)
        genre(song.to_sym).endless.play
      else
        path = [song, File.join(__dir__, 'songs', song), File.join(__dir__, 'songs', "#{song}.rb")].find { |f| File.file?(f) }
        raise ScriptRunner::InputError, "No genre or song script #{p.song.inspect} (genres: #{Genre.names.join(', ')}; or a script in bin/songs)" unless path

        ScriptRunner.replay_song(path)
      end
      injector&.start
    }
  end
end
