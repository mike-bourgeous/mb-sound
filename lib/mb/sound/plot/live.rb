module MB
  module Sound
    module Plot
      # A text plot pane redrawn many times a second (a scope, a spectrum,
      # a meter): each #redraw draws a new chart, reusing the layout (axes,
      # tick labels, legend, title, grid lines) while it stays the same, so
      # a frame costs only the marks.  The text is exactly what
      # Plot::Text.render gives for the same chart.
      #
      #     pane = MB::Sound::Plot::Live.new(width: 60, height: 16, look: :scope)
      #     loop do
      #       print "\e[H", pane.redraw(MB::Sound::Plot.waveform(buffer, range: -1.0..1.0))
      #     end
      #
      # Fixed scale domains (+range:+ in the presets) keep the layout;
      # scales fit to each frame's data change it whenever the fit does.
      class Live
        attr_reader :width, :height

        # +look+, +color+, and +theme+ are as for Plot::Text.render (nil for
        # the terminal's defaults); +cells+ the cells' class (NativeCells
        # or Cells: the class of the grid #draw paints into; by default the
        # :cell_grid kernel's, see MB::Sound::Kernels).
        def initialize(width:, height:, look: nil, color: nil, theme: nil, cells: Kernels.cell_grid)
          @width = width
          @height = height
          @frame = Text::Frame.new(width: width, height: height, look: look, color: color, theme: theme, cells: cells)
          @shown = nil
        end

        # Draws +chart+ (a Chart or Figure) and returns its text: the lines
        # joined by newlines, with ANSI colors unless the color mode is
        # :none.
        def redraw(chart)
          @frame.text(chart)
        end

        # Draws +chart+ and returns its lines (see #redraw).
        def lines(chart)
          @frame.render(chart)
        end

        # Draws +chart+ into +grid+ (a screen's NativeCells or Cells, of the
        # class given to the constructor) with its top left corner at
        # 0-based cell (+x+, +y+), clipped to the grid.  Screens composite
        # their plot panes this way, so whatever they draw over the panes
        # afterwards (key overlays, badges) stays on top and only the
        # screen's own changed-cell frame reaches the terminal (ui-fix-3).
        # Returns +grid+.
        #
        #     live.draw(MB::Sound::Plot.waveform(buffer, range: -1.0..1.0), screen_grid, x: 10, y: 2)
        def draw(chart, grid, x:, y:)
          @frame.update(chart)
          grid.blit(@frame.cells, x, y)
        end

        # Draws +chart+ and returns the terminal bytes that put it on the
        # screen at 1-based (+row+, +col+): only the cells that changed
        # since the last #frame or #write (every cell the first time, after
        # #invalidate, or with +full+), placed with cursor moves, inside
        # DEC 2026 synchronized output with +sync+.
        #
        #     print pane.frame(MB::Sound::Plot.waveform(buffer, range: -1.0..1.0), row: 2)
        def frame(chart, row: 1, col: 1, full: false, sync: true)
          @frame.update(chart)
          prev = shown(full)
          out = @frame.cells.frame(prev, color, row: row, col: col, sync: sync)
          remember
          out
        end

        # Like #frame, but writes the bytes to +io+ (with the C cells,
        # encoding and writing without holding the GVL, so the audio
        # thread can run); returns the number of bytes written.
        def write(io, chart, row: 1, col: 1, full: false, sync: true)
          @frame.update(chart)
          prev = shown(full)
          cells = @frame.cells
          n =
            if cells.is_a?(Text::NativeCells)
              cells.write_frame(io, prev, color, row: row, col: col, sync: sync)
            else
              io.write(cells.frame(prev, color, row: row, col: col, sync: sync))
            end
          remember
          n
        end

        # Makes the next #frame or #write draw every cell (after the screen
        # was cleared or scrolled).
        def invalidate
          @shown = nil
        end

        # How many layouts were built so far (one per change of scales,
        # titles, or legend).
        def layouts
          @frame.layouts
        end

        # The look, color mode, and theme in use.
        def look = @frame.look
        def color = @frame.color
        def theme = @frame.theme

        private

        # What the screen shows (nil to draw everything)
        def shown(full)
          return nil if full || @shown.nil? || @shown.class != @frame.cells.class

          @shown
        end

        # Copies the frame just drawn as what the screen shows
        def remember
          cells = @frame.cells
          @shown = cells.class.new(@width, @height) if @shown.nil? || @shown.class != cells.class
          @shown.copy_from(cells)
        end

        public

        def inspect
          "#<#{self.class.name} #{@width}x#{@height} #{look.name} #{color} #{layouts} layout#{'s' unless layouts == 1}>"
        end
      end

      # A Plot::Live pane (see there).
      def self.live(width:, height:, **opts)
        Live.new(width: width, height: height, **opts)
      end
    end
  end
end
