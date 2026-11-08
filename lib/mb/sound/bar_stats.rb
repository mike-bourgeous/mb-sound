require_relative 'bar_stats/grid'
require_relative 'bar_stats/bands'
require_relative 'bar_stats/timing'

module MB
  module Sound
    # Statistics per beat, bar, section, and song (bar-stats-1, 2026-11-08;
    # design/notes/bar_stats.md).  This step: the grids they count on
    # (Grid) and timing per band (Bands, Timing).
    module BarStats
      # The rate statistics are measured at (files are resampled to it, as
      # Structure and Analysis read them).
      RATE = 48000
    end
  end
end
