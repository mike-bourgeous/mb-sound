module MB
  module Sound
    # A linear gain that remembers the decibel value it came from: what
    # Numeric#db returns (`-6.db`).  It acts like the Float gain everywhere
    # (arithmetic, comparisons, Numo, C extensions through #to_f), so
    # `sig * -20.db`, `at(-6.db)`, and `master_gain -6.db` work as they
    # always have, and arithmetic results are plain Floats (`-6.db * 2` is a
    # gain of 1.0, no longer a dB value).
    #
    # What the tag adds: methods that take levels in dB (dynamics thresholds,
    # ceilings, makeup, compander points) read a Decibels value as its exact
    # dB number, so `compress(threshold: -20.db)` and `makeup: 6.db` are
    # unambiguous (bare numbers there are linear gains, like gains
    # everywhere else), and graph export prints it back as `-20.db`.
    #
    #     g = -6.db        # => -6.db
    #     g.to_f           # => 0.5011872336272722
    #     g.decibels       # => -6
    #     g * 2            # => 1.0023744672545444 (a Float)
    class Decibels < Numeric
      # The decibel value as given (an Integer, Float, or Rational).
      attr_reader :decibels

      # Creates a gain of +decibels+ dB.  Prefer Numeric#db.
      def initialize(decibels)
        raise ArgumentError, "Decibels need a real number (got #{decibels.inspect})" unless decibels.is_a?(Numeric) && decibels.real?

        @decibels = decibels.is_a?(Decibels) ? decibels.decibels : decibels
        # The same expression Numeric#db always used, so gains are unchanged
        @linear = 10.0 ** (@decibels / 20.0)
        freeze
      end

      # The linear gain.
      def to_f
        @linear
      end

      # The dB value as a Float (exact, unlike #to_db, which measures the
      # linear gain).
      def db_value
        @decibels.to_f
      end

      # Ruby's numeric coercion: `2 * -6.db` multiplies 2 by the gain, as
      # with a Float (other kinds of numbers, e.g. Complex, keep their own
      # rules against the Float gain).
      def coerce(other)
        [other, @linear]
      end

      # Equal to Floats (and other numbers) of the same gain.
      def ==(other)
        other.is_a?(Decibels) ? @linear == other.to_f : @linear == other
      end
      alias === ==

      # Hash equality: only Decibels of the same dB value.
      def eql?(other)
        other.is_a?(Decibels) && @decibels.eql?(other.decibels)
      end

      def hash
        [Decibels, @decibels].hash
      end

      # Prints as Ruby that makes this value: `-6.db`.
      def inspect
        d = @decibels
        s = d.is_a?(Rational) ? "(#{d.numerator}r/#{d.denominator})" : d.to_s
        "#{s}.db"
      end

      # The gain as text, like the Float it stands for (so interpolated
      # descriptions don't change).
      def to_s
        @linear.to_s
      end

      # Everything else a Float does, done by the gain (results are plain
      # Floats, Integers, or Rationals).
      (Float.public_instance_methods(false) - [:coerce, :==, :===, :eql?, :hash, :inspect, :to_s, :to_f]).each do |name|
        define_method(name) do |*args, &block|
          @linear.public_send(name, *args, &block)
        end
      end

      def real?
        true
      end

      def integer?
        false
      end

      # Numo's binary operators (`buf * -6.db`) find the result type in each
      # array class's frozen UPCAST table by the other operand's class, and
      # fail on classes they don't know.  This gives Decibels the entries of
      # Float (then Numo casts it through #to_f).  Numo::NArray[-6.db]
      # (untyped) and Numo::NMath on a bare Decibels still see an object:
      # use Numo::SFloat[...] or #to_f there.
      def self.register_with_numo
        ObjectSpace.each_object(Class).select { |c| c <= Numo::NArray && c.const_defined?(:UPCAST, false) }.each do |c|
          table = c::UPCAST
          next unless table.key?(Float) && !table.key?(self)

          table = table.merge(self => table[Float]).freeze
          c.send(:remove_const, :UPCAST)
          c.const_set(:UPCAST, table)
        end
      end
      register_with_numo
    end
  end
end
