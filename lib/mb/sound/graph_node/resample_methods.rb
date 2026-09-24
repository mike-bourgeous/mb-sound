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
        # For example, compare the sound of the following (turn volume down):
        #
        #     # No oversampling; has prominent lower frequency aliasing
        #     play 355.hz.pm(630.hz.at(100) * 0.5.hz.drumramp.at(0.9..1).filter(10.hz.lowpass)).forever
        #     # With oversampling; does not have the same aliasing
        #     play 355.hz.pm(630.hz.at(100) * 0.5.hz.drumramp.at(0.9..1).filter(10.hz.lowpass)).oversample(16).forever
        def oversample(multiplier, mode: MB::Sound::GraphNode::Resample::DEFAULT_MODE)
          # FIXME: calling oversample twice on the same node causes the upstream rate to keep multiplying.  Should we assume a 48kHz output rate?  Maybe add a sample_rate parameter to this method?
          current_rate = self.sample_rate
          self.at_rate(current_rate * multiplier).resample(current_rate, mode: mode)
        end
      end
    end
  end
end
