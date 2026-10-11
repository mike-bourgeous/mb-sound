module MB
  module Sound
    module GraphNode
      # Methods for changing the sample rate of part of a graph.  Included in
      # GraphNode.
      module ResampleMethods
        # Adds a resampling filter to the graph with the given new sample rate.
        # All nodes added after the resampling node must use the new sample rate.
        #
        # The resampling +:mode+ must be one of the supported modes listed in
        # MB::Sound::GraphNode::Resample::MODES (e.g. :libsamplerate_best).
        def resample(sample_rate = self.sample_rate, mode: MB::Sound::GraphNode::Resample::DEFAULT_MODE)
          MB::Sound::GraphNode::Resample.new(upstream: self, sample_rate: sample_rate, mode: mode)
        end

        # Tells this node and all upstream nodes to run at +multiplier+ times the
        # current sample rate, then appends a Resample node to restore the
        # current sample rate.  The +multiplier+ may also be less than one to
        # undersample, and may be fractional (for most node types).
        #
        # The upstream rates change when the graph first plays (or is
        # planned; see Resample#apply_oversample), once every consumer of
        # every upstream node exists: a node also read outside the region
        # (through another Tee branch) keeps its rate, and the region reads
        # it through a resampler (see GraphNode::Tee), so shared nodes give
        # every consumer the same signal at its own rate (2026-10-11; they
        # used to be read at two rates, and a node built later on a shared
        # node took the raised rate).  Oversample a node nothing else reads
        # to run it at the higher rate.
        #
        # For example, compare the sound of the following (turn volume down):
        #
        #     # No oversampling; has prominent lower frequency aliasing
        #     play 355.hz.pm(630.hz.at(16) * 0.5.hz.drumramp.at(0.9..1).filter(10.hz.lowpass))
        #     # With oversampling; does not have the same aliasing
        #     play 355.hz.pm(630.hz.at(16) * 0.5.hz.drumramp.at(0.9..1).filter(10.hz.lowpass)).oversample(16)
        def oversample(multiplier, mode: MB::Sound::GraphNode::Resample::DEFAULT_MODE)
          raise ArgumentError, "Oversampling multiplier must be a positive number (got #{multiplier.inspect})" unless multiplier.is_a?(Numeric) && multiplier.positive? && multiplier.finite?

          MB::Sound::GraphNode::Resample.new(upstream: self, sample_rate: self.sample_rate, mode: mode).oversampling(multiplier)
        end
      end
    end
  end
end
