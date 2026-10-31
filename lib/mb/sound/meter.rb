require 'io/console'

module MB
  module Sound
    module Meter
      # Draws volume meters on the console for each of the DFTs passed in,
      # starting at dfts.size + rows_below rows up.
      def self.meters(dfts, rows_below = 0, hz_per_bin = nil)
        levels = []
        freq_text = []
        dfts.each_with_index do |c, idx|
          abs = c.not_inplace!.abs
          level = abs.sum
          levels[idx] = level
          freq_text[idx] = "#{'%5d' % (abs.max_index * hz_per_bin)}Hz" if hz_per_bin
        end

        linear_meters(levels, rows_below, freq_text)
      end

      # Draws volume meters on the console for the list of linear amplitude
      # values passed in, starting at levels.size + rows_below rows up.  +text+
      # may be an array of strings up to 7 characters long to display before the
      # meter.
      def self.linear_meters(levels, rows_below = 0, texts = nil)
        cols = MB::U.width - (5 + 7 + 8 + 2) # 5 for index, 7 for decibels, 8 for frequency, 2 for good measure

        up(levels.size - 1 + rows_below)

        levels.each_with_index do |level, idx|
          level = level.to_db
          width = MB::M.clamp((level + 60) * cols / 70, 0, cols) # range -60dB to +10dB

          index_text = (idx + 1).to_s.rjust(4)
          level_text = "#{level.infinite? ? '-inf' : level.to_i.to_s}dB".rjust(6)
          freq_text = (texts && texts[idx]) || '       '

          STDOUT.write("\r#{index_text} #{level_text} #{'%7s' % freq_text} #{'|' * width}\e[K")

          down(1) if idx < levels.size - 1
        end

        if rows_below
          down(rows_below)
          STDOUT.write("\r")
        end

        STDOUT.flush
      end

      def self.up(rows)
        STDOUT.write("\e[#{rows}A") if rows > 0
      end

      def self.down(rows)
        STDOUT.write("\e[#{rows}B") if rows > 0
      end
    end
  end
end
