#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Plays a song script live, with Ruby's GC disabled once the music starts,
# and reports how fast memory grows (MB and objects per second of audio)
# and, with --sites, which source lines allocate it (dropouts-2,
# 2026-10-28; the maintainer: "I'd like to be able to run for an hour with
# GC off").
#
# Live-equivalent: the song runs as `bin/songs/x.rb` does without -o (its
# warm-up and rehearsal, a realtime Session with its render and scheduler
# threads, the form, takes and journal as a script keeps them), but on a
# NullOutput with a virtual clock that this tool lets through at --speed
# times real time (1 by default: like a sound card), so nothing depends on
# a sound card, and --speed 4 plays a 4-minute song in about a minute.
# --band also paints the terminal UI's deck (to /dev/null) as a song's
# --ui does, with its Poll and painter threads.
#
# When the first audio is waited for (after the song's setup, warm-up, and
# rehearsal), the tool runs GC.start and GC.disable (--gc on leaves the GC
# running), then samples RSS and GC.stat every audio second.  The report:
# the first window's growth (--window seconds, 60 by default: landings,
# first buffers, scene builds) and the steady slope after it (MB per audio
# second, objects per audio second, bytes per object), the render
# thread's share (objects allocated inside Session#process_buffer on the
# render thread), and how long 4 GB would last.  --sites N traces every
# allocation (ObjectSpace.trace_object_allocations; ~2x slower) and lists
# the N lines allocating the most bytes per audio second after the
# window, by category (render: graph nodes and the Session's render path;
# builds: scene and patch builds, plans, recipes; scheduler; journal and
# takes; UI; MIDI), from a walk of the heap at the window's end and at
# the end (GC is off, so every object is still there).
#
# --budget MB exits with status 1 if the steady slope is over MB per audio
# second (the soak spec's check).
#
# Usage: bin/gc_soak.rb [options] SONG_SCRIPT [-- song options]
#     bin/gc_soak.rb bin/songs/tunnel_vision.rb
#     bin/gc_soak.rb -n 128 --speed 2 --sites 30 bin/songs/tunnel_vision.rb
#     bin/gc_soak.rb --band --seconds 120 bin/songs/night_bus_flow.rb
#     bin/gc_soak.rb --gc on bin/songs/genre_demo.rb -- -G dnb
require 'bundler/setup'
require 'objspace'
require 'mb-sound'
require 'mb/sound/ui'

module MB::Sound
  # The soak run (see bin/gc_soak.rb); one per process.
  module GCSoak
    CATEGORIES = [
      ['UI', %r{lib/mb/sound/(ui/|ui\.rb|plot/)}],
      ['MIDI', %r{lib/mb/sound/(session/midi_in|midi/live_source|midi/virtual_input|midi/capture)}],
      ['journal/take', %r{lib/mb/sound/(session/journal|take|session/decisions|session/gestures)}],
      ['scheduler', %r{lib/mb/sound/session/scheduler}],
      ['builds', %r{lib/mb/sound/(arrangement|form|graph_node/recipe|graph_io|genre|library|rack|plan/(builder|program|region|install|rebuild|lane_group|signature)|plan\.rb|preset)}],
      ['render', %r{lib/mb/sound/}],
    ].freeze

    # Stops the song once enough audio played (see --seconds).
    class Done < Exception; end # (not a StandardError: past the script runner's rescue)

    Sample = Data.define(:seconds, :rss_mb, :objects, :render_objects, :gc_count)

    class << self
      attr_accessor :speed, :limit, :window, :sites, :gc_off, :band_on, :by_count, :dump
      attr_reader :samples, :window_sites, :end_sites, :render_objects, :started

      def setup
        @samples = []
        @render_objects = 0
        @started = nil
        @window_sites = nil
        @end_sites = nil
        @last_wall = nil
        @band = nil
        @played = 0.0
        @types0 = nil
        @types1 = nil
        @chunk_at = nil
        @gen = nil
      end

      def rss_mb
        File.read('/proc/self/status')[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
      rescue SystemCallError
        Float::NAN
      end

      # Every wait for audio (Internal.wait_audio): lets +seconds+ through
      # at the --speed pace, starting the measurement on the first call.
      def wait_audio(session, seconds, out)
        start(session) unless @started
        now = MB::U.clock_now
        target = (@last_wall || now) + seconds / @speed
        sleep(target - now) if target > now
        @last_wall = [target, MB::U.clock_now - 0.25].max # (never bank more than 0.25 s)
        out.consume(seconds)
        played = (out.frames_consumed - @frame0) / session.sample_rate.to_f
        while played >= @samples.length
          @samples << Sample.new(seconds: played, rss_mb: rss_mb, objects: GC.stat(:total_allocated_objects) - @objects0,
                                 render_objects: @render_objects, gc_count: GC.count - @gc0)
        end
        chunk(played) if @sites
        @types0 ||= types if !@sites && played >= @window
        raise Done if @limit && played >= @limit
      end

      def start(session)
        @session = session
        @out = session.instance_variable_get(:@output)
        if @band_on
          @band = UI::Band.new(layout: UI.layouts[:deck], io: File.open(File::NULL, 'w'), size: [40, 160], session: session)
          @band.start
        end
        GC.start
        GC.disable if @gc_off || @sites
        if @sites
          @window_sites = Hash.new { |h, k| h[k] = [0, 0] }
          @end_sites = Hash.new { |h, k| h[k] = [0, 0] }
          @chunk_at = CHUNK
          @gen = GC.count
          ObjectSpace.trace_object_allocations_start
        end
        @frame0 = @out.frames_consumed
        @objects0 = GC.stat(:total_allocated_objects)
        @gc0 = GC.count
        @render_objects = 0
        @started = MB::U.clock_now
        @samples << Sample.new(seconds: 0.0, rss_mb: rss_mb, objects: 0, render_objects: 0, gc_count: 0)
      end

      # Live objects by type (T_* and imemo kinds) and the memory they use
        # (GC is off: everything allocated since the window is live).
        def types
          t = ObjectSpace.count_objects.reject { |k, _| k == :TOTAL || k == :FREE }
          t.merge!(ObjectSpace.count_imemo_objects) if ObjectSpace.respond_to?(:count_imemo_objects)
          y = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? RubyVM::YJIT.runtime_stats : {}
          [t, ObjectSpace.memsize_of_all, @samples[-1]&.seconds || 0.0, (y[:code_region_size] || 0) + (y[:yjit_alloc_size] || 0), GC.stat(:malloc_increase_bytes)]
        end

      def finish
        @types1 = types if @types0 && @gc_off && !@sites
        @band&.stop
        tally_into(@played.to_f >= @window ? @end_sites : @window_sites) if @sites && @started
        ObjectSpace.trace_object_allocations_stop if @sites
        GC.enable
      end

      # Render-thread allocations (see SessionHook).
      def add_render(n)
        @render_objects += n
      end

      # Seconds of audio per traced chunk (--sites): GC off for each, the
      # chunk's objects counted by site, then a GC (memory stays bounded;
      # tracing every object of a whole run with GC off ran out of memory).
      CHUNK = 2.0

      def chunk(played)
        @played = played
        return if played < @chunk_at
        if @dump && played - CHUNK >= @window
          # (one chunk's heap, internal objects too, for imemo sites)
          File.open(@dump, 'w') { |f| ObjectSpace.dump_all(output: f, since: @gen) }
          @dump = nil
        end
        tally_into(played - CHUNK < @window ? @window_sites : @end_sites)
        ObjectSpace.trace_object_allocations_clear
        GC.enable
        GC.start
        GC.disable
        @gen = GC.count
        @chunk_at += CHUNK
      end

      # Adds the objects allocated in this chunk (GC generation) to +sites+:
      # { [file, line, method] => [count, bytes] }.
      def tally_into(sites)
        root = File.expand_path('..', __dir__)
        gen = @gen
        me = File.expand_path(__FILE__)
        ObjectSpace.each_object do |o|
          next unless ObjectSpace.allocation_generation(o) == gen
          file = ObjectSpace.allocation_sourcefile(o) or next
          next if file == me || file.end_with?('bin/gc_soak.rb') # (this walk's own keys)
          s = sites[[file.delete_prefix("#{root}/").sub(%r{\A.*/gems/}, 'gem '), ObjectSpace.allocation_sourceline(o), ObjectSpace.allocation_class_path(o).to_s + '#' + ObjectSpace.allocation_method_id(o).to_s]]
          s[0] += 1
          s[1] += ObjectSpace.memsize_of(o)
        end
        sites
      end

      def category(file)
        CATEGORIES.each { |name, re| return name if "lib/mb/sound/#{file.delete_prefix('lib/mb/sound/')}".match?(re) && file.start_with?('lib/') }
        file.start_with?('gem ') ? 'gems' : 'other'
      end

      # The report (a String) and the steady slope in MB per audio second.
      def report(song, buffer_size)
        s = @samples
        return ['No audio played', nil] if s.length < 3

        w = s.find { |x| x.seconds >= @window } || s[s.length / 2]
        last = s[-1]
        steady_secs = last.seconds - w.seconds
        slope = steady_secs > 0 ? (last.rss_mb - w.rss_mb) / steady_secs : nil
        objs = steady_secs > 0 ? (last.objects - w.objects) / steady_secs : nil
        robjs = steady_secs > 0 ? (last.render_objects - w.render_objects) / steady_secs : nil
        lines = []
        lines << format('%s: %d-frame buffers, speed %.1fx, GC %s, YJIT %s%s; %.0f s of audio after the warm-up',
          File.basename(song), buffer_size, @speed, @gc_off ? 'off' : 'on', (defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?) ? 'on' : 'off',
          @band_on ? ', UI deck painting' : '', last.seconds)
        lines << format('RSS at the start %.0f MB; first %.0f s: +%.0f MB (%.0f k objects/s); after it: %s MB/s, %s k objects/s (render thread %s k/s), %s bytes/object by RSS',
          s[0].rss_mb, w.seconds, w.rss_mb - s[0].rss_mb, w.objects / [w.seconds, 1e-9].max / 1e3,
          slope ? format('%.2f', slope) : '-', objs ? format('%.1f', objs / 1e3) : '-', robjs ? format('%.1f', robjs / 1e3) : '-',
          slope && objs && objs > 0 ? format('%.0f', slope * 1024 * 1024 / objs) : '-')
        lines << format('GC runs while playing: %d', last.gc_count) unless @gc_off
        if @gc_off && slope && slope > 0
          head = 4096 - last.rss_mb
          lines << format('4 GB lasts about %.0f more minutes at this slope (%.0f minutes of audio in all)', head / slope / 60, (4096 - s[0].rss_mb - (w.rss_mb - s[0].rss_mb)) / slope / 60 + w.seconds / 60)
        end
        if @types0 && @types1
          secs = @types1[2] - @types0[2]
          d = @types1[0].to_h { |k, v| [k, v - (@types0[0][k] || 0)] }.select { |_, v| v > 0 }.sort_by { -_2 }.first(10)
          mb = ->(i) { (@types1[i] - @types0[i]) / secs / 1024.0 / 1024 }
          lines << format('after the first %.0f s, live objects by type per second: %s; object memory (ObjectSpace.memsize_of_all) +%.2f MB/s, YJIT code and metadata +%.2f MB/s',
            @window, d.map { |k, v| format('%s %.0f', k.to_s.delete_prefix('T_'), v / secs) }.join(', '), mb.(1), mb.(3))
        end
        if @sites && @end_sites && !@end_sites.empty?
          lines << '(--sites: GC ran between traced chunks, so the RSS numbers above are not a GC-off slope)'
          lines.concat(site_lines(steady_secs))
        end
        [lines.join("\n"), slope]
      end

      def site_lines(secs)
        diff = @end_sites
        out = []
        cats = Hash.new { |h, k| h[k] = [0, 0] }
        diff.each { |(f, _, _), (c, b)| x = cats[category(f)]; x[0] += c; x[1] += b }
        out << format('after the first %.0f s, by category (objects/s, KB/s):', @window)
        cats.sort_by { |_, (_, b)| -b }.each { |name, (c, b)| out << format('  %-13s %9.0f %9.1f', name, c / secs, b / secs / 1024) }
        out << "top #{@sites} lines by #{@by_count ? 'objects' : 'bytes'} (objects/s, KB/s, category, allocating method):"
        by_line = Hash.new { |h, k| h[k] = [0, 0, []] }
        diff.each { |(f, l, m), (c, b)| x = by_line[[f, l]]; x[0] += c; x[1] += b; x[2] << m }
        by_line.sort_by { |_, (c, b, _)| @by_count ? -c : -b }.first(@sites).each do |(f, l), (c, b, ms)|
          out << format('  %8.0f %8.1f  %-12s %s:%d %s', c / secs, b / secs / 1024, category(f), f, l, ms.uniq.first(2).join(', '))
        end
        out
      end
    end

    # Counts the objects the render thread allocates in each buffer.
    module SessionHook
      def process_buffer(*a, **k)
        return super unless GCSoak.started && equal?(Session.existing) && Thread.current.equal?(@thread)
        a0 = GC.stat(:total_allocated_objects)
        r = super
        GCSoak.add_render(GC.stat(:total_allocated_objects) - a0)
        r
      end
    end

    # Paces waits for audio (see GCSoak.wait_audio).
    module WaitHook
      def wait_audio(session, seconds)
        out = session&.instance_variable_get(:@output)
        return super unless out.respond_to?(:virtual?) && out.virtual? && !out.closed?
        GCSoak.wait_audio(session, seconds, out)
        nil
      end
    end
  end
end

if MB::Sound.main_script?(__FILE__)
  MB::Sound.script(
    args: 1..,
    buffer: [256, Integer, '-n', 'Buffer size in frames', 16..8192],
    speed: [1.0, Float, 'Times real time to let audio through (1: as a sound card)', 0.1..20.0],
    seconds: [nil, Float, 'Stop after this many seconds of audio (default: the whole song)', 1.0..36000.0],
    window: [60.0, Float, 'Seconds of audio counted as the start (landings, first buffers) before the steady slope', 1.0..3600.0],
    gc: ['off', String, 'Ruby GC while playing: off (GC.disable once the music starts) or on', ['off', 'on']],
    sites: [0, Integer, 'Trace allocations and list this many lines (0: none)', 0..1000],
    dump: [nil, String, 'With --sites, write one traced chunk after the window as ObjectSpace.dump_all JSON lines (internal objects too)'],
    by: ['bytes', String, 'Order --sites lines by bytes or objects', ['bytes', 'objects']],
    band: [false, 'Also paint the terminal UI\'s deck (to /dev/null), as a song\'s --ui does'],
    budget: [nil, Float, 'Exit with status 1 if the steady slope is over this many MB per audio second', 0.0..1000.0],
  ) { |args, p|
    song, *song_args = args
    raise ArgumentError, "No such song script: #{song}" unless File.file?(song)
    raise ArgumentError, "#{song} isn't a song script (song_script)" unless File.read(song).include?('song_script')

    soak = MB::Sound::GCSoak
    soak.setup
    soak.speed = p.speed
    soak.limit = p.seconds
    soak.window = p.window
    soak.sites = p.sites.positive? ? p.sites : nil
    soak.gc_off = p.gc == 'off'
    soak.band_on = p.band
    soak.by_count = p.by == 'objects'
    soak.dump = p.dump
    MB::Sound::Session.prepend(soak::SessionHook)
    MB::Sound::Internal.singleton_class.prepend(soak::WaitHook)

    out = MB::Sound::NullOutput.new(channels: 2, buffer_size: p.buffer, sleep: :virtual)
    MB::Sound::Session.use_output(out)
    ARGV.replace(song_args + ['-q'])
    program = $PROGRAM_NAME
    $PROGRAM_NAME = song
    quiet = File.open(File::NULL, 'w')
    begin
      $stdout = quiet
      load song
    rescue soak::Done
      # (--seconds)
    ensure
      $stdout = STDOUT
      $PROGRAM_NAME = program
      soak.finish
    end
    text, slope = soak.report(song, p.buffer)
    puts text
    MB::Sound::Session.default&.close
    exit 1 if p.budget && slope && slope > p.budget
  }
end
