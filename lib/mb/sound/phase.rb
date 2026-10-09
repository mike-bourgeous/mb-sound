module MB
  module Sound
    # An oscillator phase (or phase modulation depth).  Phases are in cycles
    # throughout mb-sound: a plain number or graph node given as a phase
    # (Tone#with_phase, Tone#reset's +to:+, Tone#pm and its index,
    # Tone#fm_feedback, Pitch#unison's +phase:+, GraphNode#ping's +phase:+,
    # HarmonicTable and Wavetable.from_harmonics phases) counts cycles: 0.25
    # is a quarter cycle (90 degrees, pi / 2 radians), so live code never
    # needs Math::PI.
    #
    # A Phase object says its unit explicitly: `0.25.cycles` (aliases
    # `cycle`, `cyc`), `1.5.radians` (alias `radian`, `rad`; or
    # Phase.radians(1.5)), Phase.degrees(90), or `node.cycles` /
    # `node.radians` for a graph node whose output is in that unit (e.g. an
    # old radians modulator: `mod.radians`).  Methods that take phases
    # convert Phases with Phase.cycles.  A radians Phase keeps its radians,
    # so #to_radians gives them back exactly (kernels that work in radians
    # get the same value as before the cycles migration of 2026-10-10).
    #
    # Numeric phases are values like Intervals: they compare, add, subtract,
    # scale by numbers, and convert with #to_cycles, #to_radians, and
    # #to_degrees.
    #
    # Examples:
    #     440.hz.with_phase(0.25)                       # starts at the top
    #     440.hz.with_phase(0.25.cycles)                # the same, explicitly
    #     110.hz.pm(330.hz, 0.4)                        # PM depth 0.4 cycles
    #     110.hz.pm(330.hz, 2.5.radians)                # PM index 2.5 radians
    #     110.hz.pm(0.3.hz.lfo.at(0..0.5))              # a node in cycles
    #     55.hz.saw.reset(c.trigger, to: 0.5)
    class Phase
      include Comparable

      TWOPI = 2.0 * Math::PI

      # The phase in cycles (a Numeric, or a graph node of cycles).
      attr_reader :cycles

      # Converts +value+ to cycles, the unit of every phase input: a Phase
      # converts, and plain numbers and graph nodes (cycles already) pass
      # through, as does nil.
      def self.cycles(value)
        return value.to_cycles if value.is_a?(Phase)

        value
      end

      # Converts +value+ to radians for code that works in radians: a Phase
      # converts (a radians Phase exactly), plain numbers (cycles) are
      # multiplied by 2 pi, graph nodes (cycles) become a node times 2 pi,
      # and nil stays nil.
      def self.to_radians(value)
        return value.to_radians if value.is_a?(Phase)
        return nil if value.nil?
        return value * TWOPI if value.is_a?(Numeric)

        new(value).to_radians
      end

      # A Phase of +radians+ (a number, or a graph node of radians): e.g.
      # an FM index from the literature, `pm(mod, Phase.radians(2.4))`, the
      # same as `2.4.radians`.
      def self.radians(radians)
        new(radians, unit: :radians)
      end

      # A Phase of +degrees+ (a number): Phase.degrees(90) is 0.25 cycles.
      # (Numeric#degrees is mb-math's conversion to plain radians for
      # trigonometry, which phase methods would read as cycles.)
      def self.degrees(degrees)
        raise ArgumentError, "Degrees must be a number (got #{degrees.inspect})" unless degrees.is_a?(Numeric)

        new(degrees / 360.0)
      end

      # A phase of +value+ in +unit+ (:cycles or :radians; a number, or a
      # graph node whose output is in that unit).
      def initialize(value, unit: :cycles)
        unless value.is_a?(Numeric) || value.respond_to?(:sample)
          raise ArgumentError, "A phase needs a number or a graph node (got #{value.inspect})"
        end

        case unit
        when :cycles
          @cycles = value
          @radians = nil
        when :radians
          @radians = value
          @cycles = value.is_a?(Numeric) ? value / TWOPI : value * (1.0 / TWOPI)
        else
          raise ArgumentError, "Unknown phase unit #{unit.inspect} (use :cycles or :radians)"
        end
      end

      # True if this phase is a graph node (see GraphNode#cycles).
      def node?
        !@cycles.is_a?(Numeric)
      end

      # True if this phase was given in radians (e.g. 1.5.radians).
      def radians?
        !@radians.nil?
      end

      def to_cycles
        @cycles
      end

      # The phase in radians: a Float (exactly the radians given, for a
      # radians Phase), or for a node phase, a node (the radians node given,
      # or the cycles node times 2 pi, made once).
      def to_radians
        return @radians if @radians
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
        return "#{@radians} (radians)" if node? && @radians
        return "#{@cycles} (cycles)" if node?
        return "#{MB::M.sigfigs(@radians.to_f, 6)} radians" if @radians

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
