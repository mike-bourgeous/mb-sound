module MB
  module Sound
    module Sequence
      # Helpers for musical durations.  Durations are stored as exact Rational
      # numbers of whole notes (e.g. 1/4r for a quarter note).
      #
      # Methods that accept a duration take an Integer note division (4 for a
      # quarter note, 6 for a half note triplet, 16 for a sixteenth note) or a
      # Rational/Float fraction of a whole note (3/8r for a dotted quarter).
      module Duration
        # Note divisions that get predefined n* methods (e.g. Note#n4).  Any
        # other division is available with #n(k).
        DIVISIONS = [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32, 64, 128].freeze

        # Long names for common note lengths, as note divisions.
        NAMES = {
          whole: 1,
          half: 2,
          quarter: 4,
          eighth: 8,
          sixteenth: 16,
          thirty_second: 32,
          sixty_fourth: 64,
        }.freeze

        # Multipliers for dotted, double-dotted, and triplet durations.
        DOTTED = 3/2r
        DOUBLE_DOTTED = 7/4r
        TRIPLET = 2/3r

        # The length of a step whose duration was never set.
        DEFAULT = 1/4r

        # Converts a duration argument to a Rational number of whole notes.
        # See the Duration module description.
        def self.whole_notes(duration)
          case duration
          when Integer
            raise ArgumentError, "Note division must be positive (got #{duration})" unless duration > 0
            Rational(1, duration)

          when Rational
            raise ArgumentError, "Duration must be positive (got #{duration})" unless duration > 0
            duration

          when Float
            raise ArgumentError, "Duration must be positive and finite (got #{duration})" unless duration.finite? && duration > 0
            rational(duration)

          else
            raise ArgumentError, "Duration must be an Integer note division or a Rational/Float fraction of a whole note (got #{duration.inspect})"
          end
        end

        # Converts a Numeric to an exact Rational, turning Floats into the
        # simplest Rational within one millionth (e.g. 0.85 becomes 17/20).
        # Used wherever Floats are accepted for musical amounts (durations,
        # legato fractions, fade lengths).
        def self.rational(value)
          value.is_a?(Float) ? value.rationalize(Rational(1, 1_000_000)) : value.to_r
        end

        # Formats a duration in whole notes for display, e.g. "n4" for 1/4r
        # or "3/8" for a dotted quarter.
        def self.format(whole_notes)
          if whole_notes.numerator == 1
            "n#{whole_notes.denominator}"
          else
            whole_notes.to_s
          end
        end
      end
    end
  end
end
