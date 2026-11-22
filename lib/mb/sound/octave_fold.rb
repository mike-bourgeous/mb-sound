module MB
  module Sound
    # A note or frequency range that notes and frequencies move into by
    # whole octaves, keeping their pitch class (so their degree in the
    # key): the one core of every `within(range)` (note-within-1,
    # 2026-11-22; the maintainer: "the same scale degree as the current
    # note but locked within a specified note range or freq range").
    #
    #     lead.within(E1..E2)                    # MIDI streams, Notes (live)
    #     riff.within(C4..C5)                    # clips, Seqs, generators (each cycle)
    #     notes.freq.within(2.hz..8.hz)          # a node of Hz (GraphNode::Within)
    #     A4.within(E1..E2)                      # a Note or Pitch value (A1)
    #
    # The range is notes (`E1..E2`, plain numbers are MIDI note numbers) or
    # frequencies (`60.hz..120.hz`, constant Pitches); its ends may mix
    # the two (each end converts through the session Tuning where the
    # other kind is needed: notes for notes, Hz for signals).  The upper
    # end follows Ruby: `E1..E2` includes E2, `E1...E2` doesn't.
    #
    # A value already in the range stays.  One below it moves up by the
    # fewest octaves that reach the range, one above moves down by the
    # fewest that reach it, so a range wider than an octave keeps the
    # contour of what already fits.  A range narrower than an octave may
    # hold no octave of a pitch class: then the value takes the octave
    # nearest the range's middle (in pitch; the lower one when both are
    # as near) and is clamped to that edge (the last note of an exclusive
    # range of whole notes).
    class OctaveFold
      # The Range this fold was made from, as given.
      attr_reader :range

      # Semitones per octave (the session Tuning is 12-TET).
      OCTAVE = 12

      # +range+ as an OctaveFold (OctaveFold instances pass through).
      def self.[](range)
        range.is_a?(OctaveFold) ? range : new(range)
      end

      # A fold into +range+ (see the class description).
      def initialize(range)
        unless range.is_a?(Range)
          raise ArgumentError, "within takes a Range of notes or frequencies, like within(E1..E2) or within(60.hz..120.hz) (got #{range.inspect})"
        end
        if range.begin.nil? || range.end.nil?
          raise ArgumentError, "within needs both ends of its range, like within(E1..E2) (got #{range.inspect})"
        end

        @range = range
        @exclusive = range.exclude_end?
        @low = OctaveFold.end_of(range.begin)
        @high = OctaveFold.end_of(range.end)
        lo, hi = note_bounds
        if lo > hi || (lo == hi && @exclusive)
          raise ArgumentError, "within's range must run from low to high and hold something (got #{self})"
        end
      end

      # True if the range leaves out its upper end (`E1...E2`).
      def exclusive? = @exclusive

      # True if an end is a note (its frequency follows the session Tuning).
      def notes? = @low[0] == :note || @high[0] == :note

      # The range's ends as (fractional) MIDI note numbers [low, high]:
      # note ends as given, frequency ends through the session Tuning.
      def note_bounds(tuning = MB::Sound.tuning)
        [OctaveFold.note_of(@low, tuning), OctaveFold.note_of(@high, tuning)]
      end

      # The range's ends in Hz [low, high]: frequency ends as given, note
      # ends through +tuning+ (the session Tuning).
      def hz_bounds(tuning = MB::Sound.tuning)
        [OctaveFold.hz_of(@low, tuning), OctaveFold.hz_of(@high, tuning)]
      end

      # MIDI note number +n+ (an Integer stays an Integer) moved into the
      # range by octaves.
      def note(n)
        lo, hi = note_bounds
        OctaveFold.fold_notes(n, lo, hi, @exclusive)
      end

      # Frequency +f+ (Hz) moved into the range by octaves (see .fold_hz
      # for zero, negative, and non-finite frequencies).
      def hz(f)
        lo, hi = hz_bounds
        OctaveFold.fold_hz(f.to_f, lo, hi, @exclusive)
      end

      # A clip or stream value moved into the range: a note number, a Note
      # (stays a Note, by its fractional number), or a constant Pitch (a
      # fixed frequency, folded in Hz); nil passes through.  Anything else
      # (drum names) raises.
      def value(v)
        case v
        when nil then nil
        when Numeric
          raise ArgumentError, "within moves note numbers (got #{v.inspect})" unless v.real?
          note(v)
        when Note
          n = v.detune == 0 ? v.number : v.detuned_number
          to = note(n)
          to == n ? v : v.transpose(to - n)
        when Pitch
          raise ArgumentError, "within moves fixed pitches in clips; #{v} changes (use a node's within)" unless v.constant?
          f = v.frequency
          to = hz(f)
          to == f ? v : Pitch.new(to, sample_rate: v.sample_rate)
        else
          raise ArgumentError, "within moves notes and frequencies (got #{v.inspect}: drum names and other values have no pitch)"
        end
      end

      # The range as Ruby (`E1..E2`, `2.hz..8.hz`).
      def to_s
        RubyValue.to_ruby(@range)
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      def ==(other)
        other.is_a?(OctaveFold) && other.range == @range
      end
      alias eql? ==

      def hash
        @range.hash
      end

      # A range end as [:note, number] or [:hz, frequency].
      def self.end_of(x)
        case x
        when Note
          [:note, x.detune == 0 ? x.number : x.detuned_number]
        when Pitch
          raise ArgumentError, "within's range ends are notes or fixed frequencies (got #{x}, which changes)" unless x.constant?
          f = x.frequency.to_f
          raise ArgumentError, "within's frequency ends are above 0 Hz (got #{x})" unless f.finite? && f > 0
          [:hz, f]
        when Numeric
          unless x.real? && (!x.is_a?(Float) || x.finite?)
            raise ArgumentError, "within's range ends are notes (E1, or MIDI numbers like 28) or frequencies (60.hz) (got #{x.inspect})"
          end
          [:note, x]
        else
          raise ArgumentError, "within's range ends are notes (E1, or MIDI numbers like 28) or frequencies (60.hz) (got #{x.inspect})"
        end
      end

      # The note number of end +e+ (see .end_of) in +tuning+.
      def self.note_of(e, tuning)
        e[0] == :note ? e[1] : tuning.number_of(e[1])
      end

      # The frequency of end +e+ (see .end_of) in +tuning+.
      def self.hz_of(e, tuning)
        e[0] == :hz ? e[1] : tuning.frequency_of(e[1])
      end

      # Note number +x+ moved into +lo+..+hi+ (+exclusive+: below +hi+) by
      # octaves of 12 semitones (see the class description); exact for
      # Integers and Rationals.
      def self.fold_notes(x, lo, hi, exclusive)
        fits = ->(y) { y >= lo && (exclusive ? y < hi : y <= hi) }
        return x if fits.(x)

        if x < lo
          y = x + OCTAVE * ((lo - x) / Rational(OCTAVE)).ceil
          return y if fits.(y)
          below = y - OCTAVE
        else
          y = x - OCTAVE * ((x - hi) / Rational(OCTAVE)).ceil
          y -= OCTAVE if exclusive && y >= hi
          return y if y >= lo
          below = y
        end

        # (narrower than an octave: the octave nearest the middle, clamped)
        if lo + hi <= 2 * below + OCTAVE
          lo
        else
          exclusive && hi.is_a?(Integer) && lo.is_a?(Integer) ? hi - 1 : hi
        end
      end

      # Frequency +x+ (a Float, Hz) moved into +lo+..+hi+ (+exclusive+:
      # below +hi+) by octaves, scaling by powers of two only (exact): the
      # Ruby mirror of FastControl.octave_fold's per-sample step.  Zero
      # stays zero, a negative frequency folds its size and keeps its sign
      # (the same pitch running backward), and NaN and infinities pass
      # through.
      def self.fold_hz(x, lo, hi, exclusive)
        return x if x.nan? || x.infinite? || x == 0
        return -fold_hz(-x, lo, hi, exclusive) if x < 0
        return x if x >= lo && (exclusive ? x < hi : x <= hi)

        if x < lo
          y = Math.ldexp(x, Math.frexp(lo)[1] - Math.frexp(x)[1])
          y *= 2 while y < lo
          y *= 0.5 while y * 0.5 >= lo
          return y if exclusive ? y < hi : y <= hi
          below = y * 0.5
        else
          y = Math.ldexp(x, Math.frexp(hi)[1] - Math.frexp(x)[1])
          y *= 0.5 while exclusive ? y >= hi : y > hi
          y *= 2 while exclusive ? y * 2 < hi : y * 2 <= hi
          return y if y >= lo
          below = y
        end

        # (narrower than an octave: the octave nearest the middle in pitch,
        # mid / below <= 2 below / mid, clamped)
        lo * hi <= 2 * below * below ? lo : hi
      end
    end
  end
end
