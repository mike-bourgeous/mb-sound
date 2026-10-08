module MB
  module Sound
    module GraphNode
      # Graph feedback (see FeedbackLoop): DSL methods included in GraphNode.
      module FeedbackMethods
        # Builds a feedback loop on this node: the block gets the loop
        # variable +y+ (the loop's own output; see FeedbackLoop for when it
        # is the current output and when the one before) and this node +x+,
        # and returns the loop's body, which the loop runs one sample at a
        # time.  Returns the loop (a FeedbackLoop node).  Also available as
        # #fb.
        #
        # The body may contain arithmetic, shapers (softclip, clip, ...),
        # delays (`y.delay(t)`), and SVF filters (`filter(:lowpass, ...)`)
        # on the path from +y+ to the output; anything else (oscillators,
        # envelopes, LFOs, MIDI nodes) only where it doesn't depend on +y+
        # (e.g. as a delay time or a gain).  The longest delay on the loop
        # absorbs the loop's other latency, so its time is the loop's period
        # (`compensate: false` turns that off; FeedbackLoop#latency).
        #
        # (Tone's FM operator self-feedback, #feedback until 2026-10-09, is
        # Tone#fm_feedback.)
        #
        # Examples (bin/sound.rb):
        #     # A comb filter: echoes every 5 ms, each 0.7 times the last
        #     play input.feedback { |y, x| x + y.delay(5.ms) * 0.7 }
        #     # A one-pole lowpass built from nodes (y is the previous sample)
        #     play noise.feedback { |y, x| x + (y - x) * 0.95 }
        #     # Karplus-Strong (see bin/synths/pluck.rb)
        #     exc = noise.at(0.5) * adsr(0, 0.003, 0, 0.003, hold: 0.003)
        #     play exc.feedback { |y, x| d = y.delay(110.hz.period, smoothing: false); x + (d + d.delay(1.samples)) * 0.498 }
        def feedback(*args, compensate: true, &block)
          unless args.empty?
            raise ArgumentError, "#feedback is graph feedback and takes a block (`sig.feedback { |y, x| ... }`); for FM operator self-feedback use #fm_feedback(#{args.map(&:inspect).join(', ')})"
          end
          raise ArgumentError, 'Pass a block that builds the loop body from the loop variable: `sig.feedback { |y, x| x + y.delay(t) * 0.5 }`' unless block

          FeedbackLoop.new(self, compensate: compensate, &block)
        end
        alias fb feedback
      end
    end
  end
end
