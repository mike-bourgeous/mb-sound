module MB
  module Sound
    module UI
      # Console commands for the terminal UI (MB::Sound extends itself with
      # them; see MB::Sound::UI).
      module UIMethods
        # Shows the dashboard band above the console (Pry keeps the rest of
        # the screen): `ui` (the default layout, or the band on screen),
        # `ui :deck` (a layout by name: :band, :deck, :mini, or one made
        # with #layout or saved with `ui.save`), `ui off` (or `ui :off`,
        # `ui false`).  +at:+ :bottom (default; scrolled lines reach the
        # terminal's scrollback) or :top, +color:+ :ansi256 (default),
        # :truecolor, :ansi16, :none, +look:+ the scope's Plot look (:auto
        # default: :scope Braille for short or wide panes, else :quad).
        # Returns the band (`ui.save`, `ui.stats`).
        #
        # A layout with a `repl` pane takes the whole screen instead (`ui
        # :tiles`, `ui :studio`): panes tiled around the console, NAV mode
        # on Ctrl-] (see UI::Tiles; `help :ui`).  +mouse:+ true turns on
        # mouse reports there, +nav_esc:+ seconds lets a lone Esc enter NAV.
        def ui(layout = nil, at: nil, color: nil, look: nil, mouse: nil, nav_esc: nil)
          return UI.off if layout == :off || layout == false
          UI.show(layout, at: at, color: color, look: look, mouse: mouse, nav_esc: nav_esc)
        end

        # The virtual keyboard: KEYS mode in the tiled screen (the computer
        # keyboard plays notes into the session; Ctrl-] or F2 back), opening
        # `ui :keys` if no tiled screen is up (or bringing hidden tiles
        # back).  Options as for UI::Tiles#keys: +off:+ the note-off mode,
        # +step:+ true for step entry, +patch:+ the default patch.  F2
        # also switches between the REPL and KEYS.
        #
        #     keys                 # play
        #     keys step: true      # step entry
        def keys(off: nil, step: nil, patch: :keep)
          t = UI.tiles
          t = UI.show(:keys) unless t&.active? || t&.hidden?
          t.keys(off: off, step: step, patch: patch)
        end

        # Brings back the tiled screen hidden with Ctrl-Z, as `fg` does for a
        # shell's stopped job (the same as `ui`).  Returns the screen, or nil
        # (with a hint) if nothing is hidden.
        def fg
          t = UI.tiles
          return UI.show if t&.hidden?
          return UI.screen if UI.screen
          puts "\e[2mfg: no hidden UI (Ctrl-Z in the tiles hides them; `ui :tiles` shows them)\e[0m"
          nil
        end

        # What runs in the background, as a shell's `jobs` lists: a hidden
        # (or shown) terminal UI and the session's players.  Returns the
        # lines (also printed).
        def jobs
          lines = []
          t = UI.tiles
          if t&.hidden?
            lines << "[ui]+ hidden   ui #{t.layout_name.inspect}   (fg or Ctrl-Z brings it back)"
          elsif (s = UI.screen)
            lines << "[ui]  on screen   ui #{(s.is_a?(UI::Tiles) ? s.layout_name : s.layout.name).inspect}"
          end
          session = Session.existing
          players = session ? session.players.keys : []
          lines << "[bg]  playing   #{players.map(&:inspect).join(', ')}" unless players.empty?
          lines << 'nothing in the background' if lines.empty?
          puts lines
          lines
        end

        # :off, so `ui off` reads as it sounds.
        def off
          :off
        end

        # Defines a pane for layouts: the block draws it from a snapshot
        # into a canvas (`c.puts`, `c.text`, `c.meter`, `c.sparkline`; see
        # UI::Canvas and UI::Snapshot), at most +rate+ times a second, in
        # +height+ rows; +needs:+ :meters or :scope makes the render
        # thread collect master meters or scope samples.  Without a block,
        # returns the pane.
        #
        #     pane :where, height: 1 do |c, s|
        #       c.puts ['bar ', :dim], [s.stamp, :key], ['  ', nil], [s.form&.section.to_s, :name]
        #     end
        def pane(name, rate: 10, height: 3, width: 24, needs: [], title: nil, &block)
          return UI.panes.fetch(name) { raise ArgumentError, "No pane #{name.inspect} (panes: #{UI.panes.keys.map(&:inspect).join(', ')})" } unless block
          UI.define_pane(name, rate: rate, height: height, width: width, needs: needs, title: title, &block)
        end

        # Defines a band layout from panes in rows and columns (see
        # UI::Layout); `ui :name` shows it.  Without a block, returns the
        # layout.
        #
        #     layout :mine do
        #       cols { pane :transport; pane :form }
        #       cols { pane :meters; pane :scope, width: 50 }
        #     end
        #
        # With a `repl` pane (`repl`), and tabs (`tabs :meters, :cpu`), it is
        # a tiled layout: `ui :name` takes the whole screen.
        #
        #     layout :mine, focus: :repl do
        #       cols do
        #         repl
        #         rows(width: 40) { pane :meters; pane :scope }
        #       end
        #     end
        def layout(name, at: nil, focus: nil, zoom: nil, gap: nil, &block)
          return UI.layout_named(name) unless block
          UI.define_layout(name, **{ at: at, focus: focus, zoom: zoom, gap: gap }.compact, &block)
        end
      end

      # Tab completion of session names for Pry: after a command that takes
      # one (`go :`, `turn :`, `stop :`, `ui :`, ...) only the names it
      # takes; any other Symbol lists track, scene, knob, bus, and player
      # names first.  Prepended to Pry::InputCompleter by bin/sound.rb.
      module Completion
        # Commands and the names they complete.
        CONTEXTS = {
          scenes: %i[go scene],
          knobs: %i[turn move knob learn bind_cc snap recall xfade],
          tracks: %i[stop mute unmute solo unsolo arm disarm rec record capture resume swap track bg ahead forget],
          buses: %i[bus route feed],
          layouts: %i[ui layout],
          panes: %i[pane],
        }.freeze

        def self.install
          return unless defined?(::Pry::InputCompleter)
          ::Pry::InputCompleter.prepend(self) unless ::Pry::InputCompleter.ancestors.include?(self)
        end

        # Names for Symbol completion of +str+ on +line+ (an Array of
        # ":name" Strings, or nil when nothing applies).
        def self.names_for(str, line, session = Session.existing)
          return nil unless str.empty? || str.start_with?(':')
          before = line.to_s[0, line.to_s.length - str.length]
          cmd = before[/(?:\A|[\s;(.])(\w+)[\s(]+(?:[^\s(]*,\s*)?\z/, 1]&.to_sym
          kind = CONTEXTS.find { |_, cmds| cmds.include?(cmd) }&.first
          return nil if kind.nil? && str.empty?

          names = kind ? names_of(kind, session) : CONTEXTS.keys.flat_map { |k| names_of(k, session) }.uniq
          prefix = str.delete_prefix(':')
          found = names.map(&:to_s).select { |n| n.start_with?(prefix) }.sort.map { |n| ":#{n}" }
          found.empty? ? nil : found
        end

        # Names of one +kind+ (see CONTEXTS).
        def self.names_of(kind, session)
          case kind
          when :layouts then UI.layouts.keys + UI.tile_layouts.keys + UI.saved_layouts + [:off]
          when :panes then UI.panes.keys
          else
            return [] unless session
            case kind
            when :scenes then session.arrangement.scenes.keys
            when :knobs then session.knobs.keys
            when :buses then session.bus_names
            when :tracks
              snap = UI.band&.active? && UI.band.feed.latest
              players = snap ? snap.players.map(&:name) : session.players.keys
              (session.arrangement.tracks.keys + players).select { |n| n.is_a?(Symbol) }.uniq
            end
          end
        rescue StandardError
          []
        end

        def call(str, options = {})
          line = defined?(::Reline) ? ::Reline.line_buffer : nil
          names = Completion.names_for(str.to_s, line || str.to_s)
          return names if names && Completion.contextual?(str.to_s, line || str.to_s)

          rest = super
          names ? (names + rest).uniq : rest
        end

        # True when +line+ names a command whose names complete +str+.
        def self.contextual?(str, line)
          before = line.to_s[0, line.to_s.length - str.length]
          cmd = before[/(?:\A|[\s;(.])(\w+)[\s(]+(?:[^\s(]*,\s*)?\z/, 1]&.to_sym
          CONTEXTS.any? { |_, cmds| cmds.include?(cmd) }
        end
      end
    end

    extend UI::UIMethods
  end
end
