require 'digest'
require 'time'

module MB
  module Sound
    module BarStats
      # The bar statistics of one recording: its Grid, the beats, bars,
      # sections, and song Tables (Measures), the Broadcast loudness
      # report, the settings and source it was made from, and the stems'
      # Reports (measured on the same grid) when given.  Saves as a
      # sidecar of readable Ruby beside the file (#save, Sidecar) and
      # reads back with BarStats.load.
      #
      #     r = bar_stats('song.flac')
      #     r.bars[:lufs]          # Numo::DFloat per bar
      #     r.bar(9)               # { bar: 9, seconds: 16.457, lufs: -13.1, ... }
      #     puts r.broadcast
      class Report
        attr_reader :grid, :beats, :bars, :sections, :song, :broadcast, :settings, :source, :stems

        # +source+: { file:, digest:, bytes: } (file nil for audio data).
        def initialize(grid:, beats:, bars:, sections:, song:, broadcast:, settings:, source:, stems: {})
          @grid = grid
          @beats = beats
          @bars = bars
          @sections = sections
          @song = song
          @broadcast = broadcast
          @settings = settings.freeze
          @source = source.freeze
          @stems = stems.freeze
        end

        # The row of bar +n+ (a Hash), or nil.
        def bar(n) = @bars.at(n)

        # The row of beat +beat+ of bar +n+, or nil.
        def beat(n, beat) = @beats.at([n, beat])

        # The row of the section labeled +label+ ("A", "drop", "drop 2"),
        # or nil.
        def section(label) = @sections.at(label.to_s)

        # The file the statistics are of (nil for audio data).
        def file = @source[:file]

        # Writes the sidecar to +path+ (Sidecar.path(file) by default) and
        # returns the path.
        def save(path = nil)
          path ||= Sidecar.path(file || raise(ArgumentError, 'Pass a path to save statistics of audio data'))
          File.write(path, to_ruby(base: File.dirname(path)))
          path
        end

        # The sidecar text (see Sidecar); +base+ is the directory file paths
        # are written relative to.
        def to_ruby(base: nil)
          Sidecar.write(self, base: base)
        end

        def to_s
          lines = []
          lines << "Bar statistics of #{file || 'audio data'}: #{@grid}"
          lines << @broadcast.to_s.lines.map { |l| "  #{l.chomp}" }.join("\n") if @broadcast
          lines << '  Sections:' unless @sections.length == 0
          @sections.each { |s| lines << format('    %-8s %s LUFS, crest %s dB, width %s dB, key %s', s[:section], n(s[:lufs]), n(s[:crest]), n(s[:width]), s[:key] || '?') }
          unless @stems.empty?
            lines << "  Stems: #{@stems.map { |k, r| "#{k} #{n(r.song.row(0)[:lufs])} LUFS" }.join(', ')}"
          end
          lines.join("\n")
        end

        def inspect
          "#<BarStats::Report #{file || 'audio data'}: #{@bars.length} bars, #{@sections.length} sections>"
        end

        private

        def n(v) = v.nil? ? 'n/a' : (v.finite? ? format('%.1f', v) : '-inf')
      end
    end
  end
end
