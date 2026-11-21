module MB
  module Sound
    module UI
      # What `ui` returns (ux-1 round 3 item 8, pattern C): one object with
      # the same public surface whatever is on screen (the tiled screen,
      # the band, or nothing).  Commands go to the screen on now; a
      # command only the other kind of screen has says what to do instead
      # (and KEYS, `ui.keys`, switches to the tiles from anywhere), so no
      # `ui.x` raises NoMethodError because of the mode.
      #
      #     ui.keys          # from the band too: the tiled :keys screen
      #     ui.bind ['k', :ctrl], :keys
      #     ui.mode          # => :band
      #     ui.screen        # the Band or Tiles itself
      # What a bare `ui` returns while nothing is on screen (see
      # UIMethods#ui): the facade's commands, the default screen shown
      # first for all but QUIET ones, and when printed (`ui` alone at the
      # prompt: Pry prints the result).
      class Pending
        # Facade commands that need no screen (a bare `ui` before them
        # shows nothing).
        QUIET = %i[note notes bind unbind key_table keyboard mode off keys perf pace].freeze

        def method_missing(name, *args, **opts, &block)
          return super unless UI.facade.respond_to?(name)
          UI.show unless QUIET.include?(name)
          UI.facade.public_send(name, *args, **opts, &block)
        end

        def respond_to_missing?(name, include_private = false) = UI.facade.respond_to?(name, include_private) || super

        # Shows the default screen (the band), as `ui` always did, and
        # describes it.
        def inspect
          UI.show
          UI.facade.inspect
        end

        def pretty_print(q) = q.text(inspect)
      end

      class Facade
        # The mode: :tiles, :band, :hidden (tiles hidden with Ctrl-Z), :off.
        def mode
          t = UI.tiles
          return :tiles if t&.active?
          return :band if UI.band&.active?
          return :hidden if t&.hidden?
          :off
        end

        # The screen on (Tiles or Band; hidden tiles too), or nil.
        def screen
          UI.screen || (UI.tiles if UI.tiles&.hidden?)
        end

        # KEYS mode (see UI::Tiles#keys): opens the tiled :keys screen from
        # the band or the plain console.
        def keys(on = true, **opts)
          t = screen
          return t.keys(on, **opts) if t.is_a?(Tiles)
          return self unless on
          UI.show(:keys).keys(**opts)
        end

        # The virtual keyboard (UI::Keyboard).
        def keyboard = UI.keyboard

        # Binds a key for the tiled screen (see UI::Keys.bind); any mode.
        def bind(key, action, *args, mode: :repl, help: nil)
          note = Keys.bind(key, action, *args, mode: mode, help: help)
          puts "\e[2mui.bind: #{note}\e[0m"
          self
        end

        # Removes a #bind binding.
        def unbind(key, mode: :repl)
          Keys.unbind(key, mode: mode)
          self
        end

        # The key table as text (every mode; see UI::Keys).
        def key_table = Tiles.key_table

        # Turns the screen off (as `ui off`).
        def off = UI.off

        # Saves a UI note for the next refinement round: +text+ with the
        # screen (layout, focused pane, a plain-text capture), what plays
        # (players, tracks, the form's section, the scene, the position),
        # and the last console lines, appended to today's Markdown file
        # (UI::NoteLog.dir: $MB_SOUND_UI_NOTES, else the main checkout's
        # tmp/ui-notes/ from a git checkout, else the user data directory).
        # Each note also writes a JSON record an agent can read (the sound
        # it is about: the inspected track's patch, knobs, and reference;
        # the RENDER pane's view, markers, and what it drew; where in the
        # take; UI::NoteLog.record).  +at:+ (seconds into the rendered
        # note) and +freq:+ (Hz or a Pitch) name the spot you mean; without
        # them the RENDER pane's markers (, . < > there) do.
        # Returns the Note, which prints the file's path.
        # NAV # opens a prompt line for one while the set plays.
        #
        #     ui.note 'the cutoff turns too slowly at the bottom'
        #     ui.note 'the bump here sounds like a second click', at: 0.012, freq: 3000
        def note(text, at: nil, freq: nil) = NoteLog.save(text, at: at, freq: freq)

        # The UI notes of +day+ (:today, a Date, or "2026-10-30"), one line
        # each (UI::NoteLog::Listing).
        #
        #     ui.notes
        def notes(day = :today) = NoteLog.list(day)

        # Frame instruments (UI::Perf): what the frame rate can't see.
        # `ui.perf` starts recording on the screen (or, while recording,
        # says how long; each action returns one line, a PerfStatus, which
        # also takes `ui.perf.report` and the like); :report, :stop (and
        # the report), :save
        # (report.txt, summary.json, frames.json under
        # tmp/ui-perf/captures/), :capture (about a minute of the tiles
        # with the set playing, then the sound-design screen with a knob
        # moving; saved, three lines printed; :cancel stops it early and
        # saves what it has).  The report: frame lateness,
        # paint and write times, the worst stall between written frames,
        # bytes, GC, each pane's update age, key-to-frame latency, the
        # terminal's answer time to a query sent after sampled frames, the
        # render thread's wake delay, and the terminal's identity.
        #
        #     ui.perf             # start
        #     ui.perf :report
        #     ui.perf :capture    # one minute in your real terminal; type a few keys in phase 1
        def perf(what = nil, seconds: Perf::Capture::SECONDS, design: nil, dir: nil)
          require_relative '../help' # (the report is a help page)
          s = screen
          rec = s.respond_to?(:perf) ? s.perf : nil
          # (no argument while recording: one status line; konsole-pacing,
          # 2026-11-21: it printed the report, and `ui.perf.report` then
          # printed it twice)
          return perf_status(rec) if what.nil? && rec
          what ||= :start
          case what
          when :start
            return puts("\e[33mui.perf: no screen is on (ui :tiles, or ui.perf :capture)\e[0m") unless s
            UI.last_perf = s.start_perf
            PerfStatus.new("ui.perf: recording #{s.class.name.split('::').last.downcase} frames (ui.perf :report, :stop, :save)")
          when :stop
            p = s&.stop_perf || UI.last_perf
            return puts("\e[33mui.perf: nothing recorded\e[0m") unless p
            puts Help.for_output(p.report.to_s)
            PerfStatus.new("ui.perf: stopped after #{p.summary[:seconds]} s (the report is above; ui.perf :save keeps it)")
          when :report
            p = rec || UI.last_perf
            return puts("\e[33mui.perf: nothing recorded (ui.perf starts)\e[0m") unless p
            puts Help.for_output(p.report.to_s)
            perf_status(p)
          when :save
            p = rec || UI.last_perf
            return puts("\e[33mui.perf: nothing recorded (ui.perf starts)\e[0m") unless p
            d = p.save(dir)
            PerfStatus.new("ui.perf: saved #{d}")
          when :capture
            Perf::Capture.start(seconds: seconds, design: design, dir: dir)
            PerfStatus.new('ui.perf :capture: running in the background (ui.perf :cancel stops it early)')
          when :cancel
            Perf::Capture.cancel ? PerfStatus.new('ui.perf :capture: stopping; it saves what it recorded') : PerfStatus.new('ui.perf: no capture is running')
          else
            raise ArgumentError, "ui.perf takes #{PERF_ACTIONS.map(&:inspect).join(', ')} (got #{what.inspect}#{Facade.did_you_mean(what, PERF_ACTIONS)})"
          end
        end

        # ui.perf's actions.
        PERF_ACTIONS = %i[start report stop save capture cancel].freeze

        # What ui.perf returns: one line in the console (konsole-pacing,
        # 2026-11-21: `ui.perf :stop` returned the UI::Perf, whose rings
        # Pry printed as 209 000 lines).  `ui.perf.report` (and .stop,
        # .save, .start, .capture, .cancel) do what `ui.perf :report` does.
        PerfStatus = Data.define(:line) do
          def to_s = line
          def inspect = line
          def pretty_print(q) = q.text(line)

          PERF_ACTIONS.each do |name|
            define_method(name) { |*args, **opts| UI.facade.perf(name, *args, **opts) }
          end
        end

        # " (did you mean :on?)" for +given+ among +choices+ (Symbols), or
        # "": DidYouMean's spell checker, else the choices one or two edits
        # away (it found nothing near :omn for :on).
        def self.did_you_mean(given, choices)
          word = given.to_s
          near = DidYouMean::SpellChecker.new(dictionary: choices.map(&:to_s)).correct(word)
          if near.empty? && !word.empty?
            d = choices.to_h { |c| [c, DidYouMean::Levenshtein.distance(c.to_s, word)] }
            best = d.values.min
            near = d.select { |_, v| v == best && v <= 2 }.keys.map(&:to_s) if best
          end
          near.empty? ? '' : "; did you mean #{near.first(2).map { |n| n.to_sym.inspect }.join(' or ')}?"
        end

        private def perf_status(p)
          sm = p.summary
          PerfStatus.new("ui.perf: #{p.running? ? 'recording' : 'recorded'} #{sm[:seconds]} s, #{sm[:written_per_s]} frames written/s " \
                         "(ui.perf :report#{p.running? ? ', :stop' : ''}, :save)")
        end

        # The sound-design preview's wave mode: with no argument, :off or
        # :live; :live draws the preview every frame from the values the
        # playing voice used in its latest buffer (UI::WaveView, a
        # prototype), :off the 4/s chart previews (the default;
        # MB_SOUND_UI_WAVES=live at start sets :live).  Returns the mode.
        #
        #     ui.waves :live
        #     ui.waves          # => :live
        def waves(mode = nil)
          return WaveView.mode if mode.nil?
          WaveView.mode = mode.to_sym
        end

        # Smooth frames (ui-perf-2; off by default): with :on the render
        # thread publishes a snapshot after every buffer the painter took
        # the last one in (Feed.every_buffer), the painter times its frames
        # to new snapshots (FrameRate.snapshot_timed), and the REPL's echo
        # wakes the painter once per key (Tiles.echo_wake), so scopes and
        # meters change on every frame at 60 fps at any buffer size and
        # typing shows in about a millisecond (bin/ui_bench.rb --smooth).
        # With no argument, :on or :off; MB_SOUND_UI_SMOOTH=1 at start sets
        # :on.  Takes effect on the running screen.  Returns the mode.
        #
        #     ui.smooth :on
        #     ui.smooth          # => :on
        def smooth(mode = nil)
          return UI.smooth? ? :on : :off if mode.nil?
          on = { on: true, off: false, true => true, false => false }.fetch(mode) {
            raise ArgumentError, "ui.smooth takes :on or :off (got #{mode.inspect}#{Facade.did_you_mean(mode, %i[on off])})"
          }
          Feed.every_buffer = FrameRate.snapshot_timed = Tiles.echo_wake = on
          s = screen
          s.apply_timing if s.respond_to?(:apply_timing)
          on ? :on : :off
        end

        # The painter's pacing (konsole-pacing, 2026-11-21; off by
        # default): :exact writes frames on the target's deadlines;
        # :terminal also keeps frame writes far enough apart for the
        # detected terminal to show each one (Konsole before 26.04 shows
        # output only 10 ms after it stops arriving, so frames written
        # closer, above about 95 a second, show at about 25 a second; the
        # gap is 12 ms, about 83 frames a second at most).  Terminals
        # without such a rule (or not detected) pace as :exact.  With no
        # argument, the mode; MB_SOUND_UI_PACE=terminal sets :terminal at
        # start.  Takes effect on the running screen.
        #
        #     ui.pace :terminal
        #     ui.pace            # => :terminal
        def pace(mode = nil)
          return FrameRate.pace if mode.nil?
          unless FrameRate::PACES.include?(mode)
            raise ArgumentError, "ui.pace takes #{FrameRate::PACES.map(&:inspect).join(' or ')} (got #{mode.inspect}#{Facade.did_you_mean(mode, FrameRate::PACES)})"
          end
          FrameRate.pace = mode
          s = screen
          s.apply_timing if s.respond_to?(:apply_timing)
          mode
        end

        def respond_to_missing?(name, include_private = false)
          Tiles.public_method_defined?(name) || Band.public_method_defined?(name) || super
        end

        def method_missing(name, *args, **opts, &block)
          s = screen
          return s.public_send(name, *args, **opts, &block) if s.respond_to?(name)
          return super unless respond_to_missing?(name)
          hint =
            case mode
            when :band then "the tiled screen's (`ui :tiles`, or Ctrl-] from the console)"
            when :tiles then "the band's (`ui :band`)"
            else 'a screen\'s: none is on (`ui` shows the band, `ui :tiles` the tiled screen)'
            end
          $stdout.puts "\e[33mui.#{name}: #{hint}\e[0m"
          nil
        end

        def inspect
          s = screen
          s ? s.inspect : '#<UI off (ui: the band, ui :tiles: the tiled screen)>'
        end

        def pretty_print(q) = q.text(inspect)
      end

      # True if the current thread runs the REPL's commands (warnings it
      # raises print in the REPL; see Tiles#repl_thread?).
      def self.repl_thread?
        s = screen
        s.respond_to?(:repl_thread?) && s.repl_thread?
      end

      # The `ui` facade (one per process).
      def self.facade
        @facade ||= Facade.new
      end
    end
  end
end
