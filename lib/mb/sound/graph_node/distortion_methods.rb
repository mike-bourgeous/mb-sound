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
        # Hard-clips this node between +min+ and +max+ (nil for no limit),
        # antialiased.  See #aclip for exact clipping of control signals.
        def clip(min, max)
          Shaper.new(self, mode: :clip, p1: min, p2: max).named("clip #{min}..#{max}")
        end

        # Hard-clips like #clip without antialiasing: exact, for control
        # signals.  No added delay, for delay times and envelopes.
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

        # Shapes every sample through a transfer curve drawn in dB (DbShaper).
        # Input level to output level, the sign kept (after Sonic Foundry's
        # DirectX Distortion): points as for #compand
        # (`-60.db => -30.db`, a Hash or [input, output(, shape)] rows; bare
        # numbers are linear gains), joined by straight lines in dB
        # (+interpolation+ :linear, the default) or monotone cubics
        # (:cubic).  Unlike #compand the curve works on each sample, not a
        # smoothed level: it distorts.  Outputs may fall as inputs rise
        # (fold-back).  Two outputs at one input are a vertical step
        # (`-34.db => [-40.db, -12.db]`, or two rows with that input): the
        # curve jumps there, taking the second output at the step and
        # above.  A Symbol is a preset (`shape_db(:fuzz)`; DbShaper
        # presets :soft_knee (the default), :fuzz, :fold_back, :gate,
        # :asymmetric; `L.fx.shape_db`), with the other options over it.
        #
        # +negative+ is :mirror (default: negative samples mirror the
        # positive curve) or points of their own.  +below+ says what happens
        # under the first point: :line (continue its line, as #compand does),
        # :unity (slope 1 from the first point), or :silence.  Above the
        # last point the last line continues (inputs over full scale keep
        # following it).  +mix+ (0..1) is the shaped share, phase-aligned.
        #
        # Antialiased like #softclip (half a sample of delay; closed-form
        # ADAA of the power laws that dB lines are); #ashape_db is the exact
        # version for control signals.
        #
        #     play 110.hz.saw.at(-6.db).shape_db(-84.db => -60.db, -48.db => -18.db, 0.db => -6.db)   # a dense fuzz
        #     play 110.hz.saw.shape_db(:fold_back, mix: 0.5)
        #     play 220.hz.triangle.shape_db(-40.db => -40.db, 0.db => -10.db, negative: { -40.db => -40.db, -10.db => -10.db, 0.db => -10.db })
        def shape_db(points = nil, negative: nil, interpolation: nil, below: nil, mix: nil, antialias: true, **more_points)
          DbShaper.build(self, points, more_points, negative: negative, interpolation: interpolation, below: below, mix: mix, antialias: antialias)
        end

        # The plain (exact, aliasing) version of #shape_db, for control
        # signals.
        def ashape_db(points = nil, **options)
          shape_db(points, **options, antialias: false)
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

        # Samples and holds this node at each rising edge of +trigger+
        # (SampleHold).  Quantizing in time, as #quantize does in level.
        # Without a trigger, this node is the trigger and the held values are
        # random (+range+, default -1..1; +seed+), e.g.
        # `8.hz.lfo.square.sample_hold` is a stepped random LFO at 8 steps per
        # second.  Alias #sah.
        def sample_hold(trigger = nil, range: -1.0..1.0, seed: nil)
          return SampleHold.new(nil, self, range: range, seed: seed, sample_rate: sample_rate) if trigger.nil?
          SampleHold.new(self, trigger, sample_rate: sample_rate)
        end
        alias sah sample_hold

        # Sample-rate reduction to +rate+ Hz, aliasing on purpose
        # (GraphNode::Decimator).  A zero-order hold with no filtering: the
        # lo-fi sampler crunch, and with a resonant filter before it, moving
        # vocal-like peaks.  +rate+ is a number, a Pitch, or a node of Hz that
        # may move every sample (e.g. `v.freq * 6` tracks the note, so every
        # note folds the same way); +jitter+ (0..0.95) loosens the hold clock at
        # random (+seed+).  +mix+ is the crushed share (1, the default, all
        # crushed; a number or a node; to be consolidated with a universal
        # wet/dry mix for nodes and subgraphs when one exists).  Bit crushing is
        # #aquantize.  Aliases #crush_rate, #srr (sample-rate reduction).
        #
        #     play 110.hz.saw.lp4(1500, resonance: 0.8).decimate(2900)
        #     play 220.hz.square.decimate(0.2.hz.lfo.at(500..6000), jitter: 0.2)
        #     play 110.hz.saw.lp4(1500, resonance: 0.8).decimate(2900, mix: 0.4)   # 40% crushed
        #     play 220.hz.triangle.decimate(4000, interpolation: :linear)            # grit, less ringing
        #
        # +interpolation+ :linear joins the held samples with straight lines
        # (a first-order hold, one hold period late) instead of steps:
        # the same folding with much weaker high images.
        def decimate(rate, jitter: 0, seed: nil, mix: 1, interpolation: :hold)
          Decimator.new(self, rate: rate, jitter: jitter, seed: seed, mix: mix, interpolation: interpolation, sample_rate: sample_rate)
        end
        alias crush_rate decimate
        alias srr decimate
      end
    end
  end
end
