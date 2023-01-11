module MB
  module Sound
    module GraphNode
      # A signal generator (with a #sample method; see GraphNode and Tone)
      # that returns a constant numeric value.
      class Constant
        include GraphNode

        module NumericConstantMethods
          # Converts this numeric value into a MB::Sound::GraphNode::Constant
          # constant-value signal generator.  See the Constant constructor for
          # parameter details.
          def constant(*args, **kwargs)
            MB::Sound::GraphNode::Constant.new(self, *args, **kwargs)
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

        # Initializes a constant-output signal generator.
        #
        # If +:smoothing+ is true or nil, then when the constant is changed,
        # the output value will change smoothly over the length of one buffer
        # (TODO: use a constant-length FIR filter?  consider using or merging
        # with filter/smoothstep.rb?).
        def initialize(constant, smoothing: nil)
          raise 'The constant value must be a numeric' unless constant.is_a?(Numeric)
          @constant = constant
          @old_constant = constant
          @smoothing = smoothing
          @buf = nil
        end

        # Returns +count+ samples of the constant value.
        def sample(count)
          setup_buffer(count)

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
          [@constant]
        end

        private

        def setup_buffer(length)
          @complex = @constant.is_a?(Complex)
          @bufclass = @complex ? Numo::SComplex : Numo::SFloat

          if @buf.nil? || @buf.length != length || @bufclass != @buf.class
            @buf = @bufclass.zeros(length)
          end
        end
      end
    end
  end
end
