module MB
  module Sound
    module UI
      # Keeps Reline (Pry's line editor) inside the scroll region while the
      # band is on: Reline places its multi-line input and completion
      # dialogs from the cursor row it reads from the terminal and the
      # screen height, so with the band on, the screen it sees is the
      # region (rows shifted below a top band), and Ctrl-L clears only
      # what it owns and redraws the band.  Prepended to Reline::ANSI once;
      # does nothing while no band is on.
      module RelineGuard
        def self.install
          return unless defined?(::Reline::ANSI)
          return if ::Reline::ANSI.ancestors.include?(self)

          ::Reline::ANSI.prepend(self)
        end

        def get_screen_size
          rows, cols = super
          band = UI.band
          band&.active? ? [[rows - band.height, 1].max, cols] : [rows, cols]
        end

        def cursor_pos
          pos = super
          band = UI.band
          return pos unless band&.active? && band.top?

          ::Reline::CursorPos.new(pos.x, [pos.y - band.height, 0].max)
        end

        def clear_screen
          band = UI.band
          return super unless band&.active?

          top, = band.region
          write "\e[2J"
          write "\e[#{top};1H"
          band.invalidate
        end
      end
    end
  end
end
