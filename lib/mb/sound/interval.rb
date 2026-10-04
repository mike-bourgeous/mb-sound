module MB
  module Sound
    # A musical pitch interval: `4.octaves` (`.oct`), `7.semitones` (`.st`,
    # `.semi`), or `50.cents`.  Intervals are values like Lengths and
    # Durations: they compare, add and subtract with each other, scale by
    # numbers, and convert with #to_semitones, #to_octaves, #to_cents, and
    # #ratio (the frequency ratio).  Every method that takes an interval
    # also accepts a plain number in that method's usual unit (semitones for
    # transposing, octaves for filter sweeps), via Interval.semitones or
    # Interval.octaves.
    #
    # Whole numbers of cents are kept exact (as Rational semitones), so
    # `1200.cents == 1.octave`.
    #
    # Examples:
    #     C4.transpose(7.st)              # G4
    #     clip.transpose(-1.oct)
    #     (1.oct + 50.cents).to_semitones # => (25/2)
    #     7.st.ratio                      # => 1.498... (a 12-TET fifth)
    class Interval
      include Comparable

      # The size in semitones (an Integer, Rational, or Float).
      attr_reader :semitones

      # Converts an Interval or a plain number of semitones (or anything that
      # responds to #to_semitones) to a number of semitones.
      def self.semitones(value)
        return value.to_semitones if value.respond_to?(:to_semitones)
        return value if value.is_a?(Numeric)

        raise ArgumentError, "Expected an interval or a number of semitones (got #{value.inspect})"
      end

      # Converts an Interval or a plain number of octaves (or anything that
      # responds to #to_octaves) to a number of octaves.
      def self.octaves(value)
        return value.to_octaves if value.respond_to?(:to_octaves)
        return value if value.is_a?(Numeric)

        raise ArgumentError, "Expected an interval or a number of octaves (got #{value.inspect})"
      end

      # Creates an interval of +semitones+.  The +unit+ (:octaves, :semitones,
      # or :cents) is only used to display the interval (see #to_s).
      def initialize(semitones, unit: :semitones)
        raise ArgumentError, "An interval needs a number (got #{semitones.inspect})" unless semitones.is_a?(Numeric)
        raise ArgumentError, "Unknown interval unit #{unit.inspect}" unless [:octaves, :semitones, :cents].include?(unit)

        @semitones = semitones
        @unit = unit
      end

      def to_semitones
        @semitones
      end

      def to_octaves
        exact_divide(@semitones, 12)
      end

      def to_cents
        @semitones * 100
      end

      # The frequency ratio of this interval in equal temperament (2.0 for an
      # octave).
      def ratio
        2.0 ** (@semitones / 12.0)
      end

      def +(other)
        Interval.new(@semitones + same_type(other).semitones, unit: @unit)
      end

      def -(other)
        Interval.new(@semitones - same_type(other).semitones, unit: @unit)
      end

      def -@
        Interval.new(-@semitones, unit: @unit)
      end

      # Scales by a number.
      def *(other)
        raise ArgumentError, 'Intervals can only be multiplied by numbers' unless other.is_a?(Numeric)
        Interval.new(@semitones * other, unit: @unit)
      end

      # Divides by a number, or by another interval (giving their ratio as a
      # number).
      def /(other)
        return exact_divide(@semitones, other.semitones) if other.is_a?(Interval)
        raise ArgumentError, 'Intervals can only be divided by numbers or intervals' unless other.is_a?(Numeric)

        Interval.new(exact_divide(@semitones, other), unit: @unit)
      end

      # Allows e.g. `2 * 7.st`.
      def coerce(other)
        raise TypeError, "#{other.class} can't be coerced into an interval" unless other.is_a?(Numeric)
        [Scale.new(other), self]
      end

      def <=>(other)
        other.is_a?(Interval) ? @semitones <=> other.semitones : nil
      end

      def hash
        [Interval, @semitones].hash
      end

      def eql?(other)
        other.is_a?(Interval) && @semitones == other.semitones
      end

      def zero?
        @semitones.zero?
      end

      def abs
        Interval.new(@semitones.abs, unit: @unit)
      end

      # Shows the interval in the unit it was made with, e.g. "7 st",
      # "1 oct", "50 cents".
      def to_s
        case @unit
        when :octaves then "#{format_number(to_octaves)} oct"
        when :cents then "#{format_number(to_cents)} cents"
        else "#{format_number(@semitones)} st"
        end
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      # Multiplies an interval by a number on the left (see #coerce).
      class Scale
        def initialize(value)
          @value = value
        end

        def *(interval)
          interval * @value
        end
      end

      private

      def same_type(other)
        raise ArgumentError, "Expected an interval (got #{other.inspect}); use e.g. 2.st for semitones" unless other.is_a?(Interval)
        other
      end

      # Keeps Integer and Rational arithmetic exact.
      def exact_divide(a, b)
        a.is_a?(Float) || b.is_a?(Float) ? a / b.to_f : Rational(a, b)
      end

      def format_number(n)
        n = n.to_i if n.is_a?(Rational) && n.denominator == 1
        n = n.to_i if n.is_a?(Float) && n == n.round
        n.is_a?(Rational) ? n.to_f.round(6).to_s : n.to_s
      end
    end
  end
end
