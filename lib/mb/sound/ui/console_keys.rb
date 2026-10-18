module MB
  module Sound
    module UI
      # UI keys in the plain console and under the band (ux-1 round 3 items
      # 17, 18): there Reline reads the keyboard itself, so the UI keys are
      # Reline bindings (defaults, so the user's inputrc still wins):
      #
      # - Ctrl-]: the tiled screen in NAV (the band's layout's tiled
      #   counterpart, BAND_TILES; hidden tiles come back), the line being
      #   typed kept;
      # - F2: KEYS (the tiled :keys screen, or the tiles' keyboard);
      # - Ctrl-Backspace, Ctrl-Delete, Ctrl-Shift-Delete: delete the word
      #   before, the word after, to the end of the line (Input::RelineKeys).
      #
      # Prepended to Reline::LineEditor by .install (bin/sound.rb, through
      # UI.install_pry!).  Inside the tiles the Router reads these keys
      # before Reline, so the bindings only act where no screen owns the
      # keyboard (and while the tiles are hidden with Ctrl-Z).
      module ConsoleKeys
        # The tiled layout for Ctrl-] from each band layout.
        BAND_TILES = { band: :tiles, deck: :studio, mini: :tiles }.freeze

        # [byte sequences, LineEditor method] for the UI keys.
        BINDINGS = [
          [["\x1d"], :mb_sound_ui_nav],
          [["\eOQ", "\e[12~", "\e[[B"], :mb_sound_ui_keys],
        ].freeze

        class << self
          # What switching does, for specs: a Proc called with :nav or
          # :keys instead of switching (nil: switch).
          attr_accessor :handler

          # Prepends the editor methods and adds the bindings (once).
          # Returns the editing keys installed.
          def install
            return [] unless defined?(::Reline::LineEditor)
            ::Reline::LineEditor.prepend(self) unless ::Reline::LineEditor.ancestors.include?(self)
            BINDINGS.each { |seqs, func| seqs.each { |s| Input::RelineKeys.bind(s, func) } }
            @editing ||= Input::RelineKeys.install_editing_keys
          end

          # Ctrl-] or F2 outside the tiles: switches to the tiled screen
          # (in NAV, or KEYS).  Called on the console's thread while
          # Reline reads a line: the tiles adopt the console, and Reline
          # carries on in the REPL pane with the same line.
          def switch(what)
            return @handler.call(what) if @handler
            # (A screen's own Pry thread: that screen, never a new one on the
            # real terminal; ux-r4-panes found specs' hidden tiles opening one)
            owner = Thread.current[:mb_sound_ui_tiles]
            return owner.console_switch(what) if owner

            t = UI.tiles
            if t&.active?
              # (only while Reline reads outside the tiles' Router: nothing to do)
              return t
            end
            band = UI.band&.active? ? UI.band.layout.name : nil
            t = if t&.hidden?
                  UI.show
                elsif what == :keys
                  UI.show(:keys)
                else
                  UI.show(BAND_TILES.fetch(band, :tiles))
                end
            if what == :keys
              t.keys
            else
              t.router.mode = :nav
            end
            # Reline started this line in raw mode on the real terminal;
            # its input is now the pane's pty: raw there too, and a redraw
            # of the prompt and line in the pane (a resize, as a terminal)
            STDIN.raw!(intr: true) if STDIN.tty?
            t.host&.resize(*t.host.size, force: true)
            t
          rescue StandardError => e
            warn "ui: #{e.class}: #{e.message}"
            nil
          end
        end

        private

        def mb_sound_ui_nav(_key)
          ConsoleKeys.switch(:nav)
        end

        def mb_sound_ui_keys(_key)
          ConsoleKeys.switch(:keys)
        end
      end
    end
  end
end
