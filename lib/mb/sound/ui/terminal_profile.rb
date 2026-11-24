module MB
  module Sound
    module UI
      # When a terminal shows what the screen writes (konsole-pacing,
      # 2026-11-21).  A terminal doesn't repaint on every write: Konsole up
      # to 25.12 (src/Emulation.cpp) restarts a 10 ms timer at every chunk
      # of output it reads and starts a 40 ms one when that isn't running;
      # the view updates when either fires.  Frames written more than 10 ms
      # apart are each shown about 10 ms after they arrive; frames written
      # closer (above about 100 a second) keep restarting the short timer,
      # so the view updates only when the long one fires, about 25 times a
      # second (the maintainer, Konsole 23.08.5 on a 120 Hz screen: "at
      # target fps 120 I see the same smoothness as target fps 30").
      # Konsole 26.04 added synchronized output (DEC 2026): the end of a
      # synchronized update shows it at once, and the tiles bracket every
      # frame with it.
      #
      # A profile models that rule (#presents: when the view updates, given
      # when output arrived) for the bench's model terminal and ui.perf's
      # report, and gives the pacer its smallest useful gap between frame
      # writes (#min_gap, for `ui.pace :terminal`).  Kinds:
      # - :bulk, a short timer restarted by each chunk and a long one that
      #   isn't (+short+, +long+ seconds; Konsole before 26.04, and foot's
      #   delayed rendering, 0.5 / 8.3 ms, outside synchronized updates);
      # - :sync, every frame shown when it arrives (the end of its DEC 2026
      #   update);
      # - :cadence, the view sampled +hz+ times a second (iTerm2's update
      #   cadence, 60 by default; WezTerm's max_fps, 60);
      # - :interval, at most one update per +short+ seconds (kitty's
      #   repaint_delay, 10 ms).
      #
      #     p = TerminalProfile.detect(xtversion: 'Konsole 23.08.5')
      #     p.presents([0.0, 0.0083, 0.0167])  # => [0.0267]
      #     p.min_gap                           # => 0.012
      TerminalProfile = Data.define(:name, :kind, :short, :long, :hz) do
        # Seconds added to the short timer for #min_gap: the terminal's own
        # read and event-loop jitter between two frames (a guess, stated).
        const_set(:MARGIN, 0.002)

        # Konsole before 26.04 (src/Emulation.cpp: BULK_TIMEOUT1 = 10,
        # BULK_TIMEOUT2 = 40 ms).
        def self.konsole_bulk(name = 'Konsole') = new(name: name, kind: :bulk, short: 0.010, long: 0.040, hz: nil)

        # Konsole 26.04 and later: DEC 2026 frames shown at their end.
        def self.konsole_sync(name = 'Konsole') = new(name: name, kind: :sync, short: nil, long: nil, hz: nil)

        # The profile for the terminal named by +xtversion+ (its XTVERSION
        # answer) or, without one, +env+ (KONSOLE_VERSION); nil when unknown
        # or behind tmux/screen (they repaint on their own terms).  Only
        # Konsole's rule is read from its source; other terminals are
        # modeled in the bench by name (UIBench) but not detected.
        def self.detect(xtversion: nil, env: ENV)
          return nil if env['TMUX'] || env['STY']
          ver =
            if xtversion.to_s =~ /\AKonsole (\d+)\.(\d+)/
              [$1.to_i, $2.to_i]
            elsif xtversion.nil? && env['KONSOLE_VERSION'].to_s =~ /\A(\d\d)(\d\d)\d*\z/
              [$1.to_i, $2.to_i]
            end
          return nil unless ver
          name = "Konsole #{ver[0]}.#{format('%02d', ver[1])}"
          (ver <=> [26, 4]) >= 0 ? konsole_sync(name) : konsole_bulk(name)
        end

        # A profile from a bench option: "konsole", "konsole26" (sync),
        # "sync", "cadence:HZ", "interval:MS", "bulk:SHORT_MS,LONG_MS".
        def self.parse(text)
          kind, arg = text.to_s.split(':', 2)
          case kind
          when 'konsole' then konsole_bulk
          when 'konsole26', 'sync' then konsole_sync(kind == 'sync' ? 'sync' : 'Konsole 26.04')
          when 'cadence' then new(name: "cadence #{arg || 60}", kind: :cadence, short: nil, long: nil, hz: (arg || 60).to_f)
          when 'interval' then new(name: "interval #{arg || 10} ms", kind: :interval, short: (arg || 10).to_f / 1000, long: nil, hz: nil)
          when 'bulk'
            s, l = (arg || '10,40').split(',').map { |v| v.to_f / 1000 }
            new(name: "bulk #{(s * 1000).round(2)}/#{(l * 1000).round(2)} ms", kind: :bulk, short: s, long: l, hz: nil)
          else
            raise ArgumentError, "terminal model #{text.inspect}: konsole, konsole26, sync, cadence:HZ, interval:MS, or bulk:SHORT,LONG (ms)"
          end
        end

        # The smallest gap between frame writes that lets each frame show
        # (nil: any gap shows, or the terminal samples on its own clock).
        def min_gap = kind == :bulk ? short + self.class::MARGIN : nil

        # Frames a second this terminal shows at most from steady writes
        # (nil: as many as written).
        def max_shown_fps
          case kind
          when :bulk then 1.0 / min_gap
          when :cadence then hz
          when :interval then 1.0 / short
          end
        end

        # Frames a second shown when writes come faster than the short
        # timer (bulk: about one per long timeout), or nil.
        def collapsed_fps = kind == :bulk ? 1.0 / long : nil

        # True when steady frames +period+ seconds apart are fewer than
        # this terminal could show had they come at #max_shown_fps: a
        # bulk terminal collapses writes under its short timeout.
        def collapses?(period) = kind == :bulk && period < short

        # When the view updates, given the sorted times (seconds) output
        # arrived: one chunk read per time for :bulk (each restarts the
        # short timer), one frame's end per time for :sync.  Returns the
        # sorted update times.
        def presents(times)
          out = []
          case kind
          when :sync
            times.each { |t| out << t }
          when :cadence
            times.each do |t|
              p = (t * hz).ceil / hz
              out << p unless out.last && p <= out.last
            end
          when :interval
            times.each do |t|
              next if out.last && t <= out.last
              out << (out.last ? [t, out.last + short].max : t)
            end
          else
            t1 = t2 = nil
            times.each do |t|
              if t1 && (due = t1 < t2 ? t1 : t2) <= t
                out << due
                t1 = t2 = nil
              end
              t1 = t + short
              t2 ||= t + long
            end
            out << (t1 < t2 ? t1 : t2) if t1
          end
          out
        end

        # The update that shows each of +frames+ (sorted arrival times),
        # from #presents' +updates+: an Array of indexes into +updates+ (nil
        # for a frame after the last update).
        def self.shown_by(frames, updates)
          j = 0
          frames.map do |t|
            j += 1 while j < updates.length && updates[j] < t
            j < updates.length ? j : nil
          end
        end

        # +t+ moved to the next refresh of a +hz+ display (phase 0).
        def self.vsync(t, hz) = (t * hz - 1e-9).ceil / hz.to_f

        # One line: "Konsole 23.08 (shows a frame 10 ms after output stops,
        # at the latest 40 ms after it starts)".
        def describe
          case kind
          when :bulk then "#{name} (shows output #{(short * 1000).round(1)} ms after it stops, at the latest #{(long * 1000).round} ms after it starts)"
          when :sync then "#{name} (shows each synchronized frame when it ends)"
          when :cadence then "#{name} (samples the screen #{hz.round} times a second)"
          when :interval then "#{name} (at most one update per #{(short * 1000).round(1)} ms)"
          end
        end
      end
    end
  end
end
