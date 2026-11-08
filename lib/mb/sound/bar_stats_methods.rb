module MB
  module Sound
    # Console methods for statistics per beat, bar, and section (see
    # MB::Sound::BarStats).
    module BarStatsMethods
      # Measures +source+ (a sound file, or audio data at +:sample_rate+)
      # beat by beat and returns a BarStats::Report: per beat, bar, section,
      # and song the onset timing per band, loudness (LUFS, momentary and
      # short-term maxima, RMS, peaks, true peak, crest, tails), octave band
      # levels, centroid and tilt, stereo width and correlation (per band
      # too), and chroma and key, with a broadcast loudness report
      # (integrated, LRA, true peak, PLR, pass/fail against EBU R 128, ATSC
      # A/85, and streaming).  Prints a summary in the console.
      #
      # The grid: a render's own (`render 'song.flac', bar_stats: true`
      # writes the sidecar with it), +bpm:+ and +offset:+ (bar 1's downbeat
      # in seconds) for a known tempo, else beat tracking (+bpm:+ as a
      # hint).  +save: true+ writes the sidecar beside the file
      # ("song.flac.bar_stats.rb", readable Ruby; BarStats.load reads it),
      # +cache: true+ reads a fresh one instead of measuring.  Other options
      # go to BarStats.analyze (+stems:+, +sections:+, +targets:+, ...).
      #
      # Examples:
      #     r = bar_stats('song.flac', bpm: 140)
      #     r.bars[:lufs]            # Numo::DFloat per bar
      #     r.bar(9)                 # one bar's measures as a Hash
      #     puts r.broadcast         # the broadcast loudness report
      #     bar_stats 'song.flac', save: true
      def bar_stats(source, **options)
        report = BarStats.analyze(source, **options)
        puts report if MB::Sound.live?
        report
      end

      # Compares +b+ with +a+ bar by bar (sound files, audio data, or
      # BarStats::Reports): per bar what changed (timing per band as
      # lags of B behind A, loudness, spectrum, stereo, chroma), the worst
      # bars, likely causes, and a narrative (BarStats::Comparison).  +b+
      # is measured on +a+'s grid (+align:+ seconds when B starts later).
      # Prints the narrative in the console.  With +sections:+ [a_label,
      # b_label], compares two sections of one recording +a+.
      #
      # Examples:
      #     c = compare_bars('v13.flac', 'v15.flac', bpm: 140)
      #     c.worst(5)
      #     c.causes.map(&:text)
      #     c.check!(timing: 2, lufs: 0.5)    # raises naming the failing bars
      #     compare_bars(bar_stats('song.flac'), sections: ['A', "A'"])
      def compare_bars(a, b = nil, sections: nil, **options)
        result =
          if sections
            report = a.is_a?(BarStats::Report) ? a : BarStats.analyze(a, **options.except(:thresholds))
            BarStats::Comparison.sections(report, *sections, thresholds: options[:thresholds] || {})
          else
            raise ArgumentError, 'Pass two recordings to compare (or one with sections: [a, b])' if b.nil?
            BarStats.compare(a, b, **options)
          end
        puts result if MB::Sound.live?
        result
      end
    end
  end
end
