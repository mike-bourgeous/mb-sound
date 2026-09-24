module MB
  module Sound
    module GraphNode
      # Methods that append clipping and quantization to a graph.  Included in
      # GraphNode.
      module DistortionMethods
        # Hard-clips the output of this node to the given min and max, one of
        # which may be nil to disable clipping in that direction.
        def clip(min, max)
          self
            .proc(type_name: 'clip') { |v| v.clip(min, max) }
            .named("clamp #{min}..#{max}")
        end

        # Adds a soft-clipper to the graph.  Values greater than +threshold+ will
        # be smoothly compressed downward, with a value of infinity producing an
        # output of +limit+.
        def softclip(threshold = 0.25, limit = 1.0)
          MB::Sound::Filter::SampleWrapper.new(
            MB::Sound::SoftestClip.new(threshold: threshold, limit: limit),
            self
          )
        end

        # Adds a quantizer to the node graph.  Values will be rounded to the
        # nearest multiple of +increment+.  To quantize to a given number of
        # bits, use e.g. `5.bits`.  An +increment+ of zero means no quantization.
        #
        # The +increment+ may be another GraphNode to apply a time-varying
        # quantization amount.
        def quantize(increment)
          MB::Sound::GraphNode::Quantize.new(upstream: self, increment: increment)
        end
      end
    end
  end
end
