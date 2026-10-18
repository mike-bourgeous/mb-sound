require 'numo/narray'
require_relative 'fast_ui'

module MB
  module Sound
    # Pure-Ruby plotting: terminal text (Braille, block mosaics, eighth
    # blocks, plain ASCII) with ANSI color, SVG, and PNG / inline terminal
    # images, built in layers like a small grammar of graphics:
    #
    #     data -> Scale (x, y, color) -> Coord -> Mark -> Guides -> Layout -> Renderer
    #
    # - Scales (Plot::Scale) map data values to 0..1 and make nice ticks
    #   with labels (linear, log, frequency with note names, dB, time,
    #   symmetric, categorical).
    # - A Coord (Plot::Coord::Cartesian, Plot::Coord::Polar) turns a pair
    #   of scaled values into a position in the unit square.
    # - Marks (Plot::Mark) draw data: lines (decimated to min/max per
    #   column for long signals), steps, points, stems, areas, bands,
    #   heatmaps, rules.
    # - Guides are the axes, grid, legend, colorbar, and title, drawn by
    #   each renderer from the scales and marks.
    # - A Chart is one panel; a Figure lays out several in a grid.
    # - Renderers: Plot::Text (terminal), Plot::SVG, Plot::Image (PNG,
    #   sixel, kitty, iTerm2).
    #
    # Example (also MB::Sound.chart in the console):
    #
    #     wave = 110.hz.saw.sample(4800)
    #     MB::Sound::Plot.chart(title: 'Saw') {
    #       x :time, sample_rate: 48000
    #       line wave, label: 'saw'
    #     }.show
    #
    # See design/notes/plotting.md.
    module Plot
      class PlotError < RuntimeError; end

      class << self
        # True (the default) to draw text plots with the C kernels of
        # MB::Sound::FastUI, false for their exact Ruby mirrors (also
        # MB_SOUND_PLOT=ruby in the environment).  Both give the same text.
        attr_accessor :native
      end
      self.native = ENV['MB_SOUND_PLOT'] != 'ruby'
    end
  end
end

require_relative 'plot/format'
require_relative 'plot/scale'
require_relative 'plot/coord'
require_relative 'plot/theme'
require_relative 'plot/raster'
require_relative 'plot/mark'
require_relative 'plot/chart'
require_relative 'plot/layout'
require_relative 'plot/text'
require_relative 'plot/live'
require_relative 'plot/svg'
require_relative 'plot/image'
require_relative 'plot/ansi_html'
require_relative 'plot/terminal'
require_relative 'plot/plotter'
require_relative 'plot/presets'
require_relative 'plot/panels'
