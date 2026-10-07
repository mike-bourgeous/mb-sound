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

        # Shapes this signal through a tweening curve (MB::Sound::Curve: a
        # name such as :smoothstep (default), :sine, :elastic, :bounce,
        # :steps, :back, a Curve, a Proc, ...; +overshoot:+ and +cycles:+ go
        # to a named curve).  +in:+ (default 0..1) is the input range mapped
        # onto the curve's 0..1, and +out:+ (default 0..1) the output range
        # its 0..1 maps onto (+range:+ sets both; a number n means 0..n).
        # +edges:+ handles inputs outside the input range: :clamp (default),
        # :extend, :wrap, :mirror, or :none; +symmetric: true+ shapes the
        # magnitude and restores the sign (an odd waveshaper for audio).
        # See GraphNode::CurveShaper.
        #
        # Antialiased like #softclip (half a sample of delay); #aease is the
        # exact plain version for control signals (LFO gates, stepped
        # automation).
        #
        # Named "ease" because #curve and #shape are Envelope settings and
        # #shaper / Shaper are the clip family.
        #
        #     play 110.hz.ease(:bounce, range: -1..1, edges: :mirror) * 0.3       # a bouncing waveshaper
        #     play 220.hz.ease(:elastic, symmetric: true) * 0.2                      # odd elastic shaping
        #     amp = 1.bar.hz.phasor.aease(:steps, cycles: 4)                        # a 4-step gate ramp each bar
        #     wah = 2.beats.lfo.aease(:bounce, in: -1..1, out: 300..3000)           # a bouncing filter LFO
        def ease(curve = :smoothstep, range: nil, edges: :clamp, symmetric: false, overshoot: nil, cycles: nil, antialias: true, **io)
          extra = io.keys - [:in, :out]
          raise ArgumentError, "Unknown ease options #{extra.inspect} (in:, out:, range:, edges:, symmetric:, overshoot:, cycles:)" unless extra.empty?

          c = MB::Sound::Curve.from(curve, **{ overshoot: overshoot, cycles: cycles }.compact)
          CurveShaper.new(
            self, curve: c, input: io.fetch(:in, range || (0.0..1.0)), output: io.fetch(:out, range || (0.0..1.0)),
            edges: edges, symmetric: symmetric, antialias: antialias
          )
        end
        alias shape_curve ease

        # The plain (exact, aliasing) version of #ease, for control signals.
        def aease(curve = :smoothstep, **options)
          ease(curve, **options, antialias: false)
        end
        alias ashape_curve aease

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
