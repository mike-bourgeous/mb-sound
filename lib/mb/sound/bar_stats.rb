require_relative 'bar_stats/grid'
require_relative 'bar_stats/bands'
require_relative 'bar_stats/timing'
require_relative 'bar_stats/table'
require_relative 'bar_stats/measures'
require_relative 'bar_stats/broadcast'
require_relative 'bar_stats/report'
require_relative 'bar_stats/sidecar'
require_relative 'bar_stats/comparison'

module MB
  module Sound
    # Statistics per beat, bar, section, and song (bar-stats-1, 2026-11-08;
    # design/notes/bar_stats.md): timing per band against the grid,
    # loudness, spectrum, stereo, and harmony, beat by beat on the song's
    # grid (exact for our renders, tracked for outside audio), saved as a
    # sidecar of readable Ruby beside the file with a broadcast loudness
    # report, and compared bar by bar between two recordings (worst bars,
    # what moved, likely causes, pass/fail).  For finding localized mix and
    # .acd conversion problems, and later per-bar mastering.
    #
    #     r = BarStats.analyze('song.flac', bpm: 140)     # console: bar_stats
    #     r.bars[:lufs]; r.bar(9); puts r.broadcast
    #     c = BarStats.compare('v13.flac', 'v15.flac', bpm: 140)   # compare_bars
    #     puts c.narrative
    module BarStats
      # The rate statistics are measured at (files are resampled to it, as
      # Structure and Analysis read them; the broadcast report reads files
      # at their own rate).
      RATE = 48000

      # Extensions of the audio files a stem directory holds.
      AUDIO_EXTENSIONS = %w[flac wav ogg opus mp3 m4a aac aif aiff caf].freeze

      # Measures +source+ (a filename or audio data: an Array of channels or
      # a Numo array at +:sample_rate+) and returns a Report.
      #
      # The grid (see Grid): +grid:+ a Grid (a render's), a
      # Structure::Result, or a Transport or Session whose timeline starts
      # at the audio's start; else +bpm:+ with +offset:+ (bar 1's downbeat
      # in seconds) for a constant grid; else beat tracking
      # (Structure.analyze, +bpm:+ as a hint).  +beats_per_bar:+ for
      # constant and tracked grids.
      #
      # +sections:+ :auto (the grid's: a render's form passes, a tracked
      # song's analysis; Structure::Sections on the grid's bars otherwise),
      # false for none, or Structure::Section values.
      #
      # +stems:+ a Hash of name => file or audio (or a directory of audio
      # files): each measured on the same grid (Report#stems).
      # +targets:+ the Broadcast targets.  +save:+ writes the sidecar beside
      # a file (and each stem's beside it); +cache:+ reads a fresh sidecar
      # instead of measuring (Sidecar.fresh?).
      def self.analyze(source, sample_rate: RATE, grid: nil, bpm: nil, offset: nil, beats_per_bar: 4, sections: :auto,
                       stems: nil, targets: Broadcast::TARGETS, window: Timing::WINDOW, save: false, cache: false)
        file = source.is_a?(String) ? source : nil
        settings = request_settings(grid: grid, bpm: bpm, offset: offset, beats_per_bar: beats_per_bar, sections: sections, window: window)
        if file && cache && Sidecar.fresh?(Sidecar.path(file), file, settings)
          report = Sidecar.read(Sidecar.path(file))
          return report if stems.nil? || !report.stems.empty?
        end

        channels, rate = read(source, sample_rate)
        grid = resolve_grid(channels, rate, grid: grid, bpm: bpm, offset: offset, beats_per_bar: beats_per_bar, sections: sections)
        analyzer = Loudness::Analyzer.new(channels: channels.length, sample_rate: rate).process(channels)
        measures = Measures.new(channels, rate, grid, analyzer: analyzer, window: window)
        native = file && file_rate(file)
        broadcast = native && native != rate ? Broadcast.of(file, targets: targets) : Broadcast.new(**Broadcast.from_result(analyzer.result), targets: targets)

        stem_reports = stem_sources(stems).to_h { |name, s|
          [name, analyze(s, sample_rate: rate, grid: grid, sections: grid.sections, targets: targets, window: window, save: save && s.is_a?(String))]
        }

        source_info = file ? { file: File.expand_path(file), digest: Sidecar.digest(file), bytes: File.size(file) } : { file: nil }
        report = Report.new(grid: grid, beats: measures.beats, bars: measures.bars, sections: measures.sections, song: measures.song,
                            broadcast: broadcast, settings: settings.merge(sample_rate: rate.to_f, source: grid.source, tempo: grid.tempo,
                              bands: Bands::EDGES, octaves: Analysis::Spectrum::OCTAVE_CENTERS, min_fft: Measures::MIN_FFT),
                            source: source_info, stems: stem_reports)
        report.save if save && file
        report
      end

      # Reads the sidecar at +path+ (or of audio file +path+) into a Report.
      def self.load(path)
        path = Sidecar.path(path) unless path.end_with?(Sidecar::EXTENSION)
        Sidecar.read(path)
      end

      # Compares +a+ with +b+ bar by bar (see Comparison): each a file,
      # audio data, or a Report (sidecar statistics; per-band lags then
      # need the audio).  Options for measuring go to .analyze; +b+ is
      # measured on +a+'s grid (shifted by +align+ seconds when given).
      def self.compare(a, b, align: 0, max_lag: Comparison::MAX_LAG, thresholds: {}, **options)
        Comparison.of(a, b, align: align, max_lag: max_lag, thresholds: thresholds, **options)
      end

      # The settings recorded for a request (what a cached sidecar must
      # match).
      def self.request_settings(grid:, bpm:, offset:, beats_per_bar:, sections:, window:)
        g =
          case grid
          when nil then bpm && offset ? :given : :tracked
          when Grid then grid.source
          when Structure::Result then grid.tracker == :transport ? :transport : :tracked
          else :transport
          end
        { grid: g, bpm: bpm&.to_f, offset: offset&.to_f, beats_per_bar: beats_per_bar, sections: sections == :auto || sections == false ? sections : :given, window: window.to_f }
      end

      # [channels (DFloats), rate] of +source+.
      def self.read(source, sample_rate)
        data =
          case source
          when String then MB::Sound.read(source, sample_rate: sample_rate)
          when Numo::NArray then [source]
          when Array then source[0].is_a?(Numeric) ? [Numo::DFloat.cast(source)] : source
          else raise ArgumentError, "Pass a sound file or audio data (an Array of channels or a Numo array), not #{source.class}"
          end
        raise ArgumentError, 'The audio is empty' if data.empty? || data[0].size == 0
        [data.map { |c| Numo::DFloat.cast(c) }, sample_rate.to_f]
      end

      # The sample rate of sound file +file+.
      def self.file_rate(file)
        input = FFMPEGInput.new(file)
        input.sample_rate.to_f
      ensure
        input&.close
      end

      # The Grid for a request (see .analyze).
      def self.resolve_grid(channels, rate, grid:, bpm:, offset:, beats_per_bar:, sections:)
        duration = channels[0].length / rate
        g =
          case grid
          when Grid then grid
          when Structure::Result then Grid.from_structure(grid, sections: sections == :auto)
          when nil
            if bpm && offset
              Grid.constant(bpm: bpm, offset: offset, beats_per_bar: beats_per_bar, duration: duration)
            else
              Grid.from_structure(Structure.analyze(channels, sample_rate: rate, bpm: bpm, beats_per_bar: beats_per_bar), sections: sections == :auto)
            end
          else
            Grid.from_structure(Structure.analyze(channels, sample_rate: rate, grid: grid, beats_per_bar: beats_per_bar), sections: sections == :auto)
          end

        case sections
        when false then g.with_sections([])
        when :auto then g.sections.empty? && !g.bars.empty? ? g.with_sections(analysis_sections(channels, rate, g)) : g
        else g.with_sections(sections)
        end
      end

      # Structure's sections (S2) on +grid+'s bars.
      def self.analysis_sections(channels, rate, grid)
        mono = Structure.mixdown(channels, rate)
        frames = Structure::Frames.new(mono, sample_rate: rate)
        usual = grid.bars.map(&:beats).tally.max_by(&:last)&.first || 4
        Structure::Sections.find(BarsOnly.new(frames, grid.bars, usual))[0]
      end

      # What Structure::Sections.find reads of a Structure::Result.
      BarsOnly = Struct.new(:frames, :bars, :beats_per_bar)

      # Stems as { name => file or audio }.
      def self.stem_sources(stems)
        case stems
        when nil then {}
        when Hash then stems.transform_keys(&:to_sym)
        when String
          raise ArgumentError, "No stem directory #{stems}" unless File.directory?(stems)
          Dir.glob(File.join(stems, '*')).select { |f| File.file?(f) && AUDIO_EXTENSIONS.include?(File.extname(f).delete('.').downcase) }
            .sort.to_h { |f| [File.basename(f, '.*').to_sym, f] }
        else raise ArgumentError, "stems: is a Hash of name => file or a directory (got #{stems.class})"
        end
      end
    end
  end
end
