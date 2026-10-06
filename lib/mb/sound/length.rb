module MB
  module Sound
    # Lengths of time with units: Length::Seconds (`4.seconds`, `250.ms`),
    # Length::Samples (`5.samples`, counted at the sample rate where they're
    # used, so they follow oversampling), and Sequence::Duration (`3.n16`,
    # `2.bars`, following the tempo).  Every method that takes a length of
    # time accepts any of them, plus plain numbers in that method's usual
    # unit (seconds for delays and envelopes, bars for fades and schedules).
    #
    # Seconds and Samples may also wrap a graph node (`lfo.samples`,
    # `lfo.seconds`) where a length can change every sample (delays); plain
    # nodes are seconds.
    #
    # This module is the protocol shared by the length classes (including
    # Duration): #to_seconds, #to_samples, #to_whole_notes, and #fixed?.
    # Lengths convert at the sample rate and tempo where they're used; a
    # Duration used where a fixed time is needed (e.g. an envelope time) is
    # converted at the current tempo.
    module Length
      # Methods shared by Seconds and Samples.
      module Quantity
        include Comparable

        # The number of seconds or samples (a Numeric), or a graph node.
        attr_reader :value

        def initialize(value)
          unless value.is_a?(Numeric) || value.respond_to?(:sample)
            raise ArgumentError, "A #{self.class.name.split('::').last} length needs a number or a graph node (got #{value.inspect})"
          end
          @value = value
        end

        # True if this is a number rather than a graph node.
        def fixed?
          @value.is_a?(Numeric)
        end

        # The graph node for a node-valued length (nil for numbers).
        def node
          fixed? ? nil : @value
        end

        def +(other)
          self.class.new(numeric_value + same_unit(other))
        end

        def -(other)
          self.class.new(numeric_value - same_unit(other))
        end

        def -@
          self.class.new(-numeric_value)
        end

        # Scales by a number, or divides by a length of the same unit (giving
        # their ratio).
        def *(other)
          raise ArgumentError, "#{self.class.name.split('::').last} lengths can only be multiplied by numbers" unless other.is_a?(Numeric)
          self.class.new(numeric_value * other)
        end

        def /(other)
          other.is_a?(self.class) ? numeric_value.to_f / other.numeric_value : self.class.new(numeric_value / other.to_f)
        end

        # Allows e.g. `2 * 3.samples`.
        def coerce(other)
          raise TypeError, "#{other.class} can't be coerced into a length" unless other.is_a?(Numeric)
          [Scalar.new(other), self]
        end

        def <=>(other)
          other.is_a?(self.class) && fixed? && other.fixed? ? numeric_value <=> other.numeric_value : nil
        end

        def hash
          [self.class, @value].hash
        end

        def eql?(other)
          other.is_a?(self.class) && other.value.eql?(@value)
        end

        def to_f
          numeric_value.to_f
        end

        def to_r
          numeric_value.to_r
        end

        def zero?
          fixed? && @value == 0
        end

        def abs
          self.class.new(numeric_value.abs)
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end

        protected

        def numeric_value
          raise ArgumentError, "#{self} is a graph node, not a fixed length" unless fixed?
          @value
        end

        private

        def same_unit(other)
          unless other.is_a?(self.class)
            raise ArgumentError, "Can only add or subtract #{self.class.name.split('::').last} to #{self.class.name.split('::').last} (got #{other.inspect}; convert with a sample rate or tempo first)"
          end
          other.numeric_value
        end
      end

      # Lets a number come first when scaling a length (`2 * 3.samples`).
      class Scalar
        def initialize(value)
          @value = value
        end

        def *(length)
          length * @value
        end
      end

      # A length in seconds.  Created with Numeric#seconds (also #second,
      # #ms, #milliseconds) or GraphNode#seconds.
      class Seconds
        include Length
        include Quantity

        def to_seconds(sample_rate: 48000, transport: nil)
          numeric_value.to_f
        end

        def to_whole_notes(sample_rate: 48000, transport: Sequence.transport)
          Sequence::Duration.rational(numeric_value * transport.whole_notes_per_second)
        end

        def to_s
          fixed? ? "#{MB::M.sigfigs(@value.to_f, 6)} s" : "#{@value} (seconds)"
        end
      end

      # A length in samples at the sample rate where it's used (e.g. inside
      # #oversample, 5.samples is 5 samples at the oversampled rate).
      # Created with Numeric#samples or GraphNode#samples.
      class Samples
        include Length
        include Quantity

        def to_seconds(sample_rate: 48000, transport: nil)
          numeric_value.to_f / sample_rate
        end

        def to_samples(sample_rate: 48000, transport: nil)
          numeric_value.to_f
        end

        def to_whole_notes(sample_rate: 48000, transport: Sequence.transport)
          Sequence::Duration.rational(to_seconds(sample_rate: sample_rate) * transport.whole_notes_per_second)
        end

        # Rounds to whole samples.
        def round
          Samples.new(numeric_value.round)
        end

        def to_s
          if fixed?
            "#{MB::M.sigfigs(@value.to_f, 6)} #{@value == 1 ? 'sample' : 'samples'}"
          else
            "#{@value} (samples)"
          end
        end
      end

      # The length in samples at +sample_rate+ (default protocol method).
      def to_samples(sample_rate: 48000, transport: Sequence.transport)
        to_seconds(sample_rate: sample_rate, transport: transport) * sample_rate
      end

      # True for numbers (Duration and fixed Seconds/Samples).
      def fixed?
        true
      end

      # Returns +value+ in seconds: plain numbers are already seconds; lengths
      # convert at +sample_rate+ and +transport+'s tempo.  Raises an error for
      # graph nodes.
      def self.seconds(value, sample_rate: 48000, transport: Sequence.transport)
        case value
        when Length then value.to_seconds(sample_rate: sample_rate, transport: transport)
        when Numeric then value
        else raise ArgumentError, "Expected a length of time (seconds, a Length, or a Duration; got #{value.inspect})"
        end
      end

      # Returns +value+ as a number of samples at +sample_rate+: plain numbers
      # are seconds.
      def self.samples(value, sample_rate: 48000, transport: Sequence.transport)
        case value
        when Length then value.to_samples(sample_rate: sample_rate, transport: transport)
        when Numeric then value * sample_rate
        else raise ArgumentError, "Expected a length of time (seconds, a Length, or a Duration; got #{value.inspect})"
        end
      end

      # A length of time that may change every sample, as a delay time or
      # a time limit uses it: a number (seconds), a Seconds or Samples length
      # (fixed or wrapping a node), a Duration (following the tempo through a
      # Sequence::TempoNode), or a graph node (seconds; musical-time nodes
      # like `2.bars.lfo.at(3.n16..5.n16)` follow the tempo).  It keeps the
      # unit it was given and converts to samples when read (#samples), at
      # the sample rate of that moment, so sample rate changes need no
      # rebuilding and add no graph branches.
      class Source
        # The time as given.
        attr_reader :length

        # :seconds or :samples.
        attr_reader :unit

        # The graph node (a sampler branch) for a changing length, or nil.
        attr_reader :node

        # The Sequence::TempoNode for a Duration, or nil.
        attr_reader :tempo_node

        def initialize(length)
          @length = length
          @unit = :seconds
          @value = nil
          @node = nil
          @tempo_node = nil
          @max_seconds = nil

          case length
          when Sequence::Duration
            @tempo_node = Sequence::TempoNode.new(length, mode: :seconds)
            @node = @tempo_node
            @max_seconds = Sequence::TempoNode.max_seconds(length)

          when Samples, Seconds
            @unit = length.is_a?(Samples) ? :samples : :seconds
            if length.fixed?
              @value = length.value
            else
              @node = node_seconds(length.node)
            end

          when Numeric
            @value = length

          else
            raise ArgumentError, "Expected a length of time: seconds, a Length (e.g. 5.samples), a Duration (e.g. 3.n16), or a graph node (got #{length.inspect})" unless length.respond_to?(:sample)
            @node = node_seconds(length)
          end

          @node = @node.get_sampler if @node
        end

        # True if the length comes from a graph node (changes per sample).
        def node?
          !@node.nil?
        end

        # The fixed length in samples at +sample_rate+ (snapped to whole
        # samples within a billionth; see Length.snap).
        def constant_samples(sample_rate)
          raise ArgumentError, "#{self} changes every sample" if node?
          Length.snap(@unit == :seconds ? @value * sample_rate : @value.to_f)
        end

        # Returns +count+ samples of the length in samples at +sample_rate+: a
        # Numeric for fixed lengths, an NArray for nodes, or nil if the node
        # ended.
        def samples(count, sample_rate)
          return constant_samples(sample_rate) unless node?

          buf = @node.sample(count)
          return nil if buf.nil?
          @unit == :seconds ? scaled(buf, sample_rate) : buf
        end

        # +buf+ (seconds) times +sample_rate+, as Numo's buf * sample_rate:
        # when the same frozen buffer comes back (a steady node), one frozen
        # result (so consumers can cache it by identity); otherwise a reused
        # buffer (FastArithmetic.product, which multiplies the same way), so
        # nothing is allocated per buffer.
        private def scaled(buf, sample_rate)
          if buf.frozen? && buf.equal?(@scaled_from) && sample_rate == @scaled_rate
            return @scaled ||= (buf * sample_rate).freeze
          end
          @scaled_from = buf.frozen? ? buf : nil
          @scaled_rate = sample_rate
          @scaled = nil

          out = @scaled_buf
          out = @scaled_buf = buf.class.new(buf.length) if out.nil? || out.class != buf.class || out.length != buf.length
          pair = (@scaled_pair ||= [[nil, nil]])
          pair[0][0] = buf
          return out if MB::Sound::FastArithmetic.product(out, sample_rate, pair)

          buf * sample_rate
        end

        # The longest this length can be, in samples at +sample_rate+, if
        # known (fixed lengths, and Durations at the slowest tempo), or nil.
        def max_samples(sample_rate)
          return constant_samples(sample_rate) unless node?
          @max_seconds && @max_seconds * sample_rate
        end

        def to_s
          @length.respond_to?(:graph_node_name) ? "#{@length} (#{@unit})" : @length.to_s
        end

        private

        # A node giving seconds or samples; musical-time nodes (Durations as
        # ranges, see Tone#musical_time?) are scaled by the tempo.
        def node_seconds(node)
          @max_seconds = Sequence::TempoNode.max_seconds(node)
          @tempo_node = nil
          Sequence::TempoNode.seconds_source(node)
        end
      end

      # Snaps +samples+ to the nearest whole sample if it is within a
      # billionth of it (e.g. 0.1 * 48000), so computed whole-sample lengths
      # stay whole.
      def self.snap(samples)
        rounded = samples.round
        (samples - rounded).abs < 1e-9 ? rounded.to_f : samples.to_f
      end
    end
  end
end
