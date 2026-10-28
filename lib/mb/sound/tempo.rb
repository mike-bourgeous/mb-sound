module MB
  module Sound
    # A tempo in quarter notes per minute, as a value: what Numeric#bpm
    # returns (`138.75.bpm`).  It isn't a number (a tempo times two would
    # be ambiguous); methods that take clocks read it as "this tempo"
    # (Clip#clocked, Clock), and it prints back as `138.75.bpm`.
    #
    # The tempo is kept as an exact Rational (#to_r): Floats are read as the
    # simplest fraction within a millionth of a BPM, so 138.75 is 555/4 and
    # 138.7 is 1387/10.
    #
    #     t = 138.75.bpm     # => 138.75.bpm
    #     t.bpm              # => 138.75 (as given)
    #     t.to_r             # => (555/4)
    #     t.whole_notes_per_second # => (37/64)
    class Tempo
      include Comparable

      # The tempo as given (an Integer, Float, or Rational).
      attr_reader :bpm

      # Creates a tempo of +bpm+ quarter notes per minute.  Prefer
      # Numeric#bpm.
      def initialize(bpm)
        unless bpm.is_a?(Numeric) && bpm.real? && bpm.finite? && bpm > 0
          raise ArgumentError, "A tempo is a positive number of beats per minute (got #{bpm.inspect})"
        end
        @bpm = bpm.is_a?(Tempo) ? bpm.bpm : bpm
        @exact = Tempo.exact(@bpm)
        freeze
      end

      # +x+ (a real number) as an exact Rational: Floats as the simplest
      # fraction within a millionth.
      def self.exact(x)
        x.is_a?(Float) ? x.rationalize(Rational(1, 1_000_000)) : x.to_r
      end

      # The tempo as an exact Rational (BPM).
      def to_r
        @exact
      end

      # The tempo as a Float (BPM).
      def to_f
        @exact.to_f
      end

      # Whole notes per second at this tempo (exact).
      def whole_notes_per_second
        @exact / 240
      end

      # The ratio of this tempo to +other+ (a Tempo or a number of BPM), as
      # an exact Rational: `138.75.bpm / 165.bpm` is 111/132.
      def /(other)
        other = other.is_a?(Tempo) ? other.to_r : Tempo.exact(other)
        @exact / other
      end

      def ==(other)
        other.is_a?(Tempo) && other.to_r == @exact
      end

      # Tempos compare by BPM, so they make ranges (`90.bpm..180.bpm`, for
      # knob ranges and checks); other values don't compare (nil).
      def <=>(other)
        other.is_a?(Tempo) ? @exact <=> other.to_r : nil
      end
      alias eql? ==

      def hash
        [Tempo, @exact].hash
      end

      # Ruby code for this tempo: `138.75.bpm`, `(555/4r).bpm`.
      def to_ruby
        b = @bpm
        t = case b
            when Rational then b.denominator == 1 ? b.numerator.to_s : "(#{b.numerator}/#{b.denominator}r)"
            when Float then b == b.round && b.abs < 1e15 ? b.round.to_s : b.to_s
            else b.to_s
            end
        "#{t}.bpm"
      end
      alias to_s to_ruby
      alias inspect to_ruby

      def pretty_print(q)
        q.text(to_ruby)
      end
    end

    module NumericSoundMixins
      # A Tempo of this many quarter notes per minute (`138.75.bpm`), for
      # clocks: `riff.clocked(138.75.bpm)` plays a clip at its own tempo
      # inside a set at another (see Clock).
      def bpm
        Tempo.new(self)
      end
    end
  end
end
