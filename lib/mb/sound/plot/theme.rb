module MB
  module Sound
    module Plot
      # Colors as [r, g, b] Integer Arrays (0..255), and helpers.
      module Color
        module_function

        # [r, g, b] from '#rrggbb' or [r, g, b].
        def rgb(c)
          case c
          when Array then c.map(&:to_i)
          when /\A#?(\h\h)(\h\h)(\h\h)\z/ then [$1.hex, $2.hex, $3.hex]
          else raise ArgumentError, "Unknown color #{c.inspect} (use '#rrggbb', [r, g, b], or a palette slot Integer)"
          end
        end

        # '#rrggbb' for [r, g, b].
        def hex(c)
          format('#%02x%02x%02x', *rgb(c))
        end

        # Linear mix of colors +a+ and +b+ (+t+ = 0 gives +a+).
        def mix(a, b, t)
          a.zip(b).map { |x, y| (x + (y - x) * t).round.clamp(0, 255) }
        end
      end

      # A colormap for heatmaps: a lookup table of +size+ colors made by
      # interpolating +stops+ (hex Strings, evenly spaced).
      class Colormap
        # Perceptually ordered maps (approximations of matplotlib's magma,
        # inferno, and viridis, by their ninths), a one-hue blue ramp (from
        # the reference data-viz palette), and an oscilloscope green.
        STOPS = {
          magma: %w[#000004 #1c1044 #4f127b #812581 #b5367a #e55064 #fb8761 #fec287 #fcfdbf],
          inferno: %w[#000004 #1f0c48 #550f6d #88226a #ba3655 #e35933 #f98e09 #f8c932 #fcffa4],
          viridis: %w[#440154 #472c7a #3b518b #2c718e #21908d #27ad81 #5cc863 #aadc32 #fde725],
          blues: %w[#0d1b2e #0d366b #184f95 #256abf #3987e5 #6da7ec #9ec5f4 #cde2fb #f2f7fe],
          phosphor: %w[#000000 #002208 #00451a #00702a #00a03a #10d050 #60f080 #b0ffc0 #f0fff0],
          gray: %w[#000000 #ffffff],
        }.freeze

        attr_reader :name, :colors

        # A Colormap by name (Symbol), or +map+ itself if it is one.
        def self.[](map)
          return map if map.is_a?(Colormap)

          @maps ||= {}
          @maps[map.to_sym] ||= new(map.to_sym)
        end

        def initialize(name, size: 64, stops: nil)
          @name = name
          stops ||= STOPS.fetch(name) { raise ArgumentError, "Unknown colormap #{name.inspect} (#{STOPS.keys.join(', ')})" }
          rgbs = stops.map { |s| Color.rgb(s) }
          @colors = Array.new(size) { |i|
            t = i * (rgbs.length - 1) / (size - 1).to_f
            k = [t.floor, rgbs.length - 2].min
            Color.mix(rgbs[k], rgbs[k + 1], t - k)
          }.freeze
          freeze
        end

        def size
          @colors.length
        end

        # Indexes 0...size for values +u+ from 0 to 1 (Numo::DFloat; NaN
        # and values outside are clamped).
        def indexes(u)
          u = Numo::DFloat.cast(u)
          u[u.isnan] = 0
          Numo::Int32.cast((u.clip(0, 1) * (size - 1)).round)
        end

        # The color for one value from 0 to 1.
        def at(u)
          @colors[(u.to_f.clamp(0, 1) * (size - 1)).round]
        end
      end

      # Colors and fonts shared by every renderer.  +palette+ is the
      # categorical series order (fixed order, never cycled past its end:
      # more series reuse colors with a different dash/glyph); +ink+ is
      # text, +muted+ is axes and tick labels, +grid+ is grid lines,
      # +background+ is the surface (nil in terminals: their own
      # background).
      Theme = Data.define(:name, :background, :ink, :muted, :grid, :palette, :colormap, :font, :glow) do
        def initialize(name:, background:, ink:, muted:, grid:, palette:, colormap: :magma, font: 'ui-monospace, Menlo, Consolas, monospace', glow: false)
          super(
            name: name,
            background: background && Color.rgb(background),
            ink: ink && Color.rgb(ink),
            muted: Color.rgb(muted),
            grid: Color.rgb(grid),
            palette: palette.map { |c| Color.rgb(c) }.freeze,
            colormap: colormap,
            font: font,
            glow: glow,
          )
        end

        # The color of series slot +i+ (0-based).
        def series(i)
          palette[i % palette.length]
        end

        # Data.define's positional constructor would be Theme[...]; here [] looks
        # a theme up by name instead (remove the generated one first, so -w
        # doesn't warn about a redefinition).
        class << self
          remove_method :[]
        end

        # A Theme by name, or +theme+ itself.
        def self.[](theme)
          return theme if theme.is_a?(Theme)

          THEMES.fetch(theme.to_sym) { raise ArgumentError, "Unknown theme #{theme.inspect} (#{THEMES.keys.join(', ')})" }
        end
      end

      # Categorical slots from the reference data-viz palette (validated for
      # color vision deficiencies in this order), light and dark steps.
      LIGHT_PALETTE = %w[#2a78d6 #eb6834 #1baf7a #eda100 #e87ba4 #008300 #6250d6 #e34948].freeze
      DARK_PALETTE = %w[#3987e5 #d95926 #199e70 #c98500 #d55181 #008300 #9085e9 #e66767].freeze

      # Brighter dark-terminal steps (text glyphs are thin, so they need
      # more lightness than filled marks on a dark surface).
      TERMINAL_PALETTE = %w[#5598e7 #f0783c #2cc28a #e6a817 #e870a0 #4caf50 #a59cf0 #f07878].freeze

      THEMES = {
        # Terminal themes (no background: the terminal's own)
        dark: Theme.new(name: :dark, background: nil, ink: nil, muted: '#8a8a85', grid: '#3c3c3a', palette: TERMINAL_PALETTE),
        light: Theme.new(name: :light, background: nil, ink: nil, muted: '#6b6a66', grid: '#d6d5d0', palette: LIGHT_PALETTE),

        # Image themes
        paper: Theme.new(name: :paper, background: '#fcfcfb', ink: '#0b0b0b', muted: '#52514e', grid: '#e4e3df', palette: LIGHT_PALETTE, colormap: :magma,
          font: "'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif"),
        studio: Theme.new(name: :studio, background: '#1a1a19', ink: '#f0efec', muted: '#c3c2b7', grid: '#33332f', palette: DARK_PALETTE, colormap: :inferno,
          font: "'Inter', 'Helvetica Neue', Helvetica, Arial, sans-serif"),
        phosphor: Theme.new(name: :phosphor, background: '#040a06', ink: '#9dffb4', muted: '#4fbf6c', grid: '#0f2a17',
          palette: %w[#39ff6a #ffb000 #4fd8ff #ff5ea8 #c6ff3d #ff7a3d #b48cff #f0f0f0], colormap: :phosphor, glow: true,
          font: "'IBM Plex Mono', 'SF Mono', Menlo, monospace"),
      }.freeze
    end
  end
end
