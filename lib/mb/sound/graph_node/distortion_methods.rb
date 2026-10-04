module MB
  module Sound
    module GraphNode
      # Methods that append clipping and quantization to a graph.  Included in
      # GraphNode.
      #
      # The shapers here are antialiased (antiderivative antialiasing; see
      # MB::Sound::Shaper), with half a sample of delay; the a* versions
      # (#aclip, #asoftclip, #aquantize) are the plain shapers, which alias
      # but are exact, for control signals (delay times, envelopes) and
      # deliberate grit.
      module DistortionMethods
        # Hard-clips the output of this node to the given min and max, one of
        # which may be nil to disable clipping in that direction.
        # Antialiased; see #aclip for exact clipping of control signals.
        def clip(min, max)
          Shaper.new(self, mode: :clip, p1: min, p2: max).named("clip #{min}..#{max}")
        end

        # Hard-clips like #clip without antialiasing: exact (no added delay),
        # for control signals like delay times and envelopes.
        def aclip(min, max)
          Shaper.new(self, mode: :clip, p1: min, p2: max, antialias: false).named("aclip #{min}..#{max}")
        end

        # Adds a soft-clipper to the graph.  Values greater than +threshold+ will
        # be smoothly compressed downward, with a value of infinity producing an
        # output of +limit+.  Linear below the threshold (see
        # MB::Sound::SoftestClip), antialiased (see MB::Sound::Shaper); see
        # #asoftclip for the plain version.
        def softclip(threshold = 0.25, limit = 1.0)
          Shaper.new(self, mode: :softclip, p1: threshold, p2: limit)
        end

        # The plain (aliased) version of #softclip.
        def asoftclip(threshold = 0.25, limit = 1.0)
          Shaper.new(self, mode: :softclip, p1: threshold, p2: limit, antialias: false)
        end

        # Adds a quantizer to the node graph.  Values will be rounded to the
        # nearest multiple of +increment+.  To quantize to a given number of
        # bits, use e.g. `5.bits`.  An +increment+ of zero means no quantization.
        #
        # A numeric +increment+ is antialiased (see MB::Sound::Shaper; #aquantize
        # is the plain bitcrusher).  The +increment+ may be another GraphNode to
        # apply a time-varying quantization amount (not antialiased).
        def quantize(increment)
          if increment.is_a?(Numeric) && increment != 0 && increment.to_f.finite?
            Shaper.new(self, mode: :quantize, p1: increment.abs)
          else
            aquantize(increment)
          end
        end

        # The plain (aliased) version of #quantize, the classic bitcrusher.
        def aquantize(increment)
          MB::Sound::GraphNode::Quantize.new(upstream: self, increment: increment)
        end
      end
    end
  end
end
