module MB
  module Sound
    # A value that differs per band of a filter bank (or any harmonic series
    # of settings), made by MB::Sound#per_harmonic: the sibling of
    # per_channel (per channel) and per_voice (per synth voice).
    #
    # Three forms:
    # - a Range and a curve: band i of N gets a + (b - a) * curve(i / (N -
    #   1)), the first band +a+ and the last +b+ (one band: +a+).  An
    #   exclusive Range (`0...1`) spaces the bands evenly without reaching
    #   +b+: band i gets a + (b - a) * curve(i / N) (phases around a cycle).
    #   The curve is anything MB::Sound::Curve takes (`:linear`, the
    #   default, `:exp`, `:smooth`, `Curve.power(2)`, a Proc, ...).
    #   Endpoints are Intervals (`15.cents..90.cents`, interpolated in
    #   semitones), Pitches (`100.hz..400.hz`, in Hz, staying Pitches),
    #   Decibels (`-12.db..0.db`, in dB), or plain numbers; both of one kind.
    # - a list of values: band i gets value i, repeating from the start when
    #   there are more bands than values (as per_voice does).
    # - a tone and spreads (+phase:+, +rate:+): every band gets its own copy
    #   of the tone (an LFO such as `0.2.hz.lfo`, `0.1.hz.triangle.lfo`,
    #   `4.bars.lfo`, or a Pitch, which plays as a sine), with +phase+
    #   cycles added to its starting phase and its frequency times +rate+,
    #   each one value for every band or per band (a Range, a list, or a
    #   per_harmonic value), so each band moves on its own LFO:
    #   `pan: per_harmonic(0.2.hz.lfo, phase: 0...1)`.  Copies share the
    #   tone's inputs (through new branches) and take seeds derived from its
    #   own (seed + 1 + band), so one seed rebuilds them; the tone itself is
    #   a pattern and isn't played.
    #
    # A bare Range given to a per-band argument is per_harmonic with the
    # linear curve.  The value prints back as `per_harmonic(...)` (#to_ruby),
    # so graphs that use it save and load.
    class PerHarmonic
      # The values of the list form (nil for a Range or a tone).
      attr_reader :values

      # The Range of the range form (nil for a list or a tone).
      attr_reader :range

      # The curve as given (a Symbol, Curve, Proc, ...; nil for a list, a
      # tone, or the default linear curve).
      attr_reader :curve

      # The tone of the tone form (a Tone or Pitch; nil for the others).
      attr_reader :tone

      # The tone form's phase spread in cycles (nil for none; see the class
      # description).
      attr_reader :phase

      # The tone form's rate spread, a factor of the tone's frequency (nil
      # for none).
      attr_reader :rate

      # Creates per-band values from a Range (with +curve+), a list, or a
      # tone with +phase+ and +rate+ spreads.
      def initialize(*items, curve: nil, phase: nil, rate: nil)
        items = items[0] if items.length == 1 && items[0].is_a?(Array)
        raise ArgumentError, 'per_harmonic needs a Range or at least one value' if items.empty?

        @values = nil
        @range = nil
        @curve = nil
        @curve_object = nil
        @tone = nil
        @phase = nil
        @rate = nil

        if !phase.nil? || !rate.nil?
          t = items[0]
          unless items.length == 1 && (t.is_a?(Tone) || (t.is_a?(Pitch) && !t.is_a?(Tone)))
            raise ArgumentError, "phase: and rate: spread one tone across the bands (per_harmonic(0.2.hz.lfo, phase: 0...1); got #{items.map { |v| v.respond_to?(:sample) ? v.class.name : v.inspect }.join(', ')}); " \
              'for other per-band nodes give a list (per_harmonic(a, b, c))'
          end
          raise ArgumentError, 'A curve is for a Range (per_harmonic(15.cents..90.cents, curve: :exp)); give phase: or rate: a per_harmonic(..., curve:)' unless curve.nil?

          @tone = t
          @phase = self.class.check_spread(phase, 'phase')
          @rate = self.class.check_spread(rate, 'rate')
        elsif items.length == 1 && items[0].is_a?(Range)
          @range = items[0]
          a = @range.begin
          b = @range.end
          raise ArgumentError, "per_harmonic needs a Range with both ends (got #{@range.inspect})" if a.nil? || b.nil?
          raise ArgumentError, "per_harmonic can't spread across #{@range.inspect} (both ends must be Intervals, Pitches, Decibels, or numbers of one kind)" unless self.class.kind_of_value(a) && self.class.kind_of_value(a) == self.class.kind_of_value(b)

          @curve = curve
          @curve_object = Curve.from(curve.nil? ? :linear : curve)
        else
          raise ArgumentError, 'A curve is for a Range (per_harmonic(15.cents..90.cents, curve: :exp))' unless curve.nil?

          @values = items.dup.freeze
        end
        freeze
      end

      # The values, the Range's ends, or the tone and its spreads (for graph
      # traversal and printing).
      def items
        return [@tone, @phase, @rate].compact if @tone

        @values || [@range.begin, @range.end]
      end

      # The value for band +index+ of +count+ (for the tone form, a new copy
      # of the tone on every call).
      def value(index, count)
        return @values[index % @values.length] if @values
        return tone_copy(index, count) if @tone

        if @range.exclude_end?
          t = count <= 1 ? 0.0 : index / count.to_f
        else
          t = count <= 1 ? 0.0 : index / (count - 1).to_f
        end
        self.class.interpolate(@range.begin, @range.end, @curve_object.call(t))
      end

      # All +count+ values.
      def to_a(count)
        Array.new(count) { |i| value(i, count) }
      end

      # The Ruby that makes this value: per_harmonic(...), with values
      # printed by the block (e.g. the graph writer's), else as values
      # (MB::Sound::RubyValue) and nodes as their own Ruby.
      def to_ruby(&printer)
        printer ||= ->(v) { v.is_a?(GraphNode) && !v.is_a?(Pitch) ? v.to_ruby : MB::Sound::RubyValue.text(v) }
        if @values
          "per_harmonic(#{@values.map(&printer).join(', ')})"
        elsif @tone
          args = [printer.call(@tone)]
          args << "phase: #{spread_text(@phase, printer)}" unless @phase.nil?
          args << "rate: #{spread_text(@rate, printer)}" unless @rate.nil?
          "per_harmonic(#{args.join(', ')})"
        else
          args = [range_text(@range, printer)]
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
        other.is_a?(PerHarmonic) && other.values == @values && other.range == @range && other.curve == @curve &&
          other.tone.equal?(@tone) && other.phase == @phase && other.rate == @rate
      end
      alias eql? ==

      def hash
        [PerHarmonic, @values, @range, @curve, @tone&.object_id, @phase, @rate].hash
      end

      # A tone form spread (+phase:+ or +rate:+) as given, checked: nil, a
      # number (every band), a Range (per_harmonic with the linear curve),
      # an Array (one per band, repeating), or a per_harmonic Range or list.
      def self.check_spread(value, name)
        case value
        when nil then nil
        when Range
          PerHarmonic.new(value) # (checks it)
          raise ArgumentError, "#{name}: takes numbers (got #{value.inspect})" unless kind_of_value(value.begin) == :number
          value
        when Array
          raise ArgumentError, "#{name}: needs at least one value" if value.empty?
          value.each { |v| check_spread(v, name) }
          value.frozen? ? value : value.dup.freeze
        when PerHarmonic
          raise ArgumentError, "#{name}: takes a per_harmonic Range or list of numbers, not a tone" if value.tone
          value.items.each { |v| check_spread(v, name) }
          value
        else
          v = name == 'phase' ? Phase.cycles(value) : value
          raise ArgumentError, "#{name}: takes numbers#{' (cycles) or Phases' if name == 'phase'}, Ranges, lists, or per_harmonic values (got #{value.inspect})" unless v.is_a?(Numeric) && v.real?

          value
        end
      end

      private

      # Band +index+'s copy of the tone (see the class description).
      def tone_copy(index, count)
        phase = @phase.nil? ? nil : Phase.cycles(spread_value(@phase, index, count)).to_f
        rate = @rate.nil? ? nil : spread_value(@rate, index, count).to_f
        if @tone.is_a?(Tone)
          @tone.per_band_copy(index, phase: phase, rate: rate)
        else
          @tone.tone.per_band_copy(index, phase: phase, rate: rate, copy: false)
        end
      end

      # The value of spread +v+ for band +index+ of +count+.
      def spread_value(v, index, count)
        case v
        when PerHarmonic then v.value(index, count)
        when Range then PerHarmonic.new(v).value(index, count)
        when Array then v[index % v.length]
        else v
        end
      end

      def spread_text(v, printer)
        case v
        when Range then range_text(v, printer)
        when Array then "[#{v.map(&printer).join(', ')}]"
        else printer.call(v)
        end
      end

      def range_text(r, printer)
        "#{printer.call(r.begin)}#{r.exclude_end? ? '...' : '..'}#{printer.call(r.end)}"
      end

      public

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
