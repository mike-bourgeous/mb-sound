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
        # the terminal's defaults).
        def initialize(width:, height:, look: nil, color: nil, theme: nil)
          @width = width
          @height = height
          @frame = Text::Frame.new(width: width, height: height, look: look, color: color, theme: theme)
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

        # How many layouts were built so far (one per change of scales,
        # titles, or legend).
        def layouts
          @frame.layouts
        end

        # The look, color mode, and theme in use.
        def look = @frame.look
        def color = @frame.color
        def theme = @frame.theme

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
