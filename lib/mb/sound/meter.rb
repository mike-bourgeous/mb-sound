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
        cols = IO.console.winsize[1] - (5 + 7 + 8 + 2) # 5 for index, 7 for decibels, 8 for frequency, 2 for good measure

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

      # Draws horizontal axes for pan and fade, with the pan and fade values
      # marked.
      def self.pan_fade_bars(min_pan, avg_pan, max_pan, min_fade, avg_fade, max_fade, rows_below = 0)
        cols = IO.console.winsize[1] - (5 + 7 + 4) # labels, values, spaces

        up(1 + rows_below)

        [
          ['Pan', min_pan, avg_pan, max_pan],
          ['Fade', min_fade, avg_fade, max_fade]
        ].each do |(label, min, avg, max)|
          core_width = (MB::M.scale(max, -1..1, 0..cols) - MB::M.scale(min, -1..1, 0..cols) + 1).ceil
          core_width = cols if core_width > cols
          lower_core = (MB::M.scale(avg, -1..1, 0..cols) - MB::M.scale(min, -1..1, 0..cols)).ceil
          upper_core = [0, core_width - (lower_core + 1)].max

          lower_axis = [0, MB::M.scale(min, -1..1, 0..cols).floor].max
          upper_axis = cols - core_width - lower_axis

          # FIXME: fix the math instead of this hack
          if upper_axis < 0
            lower_axis += upper_axis
            upper_axis = 0
          end

          binding.pry if lower_core < 0 || upper_core < 0 || core_width == 0
          binding.pry if lower_axis < 0 || upper_axis < 0 || core_width+lower_axis+upper_axis != cols

          core_str = "#{'=' * lower_core}|#{'=' * upper_core}"
          meter_str = "#{'-' * lower_axis}#{core_str}#{'-' * upper_axis}"

          puts(
            '',
            CodeRay.scan(
              {label: label, cols: cols, cw: core_width, lc: lower_core, uc: upper_core, cs: core_str, la: lower_axis, ua: upper_axis, ms: meter_str, total: core_width + lower_axis + upper_axis}.pretty_inspect,
              :ruby
            ).term,
            ''
          ) if false# XXX

          label_text = label.ljust(5)
          value_text = ('%.4f' % avg).rjust(7)

          STDOUT.write("\r#{label_text} #{value_text} #{meter_str}\e[K")
          down(1) if label == 'Pan'
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
