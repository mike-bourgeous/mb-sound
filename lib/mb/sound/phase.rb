module MB
  module Sound
    # An oscillator phase (or phase modulation depth) in cycles: `0.25.cycles`
    # (alias `.cyc`; a quarter cycle = 90 degrees = pi / 2 radians), or
    # `node.cycles` for a graph node whose output is in cycles (e.g. a
    # phasor, or an LFO giving a phase modulation depth).
    #
    # Methods that take a phase in radians (Tone#with_phase, Tone#reset's
    # +to:+, Tone#pm and its index, Tone#fm_feedback, Pitch#unison's
    # +phase:+, GraphNode#ping's +phase:+) also accept a Phase, converted
    # with Phase.radians, so live code doesn't need Math::PI.  Plain numbers
    # and plain nodes stay radians in those methods (cycles throughout is
    # the planned larger migration; see the _cycles variants such as
    # Tone#with_phase_cycles, #pm_cycles, and #fm_feedback_cycles).
    #
    # Numeric phases are values like Intervals: they compare, add, subtract,
    # scale by numbers, and convert with #to_cycles, #to_radians, and
    # #to_degrees.
    #
    # Examples:
    #     440.hz.with_phase(0.25.cycles)                # starts at the top
    #     110.hz.pm(330.hz, 0.4.cycles)                 # PM depth 0.4 cycles
    #     110.hz.pm(0.3.hz.lfo.at(0..0.5).cycles)       # a node in cycles
    #     55.hz.saw.reset(c.trigger, to: 0.5.cycles)
    class Phase
      include Comparable

      TWOPI = 2.0 * Math::PI

      # The phase in cycles (a Numeric, or a graph node of cycles).
      attr_reader :cycles

      # Converts +value+ to radians: a Phase (or anything with #to_radians)
      # converts, plain numbers and graph nodes (radians already) pass
      # through, and nil stays nil.
      def self.radians(value)
        return value.to_radians if value.respond_to?(:to_radians)

        value
      end

      # Converts +value+ to cycles: a Phase converts, and plain numbers and
      # graph nodes (cycles already, where a method counts in cycles) pass
      # through.
      def self.cycles(value)
        return value.to_cycles if value.respond_to?(:to_cycles)

        value
      end

      # A phase of +cycles+ (a number, or a graph node whose output is in
      # cycles).
      def initialize(cycles)
        unless cycles.is_a?(Numeric) || cycles.respond_to?(:sample)
          raise ArgumentError, "A phase needs a number or a graph node of cycles (got #{cycles.inspect})"
        end

        @cycles = cycles
      end

      # True if this phase is a graph node (see GraphNode#cycles).
      def node?
        !@cycles.is_a?(Numeric)
      end

      def to_cycles
        @cycles
      end

      # The phase in radians: a Float, or for a node phase, a node
      # multiplying it by 2 pi (made once).
      def to_radians
        return @cycles * TWOPI unless node?

        @radians_node ||= @cycles * TWOPI
      end

      def to_degrees
        raise ArgumentError, 'A node phase has no fixed degrees' if node?

        @cycles * 360
      end

      def +(other)
        Phase.new(numeric! + Phase.numeric_cycles(other))
      end

      def -(other)
        Phase.new(numeric! - Phase.numeric_cycles(other))
      end

      def -@
        Phase.new(-numeric!)
      end

      def *(other)
        raise ArgumentError, 'Phases can only be multiplied by numbers' unless other.is_a?(Numeric)

        Phase.new(numeric! * other)
      end

      def /(other)
        raise ArgumentError, 'Phases can only be divided by numbers' unless other.is_a?(Numeric)

        Phase.new(numeric! / other)
      end

      def coerce(other)
        raise TypeError, "#{other.class} can't be coerced into a phase" unless other.is_a?(Numeric)

        [Scalar.new(other), self]
      end

      # A number on the left of a Phase in arithmetic (see #coerce).
      class Scalar
        def initialize(value)
          @value = value
        end

        def *(phase)
          phase * @value
        end
      end

      def <=>(other)
        return nil unless other.is_a?(Phase) && !node? && !other.node?

        @cycles <=> other.cycles
      end

      def hash
        [Phase, @cycles].hash
      end

      def eql?(other)
        other.is_a?(Phase) && @cycles.eql?(other.cycles)
      end

      def zero?
        !node? && @cycles.zero?
      end

      def to_s
        return "#{@cycles} (cycles)" if node?

        "#{MB::M.sigfigs(@cycles.to_f, 6)} cycles"
      end

      def inspect
        "#<MB::Sound::Phase #{self}>"
      end

      # The cycles of +other+ (a numeric Phase) for arithmetic.
      def self.numeric_cycles(other)
        raise ArgumentError, "Expected a phase (e.g. 0.25.cycles), got #{other.inspect}" unless other.is_a?(Phase) && !other.node?

        other.cycles
      end

      private

      def numeric!
        raise ArgumentError, 'Arithmetic on node phases happens on the node (e.g. (lfo * 2).cycles)' if node?

        @cycles
      end
    end
  end
end
