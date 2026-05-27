module MB
  module Sound
    module GraphNode
      # A signal generator (with a #sample method; see GraphNode and Tone)
      # that returns a constant numeric value.
      class Constant
        include GraphNode
        include BufferHelper

        module NumericConstantMethods
          # Converts this numeric value into a MB::Sound::GraphNode::Constant
          # constant-value signal generator.  See the Constant constructor for
          # parameter details.
          def constant(*args, sample_rate: 48000, **kwargs)
            MB::Sound::GraphNode::Constant.new(self, *args, sample_rate: sample_rate, **kwargs)
          end
        end
        Numeric.include(NumericConstantMethods)

        # The steady-state value this graph node will output.
        attr_reader :constant

        # If nil (the default) or truthy, then changes to the constant value
        # will be interpolated over the duration one output sampling frame,
        # instead of changing suddenly at the start of the frame.
        #
        # If nil, then other graph nodes (e.g. MIDI::GraphVoice) may change the
        # value (e.g. defaulting frequency constants to change instantly
        # instead of being interpolated).
        attr_accessor :smoothing

        # The sample rate given to the constructor, used for calculating the
        # constant duration in #for.
        attr_reader :sample_rate

        # An optional allowed range for this constant.  May be used for
        # limiting input ranges or controlling display ranges.
        attr_reader :range

        # An optional unit string for this constant.  Used in to_s and other
        # display settings.
        attr_reader :unit

        # Whether the to_s method will include an SI prefix when showing the
        # value.
        attr_reader :si

        # Initializes a constant-output signal generator.
        #
        # If +:smoothing+ is true or nil, then when the constant is changed,
        # the output value will change smoothly over the interval to the next
        # update (see #timed_change), or until the end of the buffer.
        # (TODO: use a constant-length FIR filter?  consider using or merging
        # with filter/smoothstep.rb?).
        def initialize(constant, smoothing: nil, sample_rate:, unit: nil, range: nil, si: true)
          raise 'The constant value must be a numeric' unless constant.is_a?(Numeric)
          @constant = constant
          @complex = @constant.is_a?(Complex)
          @old_constant = @constant
          @smoothing = smoothing
          @buf = nil
          @unit = unit
          @range = range
          @si = si

          @sample_rate = sample_rate.to_f
          @elapsed_samples = 0.0
          @duration_samples = nil
          @duration_set = false

          @changes = []
        end

        # Sets the constant value at the start of the next sample buffer.
        def constant=(value)
          timed_change(value, 0)
        end

        # Allows queuing changes at specific time offsets within a buffer,
        # regardless of sample rate.  See #indexed_change.
        def timed_change(value, timestamp)
          indexed_change(value, (timestamp * @sample_rate).floor)
        end

        # Allows queuing multiple changes at specific sample indices within a
        # single buffer.  Each call to this method queues a change to the
        # constant value at the given sample index within the buffer.  The
        # #sample method will apply these changes to the next buffer.
        #
        # Raises an error if +index+ is out of range for a single buffer.
        def indexed_change(value, index)
          # FIXME: oversampling???
          @complex = true if value.is_a?(Complex)
          setup_buffer(length: index + 1, complex: @complex) unless @buf # TODO: better option for initial creation?

          raise RangeError, "Index #{index} out of buffer range #{@buf&.length.inspect} for timed constant" if @buf.nil? || index >= @buf.length

          @changes << [index, value]
        end

        # Returns +count+ samples of the constant value.
        def sample(count)
          if @duration_samples
            # Return nil if we have reached the duration set by #for
            return nil if @elapsed_samples >= @duration_samples

            # Return less than requested if we have nearly reached the duration set by #for
            if @elapsed_samples + count >= @duration_samples
              count = (@duration_samples - @elapsed_samples).round
            end
          end

          return nil if count == 0

          @elapsed_samples += count

          setup_buffer(length: count, complex: @complex)

          smoothing = @smoothing || @smoothing.nil?

          if @changes.any?
            # Per-sample updates
            @buf.inplace!

            @changes.sort_by!(&:first)

            first_sample = @changes[0][0]
            if first_sample > 0
              @buf[0...first_sample].fill(@old_constant)
            end

            # Per-sample updates
            @changes.each_with_index do |(sample, value), idx|
              next_sample = @changes[idx + 1]&.first || count

              @constant = value

              # Coalesce multiple updates at the same time
              next if next_sample == sample

              local_buf = @buf[sample...next_sample]

              if smoothing && @constant != @old_constant
                local_buf[] = MB::FastSound.smoothstep_buf(local_buf)
                local_buf.inplace! * (@constant - @old_constant)
                local_buf.inplace! + @old_constant
              else
                local_buf.fill(@constant)
              end

              @old_constant = value
            end

            @changes.clear

          else
            @buf.fill(@constant)
          end

          @old_constant = @constant

          @buf.not_inplace!
        end

        def sources
          { value: @constant }
        end

        # Changes the sample rate of this constant value, used for duration
        # calculation.
        def at_rate(sample_rate)
          new_rate = sample_rate.to_f

          @elapsed_samples = @elapsed_samples * new_rate / @sample_rate
          @duration_samples = @duration_samples * new_rate / @sample_rate if @duration_samples

          @sample_rate = new_rate

          self
        end
        alias sample_rate= at_rate

        # Sets the duration for which this constant will run *from now*, or nil
        # to run forever.
        def for(duration_seconds, recursive: true)
          super(duration_seconds, recursive: recursive)
          @elapsed_samples = 0
          @duration_samples = duration_seconds ? duration_seconds.to_f * @sample_rate : nil
          @duration_set = true
          self
        end

        # Sets the default duration for this constant
        def or_for(duration_seconds, recursive: true)
          # TODO: deduplicate duration management code
          super(duration_seconds, recursive: false)

          unless @duration_set
            @duration_samples = duration_seconds ? duration_seconds.to_f * @sample_rate : nil
          end

          self
        end

        # Returns the duration of the constant in seconds, or nil if there is
        # no duration.
        def duration
          return nil unless @duration_samples
          @duration_samples / @sample_rate
        end

        # Returns the amount of time the constant has been playing since the
        # start of playback, or since #for was last called.
        def elapsed
          @elapsed_samples / @sample_rate
        end

        # Returns the progress as a percentage through playback (from 0 to 100)
        # if there is a duration set, or nil if there is no duration.
        #
        # TODO: abstract progress reporting as a mixin for Tone, inputs, etc.?
        def progress
          return nil unless @duration_samples
          @elapsed_samples * 100.0 / @duration_samples
        end

        # See GraphNode#to_s
        def to_s
          "#{super} -- value=#{value_string}"
        end

        # See GraphNode#to_s_graphviz
        def to_s_graphviz
          <<~EOF
          #{super}---------------
          value: #{value_string}
          EOF
        end

        # Returns a String display of the constant value, with unit and SI
        # prefixes if specified.
        def value_string
          if @constant.is_a?(Complex)
            s = @constant.to_s
          elsif @si
            s = MB::M.sigformat(@constant, 5)
          else
            s = @constant.to_nice_s(4)
          end

          "#{s}#{unit}"
        end

        # Same as #value_string for compatibility with other arithmetic nodes.
        #
        # Named nodes will show up as their names, so you can name this node to
        # show that instead of the value.
        def arithmetic_string(_separator = ' ')
          value_string
        end
      end
    end
  end
end
