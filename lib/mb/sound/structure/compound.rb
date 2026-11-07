module MB
  module Sound
    module Structure
      # Compound meter (6/8) on a tracked beat grid (fix-batch-1106).  The
      # tempo estimate and the 4-beat downbeat model assume simple meter,
      # so a 6/8 song comes out as 4/4 at another tempo: at 4/3 of the
      # quarter-note tempo when the grid's beat is a dotted eighth (both
      # 6/8 songs of research-acd-format-2's form comparison: 90 -> 120,
      # 103 -> 137.3), or with a dotted-quarter or eighth beat (synthetic
      # 6/8 grooves here: 90 -> 60, 70 -> 140).  Compound.check reads the
      # onsets around the grid's beats for each of those patterns:
      #
      # - :dotted_eighth: every other beat falls on nothing while onsets
      #   sit at 1/3 and 2/3 of the way between the others (the eighths of
      #   6/8, 1.5 grid beats apart).  The grid is wrong for any meter, so
      #   Structure.analyze regrids it as 6/8 at 3/4 of the tempo (bars
      #   kept: the 4/4 bar was the 6/8 bar).
      # - :ternary: the beat divides in three (onsets at 1/3 and 2/3 of it,
      #   not at 1/2): 12/8 (a shuffle in 4/4) at this tempo, or 6/8 at
      #   3/2 of it (two beats a bar).  Reported only.
      # - :threes: every third beat is accented: 3/4 at this tempo, or 6/8
      #   at half of it (the beat an eighth).  Reported only.
      #
      # The result's +tempo+ is the quarter-note tempo of the 6/8 reading
      # (ACID's and Transport's convention: a 6/8 bar is 3 quarter notes).
      class Compound < Data.define(:kind, :tempo, :evidence, :note)
        # True when the analysis regridded as 6/8 (:dotted_eighth).
        def regridded? = kind == :dotted_eighth

        def to_s = note

        # Onsets at the expected places at least this many times those at
        # the places that must stay quiet (the beats that fall between
        # eighths, the beat's middle, unaccented beats).
        RATIO = 2.0

        # How far around each expected place to look for an onset peak, in
        # grid beats.
        WINDOW = 1 / 24.0

        # The Compound reading of +onset+ (Frames#onset at +fps+) around
        # the beats at +beat_frames+ (frame positions) at +tempo+ (the
        # grid's BPM), or nil if it reads as simple meter (or too few
        # beats).
        def self.check(onset, fps, beat_frames, tempo)
          return nil if beat_frames.length < 8 || onset.size == 0
          period = beat_frames.each_cons(2).map { |a, b| b - a }.sort[(beat_frames.length - 1) / 2]
          w = [(period * WINDOW).round, 1].max
          floor = onset.mean + 1e-9
          at = ->(f) {
            lo = (f - w).round.clamp(0, onset.size - 1)
            hi = (f + w).round.clamp(lo, onset.size - 1)
            onset[lo..hi].max
          }
          mean = ->(list) { list.empty? ? 0.0 : list.sum / list.length / floor }
          bf = beat_frames[0...-1] # (each beat with the one after it)

          # Dotted eighths: the beats of one parity on nothing, the eighths
          # at 1/3 and 2/3 of the two-beat span from the other parity
          parity = [0, 1].max_by { |p| mean.(bf.each_with_index.select { |_, i| i % 2 == p }.map { |f, _| at.(f) }) }
          strong = bf.each_with_index.select { |_, i| i % 2 == parity }.map(&:first)
          weak = bf.each_with_index.select { |_, i| i % 2 != parity }.map { |f, _| at.(f) }
          eighths = strong.flat_map { |f| [at.(f + period * 2 / 3.0), at.(f + period * 4 / 3.0)] }
          e = mean.(eighths)
          wk = mean.(weak)
          if e > 1 && e > wk * RATIO
            return new(kind: :dotted_eighth, tempo: tempo * 3 / 4.0, evidence: { eighths: e.round(2), between_beats: wk.round(2) },
              note: format('6/8 at %.2f BPM: every other beat of the %.2f BPM grid fell between eighths (onsets %.1fx there, %.1fx between)',
                tempo * 3 / 4.0, tempo, e, wk))
          end

          # The beat in three
          thirds = mean.(bf.flat_map { |f| [at.(f + period / 3.0), at.(f + period * 2 / 3.0)] })
          half = mean.(bf.map { |f| at.(f + period / 2.0) })
          if thirds > 1 && thirds > half * RATIO
            return new(kind: :ternary, tempo: tempo * 3 / 2.0, evidence: { thirds: thirds.round(2), half: half.round(2) },
              note: format('the beat divides in three: 12/8 (a 4/4 shuffle) at %.2f BPM, or 6/8 at %.2f BPM (onsets %.1fx at thirds, %.1fx at halves)',
                tempo, tempo * 3 / 2.0, thirds, half))
          end

          # Accents every third beat
          levels = beat_frames.map { |f| at.(f) }
          groups = (0...3).map { |k| mean.(levels.each_with_index.select { |_, i| i % 3 == k }.map(&:first)) }
          top = groups.max
          rest = groups.sort[0..1]
          if top > 1 && rest.all? { |g| top > g * RATIO } && rest.min > 0.5
            return new(kind: :threes, tempo: tempo / 2.0, evidence: { accented: top.round(2), others: rest.map { |g| g.round(2) } },
              note: format('every third beat is accented: 3/4 at %.2f BPM, or 6/8 at %.2f BPM (beats %.1fx, %.1fx, %.1fx)',
                tempo, tempo / 2.0, *groups))
          end

          nil
        end
      end
    end
  end
end
