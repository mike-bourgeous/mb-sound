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
        attr_accessor :constant

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

        # Initializes a constant-output signal generator.
        #
        # If +:smoothing+ is true or nil, then when the constant is changed,
        # the output value will change smoothly over the length of one buffer
        # (TODO: use a constant-length FIR filter?  consider using or merging
        # with filter/smoothstep.rb?).
        def initialize(constant, smoothing: nil, sample_rate:)
          raise 'The constant value must be a numeric' unless constant.is_a?(Numeric)
          @constant = constant
          @complex = @constant.is_a?(Complex)
          @old_constant = @constant
          @smoothing = smoothing
          @buf = nil

          @sample_rate = sample_rate.to_f
          @elapsed_samples = 0.0
          @duration_samples = nil
        end

        # Returns +count+ samples of the constant value.
        def sample(count)
          @complex ||= @constant.is_a?(Complex)

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
          if @constant != @old_constant && smoothing
            @buf.inplace!
            @buf = MB::FastSound.smoothstep_buf(@buf)
            @buf * (@constant - @old_constant)
            @buf + @old_constant
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
          @duration_samples = duration_seconds && duration_seconds.to_f * @sample_rate
          self
        end

        # See GraphNode#to_s
        def to_s
          "#{super} -- value=#{@constant}"
        end

        # See GraphNode#to_s_graphviz
        def to_s_graphviz
          <<~EOF
          #{super}---------------
          value: #{@constant}
          EOF
        end
      end
    end
  end
end
