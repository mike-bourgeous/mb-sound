module MB
  module Sound
    # A value that differs per band of a filter bank (or any harmonic series
    # of settings), made by MB::Sound#per_harmonic: the sibling of
    # per_channel (per channel) and per_voice (per synth voice).
    #
    # Two forms:
    # - a Range and a curve: band i of N gets a + (b - a) * curve(i / (N -
    #   1)), the first band +a+ and the last +b+ (one band: +a+).  The curve
    #   is anything MB::Sound::Curve takes (`:linear`, the default, `:exp`,
    #   `:smooth`, `Curve.power(2)`, a Proc, ...).  Endpoints are Intervals
    #   (`15.cents..90.cents`, interpolated in semitones), Pitches
    #   (`100.hz..400.hz`, in Hz, staying Pitches), Decibels (`-12.db..0.db`,
    #   in dB), or plain numbers; both of one kind.
    # - a list of values: band i gets value i, repeating from the start when
    #   there are more bands than values (as per_voice does).
    #
    # A bare Range given to a per-band argument is per_harmonic with the
    # linear curve.  The value prints back as `per_harmonic(...)` (#to_ruby),
    # so graphs that use it save and load.
    class PerHarmonic
      # The values of the list form (nil for a Range).
      attr_reader :values

      # The Range of the range form (nil for a list).
      attr_reader :range

      # The curve as given (a Symbol, Curve, Proc, ...; nil for a list or the
      # default linear curve).
      attr_reader :curve

      # Creates per-band values from a Range (with +curve+) or a list.
      def initialize(*items, curve: nil)
        items = items[0] if items.length == 1 && items[0].is_a?(Array)
        raise ArgumentError, 'per_harmonic needs a Range or at least one value' if items.empty?

        if items.length == 1 && items[0].is_a?(Range)
          @range = items[0]
          @values = nil
          a = @range.begin
          b = @range.end
          raise ArgumentError, "per_harmonic needs a Range with both ends (got #{@range.inspect})" if a.nil? || b.nil?
          raise ArgumentError, "per_harmonic can't spread across #{@range.inspect} (both ends must be Intervals, Pitches, Decibels, or numbers of one kind)" unless self.class.kind_of_value(a) && self.class.kind_of_value(a) == self.class.kind_of_value(b)
          raise ArgumentError, 'per_harmonic Ranges must include their end (use .. not ...)' if @range.exclude_end?

          @curve = curve
          @curve_object = Curve.from(curve.nil? ? :linear : curve)
        else
          raise ArgumentError, 'A curve is for a Range (per_harmonic(15.cents..90.cents, curve: :exp))' unless curve.nil?

          @range = nil
          @values = items.dup.freeze
          @curve = nil
          @curve_object = nil
        end
        freeze
      end

      # The values or the Range's ends (for graph traversal and printing).
      def items
        @values || [@range.begin, @range.end]
      end

      # The value for band +index+ of +count+.
      def value(index, count)
        return @values[index % @values.length] if @values

        t = count <= 1 ? 0.0 : index / (count - 1).to_f
        self.class.interpolate(@range.begin, @range.end, @curve_object.call(t))
      end

      # All +count+ values.
      def to_a(count)
        Array.new(count) { |i| value(i, count) }
      end

      # The Ruby that makes this value: per_harmonic(...), with values
      # printed by the block (e.g. the graph writer's), else inspected.
      def to_ruby(&printer)
        printer ||= ->(v) { MB::Sound::RubyValue.text(v) }
        if @values
          "per_harmonic(#{@values.map(&printer).join(', ')})"
        else
          args = ["#{printer.call(@range.begin)}..#{printer.call(@range.end)}"]
          args << "curve: #{printer.call(@curve)}" unless @curve.nil?
          "per_harmonic(#{args.join(', ')})"
        end
      end

      def to_s
        to_ruby
      end

      def inspect
        "#<#{self.class.name} #{to_ruby}>"
      end

      def ==(other)
        other.is_a?(PerHarmonic) && other.values == @values && other.range == @range && other.curve == @curve
      end
      alias eql? ==

      def hash
        [PerHarmonic, @values, @range, @curve].hash
      end

      # The kind of +v+ for interpolation (:interval, :pitch, :decibels,
      # :number), or nil.
      def self.kind_of_value(v)
        case v
        when Interval then :interval
        when Pitch then v.constant? ? :pitch : nil
        when Decibels then :decibels
        when Numeric then v.real? ? :number : nil
        end
      end

      # +a+ + (+b+ - +a+) * +c+ in the values' own unit (see the class
      # description).
      def self.interpolate(a, b, c)
        case kind_of_value(a)
        when :interval then a + (b - a) * c
        when :pitch then (a.frequency + (b.frequency - a.frequency) * c).hz
        when :decibels then Decibels.new(a.db_value + (b.db_value - a.db_value) * c)
        else a + (b - a) * c
        end
      end
    end
  end
end
