module MB
  module Sound
    module UI
      # `design :bass` (sound-design-nav-1; design/notes/sound_design_ui.md,
      # Design): one command from a track (or an instrument and a clip) to
      # turning its filter.  Makes the track if needed, plays it on MAIN
      # (the maintainer, 2026-10-29: "MAIN always": a design audition is
      # just another part), shows `ui :sound` (fewer panes on small
      # screens: UI.tile_layout_levels) with the inspector on the track's
      # filter and its keys live, and `design off` puts back the screen
      # that was up before.
      module Design
        # What `design` did, printed as one line by the console.
        Opened = Data.define(:track, :instrument, :created, :clip, :played, :knobs, :row, :entry) do
          def to_s
            what = instrument ? "#{instrument} on track #{track.inspect}#{created ? ' (new)' : ''}" : "track #{track.inspect}"
            play = played ? "plays #{clip} on MAIN#{entry.respond_to?(:lands) && entry.lands ? " from #{entry.lands}" : ''}" : 'playing'
            k =
              if knobs.nil? then 'its knobs show once it lands'
              elsif knobs.empty? then 'no knobs yet (Enter on a dim · binds a literal)'
              else "knobs #{knobs.first(5).join(' ')}#{knobs.length > 5 ? " ... (#{knobs.length})" : ''}"
              end
            "design #{track.inspect}: #{what}, #{play}; #{k}#{row ? "; #{row} picked" : ''}"
          end

          def inspect = "#<#{self}>"
        end

        # The instrument a new track starts from when `design` gets none:
        # the init voice (presets/init.mbg.rb, bin/synths/init_voice.rb).
        BLANK = :init

        class << self
          # The last track designed (`design` alone opens it again).
          attr_reader :last

          # The screen up before the first `design` ([:tiles, name], [:band,
          # name], or [:none]), for `design off`.
          attr_reader :before

          # Opens track +name+ for design (see DesignMethods#design).
          # +values+ are an instrument (a Library::Entry or a preset's
          # name) and a clip, in either order.  Returns an Opened.
          def open(name = nil, *values)
            name ||= @last or raise ArgumentError, "design names a track: design :bass (an existing track), or design :bass, L.inst.dnb.dnb_reese, riff (makes it)"
            raise ArgumentError, "Track names are Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
            session = Session.current
            arr = session.arrangement
            clip, instrument = split(values)
            existing = arr.tracks[name]
            created = existing.nil?
            if instrument || existing.nil?
              # (a new track without an instrument starts from the init
              # voice: sound-design-2, the maintainer's "Init, based on 2osc
              # morph with optional am/fm/sync")
              instrument ||= BLANK
              MB::Sound.track(name, instrument) or return nil
            end
            tr = arr.tracks[name]
            clip ||= tr&.clip
            played = !session.playing_after_queue?(name) || values.any? { |v| v.is_a?(Sequence::Clip) || v.is_a?(Sequence::Kit) }
            clip_text = clip_name(clip)
            unless clip
              clip, note = default_clip(name, instrument)
              clip_text = "#{note} (its role's note)"
            end
            entry = played ? MB::Sound.bg(name, clip) : nil
            @last = name
            @open = true

            Inspect.target = { track: name, node: nil }.freeze
            show_screen
            info = Inspect::Gatherer.new.call(session, Inspect.target) rescue nil
            info = nil unless info&.track == name # (not playing yet: it lands at its launch point)
            row = info&.selected && "#{Inspect::SECTION_TITLES[info.selected.section] || 'row'} #{info.selected.label}"
            Opened.new(track: name, instrument: instrument_name(instrument), created: created, clip: clip_text, played: played,
                       knobs: info ? info.knobs : nil, row: row, entry: entry)
          end

          # Puts back the screen that was up before `design` (ui off when
          # none was).  Returns a line saying so.
          # True while track +name+ is in sound design: opened by `design`
          # (until `design off`), or the track the sound screen inspects
          # (`ui :sound`).  Its rebuilds land on the next buffer when every
          # state carries, else on the next beat (Arrangement#rebuild_track;
          # the maintainer, 2026-10-30/31).
          def designing?(name)
            return false if name.nil?
            return true if @open && @last == name

            t = UI.tiles
            target = Inspect.target
            !!(t&.active? && t.layout_name == :sound && target.is_a?(Hash) && target[:track] == name)
          rescue StandardError
            false
          end

          def close
            @open = false
            was = @before
            @before = nil
            kind, name = was
            case kind
            when :tiles, :band then UI.show(name)
            else UI.off
            end
            playing = @last ? "; #{@last.inspect} plays on (stop #{@last.inspect})" : ''
            "design off: #{kind == :tiles || kind == :band ? "back to ui #{name.inspect}" : 'ui off'}#{playing}"
          end

          private

          # [clip, instrument] from design's values.
          def split(values)
            clip = instrument = nil
            values.each do |v|
              if v.is_a?(Sequence::Clip) || v.is_a?(Sequence::Kit) || (v.is_a?(Library::Entry) && v.kind == :clip)
                raise ArgumentError, 'design: give it one clip (got two)' if clip
                clip = v.is_a?(Library::Entry) ? v.call : v
              else
                raise ArgumentError, 'design: give it one instrument (got two)' if instrument
                instrument = v
              end
            end
            [clip, instrument]
          end

          # A clip for a track with none: its role's note (PatchRender.ROLES,
          # from the track's and the instrument's names), a half note looping.
          def default_clip(name, instrument)
            row = PatchRender.role_of("#{name} #{instrument_name(instrument)}")
            note = Note.new(row[:note])
            [MB::Sound.seq(note).n2.loop, note.name]
          end

          def instrument_name(v)
            case v
            when nil then nil
            when Library::Entry then v.name
            else v.to_s
            end
          end

          def clip_name(c)
            return 'a clip' unless c
            n = c.respond_to?(:name) ? c.name : nil
            n ? n.to_s : 'its clip'
          end

          # True if a terminal can show the screen (the tiles' REPL is one).
          def terminal?
            $stdout.tty? || !UI.tiles.nil? || !UI.screen.nil?
          rescue StandardError
            false
          end

          # ui :sound, remembering the screen before the first design, with
          # the inspector focused and its keys live.
          def show_screen
            # (no terminal, e.g. a script or a pipe: the track is set up and
            # plays; `ui :sound` shows it in a terminal)
            return nil unless terminal?
            t = UI.tiles
            now =
              if t&.active? then [:tiles, t.layout_name]
              elsif (b = UI.screen) then [:band, b.layout.name]
              else [:none]
              end
            @before = now unless now == [:tiles, :sound] || @before
            screen = UI.show(:sound)
            screen.enter(:inspector) if screen.respond_to?(:enter) && screen.respond_to?(:tiler) && screen.tiler.layout.panes.include?(:inspector)
            screen
          end
        end
      end

      # The console's `design` (MB::Sound extends itself with it).
      module DesignMethods
        # Opens a track for sound design: `design :bass` shows `ui :sound`
        # on track :bass's voice with the inspector on its filter (its
        # keys live: s f a o x jump to SOURCE FILTER AMP MOD FX, arrows
        # turn, Enter types or binds, P the panel), playing it on MAIN if
        # it isn't playing.  `design :bass, L.inst.dnb.dnb_reese, riff`
        # makes the track with that instrument first (either order; any
        # instrument `track` takes; a new track without one starts from the
        # init voice, `preset :init`), and plays riff (else its clip, else
        # its role's note).  `design` alone opens the last one again; `design
        # off` puts back the screen that was up before.  Returns what it
        # did (one line).
        #
        #     bass = seq(E1, E1, G1, A1).n8.loop
        #     design :bass, L.inst.dnb.dnb_reese, bass
        #     design :lead              # a new track on the init voice
        #     design off
        def design(name = nil, *values)
          return UI::Design.close if name == :off || name == false
          UI::Design.open(name, *values)
        end
      end
    end

    extend UI::DesignMethods
  end
end
