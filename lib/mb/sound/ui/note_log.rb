require 'date'
require 'fileutils'

module MB
  module Sound
    module UI
      # UI notes for the next refinement round (ui-scaffold-1, the
      # maintainer's u-notes: the library and live UIs get refinement
      # rounds from his notes after real use).  `ui.note 'the cutoff turns
      # too slowly'` (or NAV # for a prompt line while the set plays) keeps
      # the text with what was on screen and what was playing: the time,
      # the layout, the focused pane and mode, the terminal size, a plain
      # text capture of the screen, the players and tracks, the form's
      # section, the scene, the position, and the last console lines.
      # Notes go to one Markdown file per day in $MB_SOUND_UI_NOTES, else
      # the user data directory (ui-notes/ beside help/ and takes/),
      # appended, never rewritten.  `ui.notes` lists today's.
      module NoteLog
        # The console lines kept with a note.
        COMMANDS = 8

        # A saved note: +time+, +text+, +path+ (the day's file), +where+
        # (the screen in words), +markdown+ (what was appended).
        Note = Data.define(:time, :text, :path, :where, :markdown) do
          def to_s = "ui.note saved #{time.strftime('%H:%M:%S')} (#{where}) to #{path}"
          def inspect = "#<#{self}>"
        end

        # A day's notes: +path+, +day+, +entries+ ([[time text, first line
        # of the note], ...]).
        Listing = Data.define(:path, :day, :entries) do
          include Enumerable

          def each(&block) = entries.each(&block)
          def size = entries.size

          def to_s
            return "No UI notes on #{day} (ui.note 'text' saves one; NAV # while the screen is up)" if entries.empty?
            ["#{entries.length} UI note#{'s' unless entries.length == 1} on #{day} (#{path}):", *entries.map { |t, x| "  #{t}  #{x}" }].join("\n")
          end

          def inspect = to_s
        end

        module_function

        # Where notes go: $MB_SOUND_UI_NOTES, else the user data directory.
        def dir
          env = ENV['MB_SOUND_UI_NOTES']
          return File.expand_path(env) unless env.to_s.empty?
          File.join(File.dirname(Internal.help_data_dir), 'ui-notes')
        end

        # The day's file for +day+ (a Date).
        def path_for(day) = File.join(dir, "#{day.strftime('%Y-%m-%d')}.md")

        # What the screen +screen+ (Tiles, Band, or nil) shows: { layout:,
        # focus:, mode:, size:, text: }, read now.  The tiles' NAV # prompt
        # takes this when the prompt opens (what was looked at), not when
        # Enter saves.
        def capture(screen = UI.screen || (UI.tiles if UI.tiles&.hidden?))
          return { layout: nil, focus: nil, mode: :off, size: nil, text: nil } unless screen
          if screen.is_a?(Tiles)
            {
              layout: screen.layout_name, focus: screen.tiler.focus, mode: screen.hidden? ? :hidden : screen.mode,
              size: [screen.cols, screen.rows], text: screen.hidden? ? nil : screen.to_text(:none),
            }
          else
            { layout: (screen.layout.name rescue nil), focus: nil, mode: :band, size: nil, text: screen.to_text(:none) }
          end
        rescue StandardError => e
          { layout: nil, focus: nil, mode: :unknown, size: nil, text: "(no capture: #{e.class}: #{e.message})" }
        end

        # Saves a note of +text+ (see the module description), with
        # +capture+ (#capture's Hash; now if nil) and +session+'s state.
        # Returns a Note.
        def save(text, capture: nil, session: Session.existing, time: Time.now)
          text = text.to_s.strip
          raise ArgumentError, "ui.note takes the note's text (ui.note 'the cutoff turns too slowly')" if text.empty?
          capture ||= self.capture
          md = markdown(text, capture, session, time)
          path = path_for(time.to_date)
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, 'a') do |f|
            f.write("# UI notes #{time.strftime('%Y-%m-%d')}\n\nSaved by `ui.note` (mb-sound) for the next UI refinement round.\n") if f.size == 0
            f.write("\n#{md}")
          end
          Note.new(time: time, text: text.freeze, path: path, where: where(capture).freeze, markdown: md.freeze)
        end

        # The notes of +day+ (:today, a Date, or "2026-10-30").
        def list(day = :today)
          day = case day
                when :today, nil then Date.today
                when Date then day
                else Date.parse(day.to_s)
                end
          path = path_for(day)
          entries = File.exist?(path) ? File.readlines(path, chomp: true).grep(/\A## /).map { |l| l.delete_prefix('## ').split('  ', 2) } : []
          Listing.new(path: path, day: day.strftime('%Y-%m-%d'), entries: entries.map { |t, x| [t, x.to_s] }.freeze)
        end

        # The screen in words, from a #capture.
        def where(c)
          return 'no screen' if c[:mode] == :off
          parts = []
          parts << "ui #{c[:layout].inspect}" if c[:layout]
          parts << "#{c[:size][0]}x#{c[:size][1]}" if c[:size]
          parts << "focus #{c[:focus]}" if c[:focus]
          parts << "#{c[:mode]} mode" if c[:mode] && c[:mode] != :band
          parts.join(', ')
        end

        # The Markdown of one note.
        def markdown(text, c, session, time)
          first, *rest = text.lines.map(&:rstrip)
          out = ["## #{time.strftime('%H:%M:%S')}  #{first}", '']
          out.concat(rest.map { |l| "> #{l}" }) << '' unless rest.empty?
          out << "- **screen**: #{where(c)}"
          out.concat(playing_lines(session))
          lines = Take.active&.recent_lines(COMMANDS) || []
          unless lines.empty?
            out << "- **last commands**:" << '' << '```ruby'
            lines.each { |stamp, code| out << "#{code.rstrip}  # #{stamp}" }
            out << '```'
          end
          if c[:text]
            fence = '````'
            out << '' << "<details><summary>screen#{c[:size] ? " (#{c[:size][0]}x#{c[:size][1]})" : ''}</summary>" << '' << "#{fence}text"
            out.concat(c[:text].lines.map(&:rstrip))
            out << fence << '' << '</details>'
          end
          out.join("\n") + "\n"
        end

        # What +session+ plays, as Markdown list items.
        def playing_lines(session)
          return ['- **playing**: no session'] unless session
          out = []
          arr = session.arrangement
          clock = session.clock.to_s
          stamp = clock[/\A#<Stamp (\S+)/, 1] || clock
          at = ["bar #{stamp}", "#{format('%g', session.transport.bpm.to_f.round(2))} bpm"]
          (form = arr.playback) && at << "form #{form}"
          (scene = arr.current_scene) && at << "scene #{scene.inspect}"
          out << "- **at**: #{at.join(', ')}"
          tracks = arr.track_info
          players = session.players
          out << "- **players**: #{players.empty? ? 'none' : players.map { |n, d| tracks[n] ? "#{n.inspect} (track #{tracks[n]})" : "#{n.inspect} (#{d.to_s[0, 60]})" }.join('; ')}"
          idle = tracks.keys - players.keys
          out << "- **tracks not playing**: #{idle.map(&:inspect).join(', ')}" unless idle.empty?
          out
        rescue StandardError => e
          out << "- **playing**: (not read: #{e.class}: #{e.message})"
        end
      end
    end
  end
end
