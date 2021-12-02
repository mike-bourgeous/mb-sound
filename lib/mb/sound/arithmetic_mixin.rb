module MB
  module Sound
    # Adds methods to any
    module ArithmeticMixin
      # Creates a mixer that adds this mixer's output to +other+.  Part of a
      # DSL experiment for building up a signal graph.
      def +(other)
        other.or_for(nil) if other.respond_to?(:or_for) # Default to playing forever
        Mixer.new([self, other])
      end

      # Creates a mixer that subtracts +other+ from this mixer's output.  Part
      # of a DSL experiment for building up a signal graph.
      def -(other)
        other.or_for(nil) if other.respond_to?(:or_for) # Default to playing forever
        Mixer.new([self, [other, -1]])
      end

      # Creates a multiplier that multiplies +other+ by this mixer's output.
      # Part of a DSL experiment for building up a signal graph.
      def *(other)
        other.or_for(nil) if other.respond_to?(:or_for) # Default to playing forever
        other.or_at(1) if other.respond_to?(:or_at) # Keep amplitude high
        Multiplier.new([self, other])
      end

      # Applies the given filter to this sample source or sample chain.
      # Defaults to generating a low-pass filter if given a frequency in Hz.
      #
      # Example:
      #     MB::Sound.play(500.hz.ramp.filter(1200.hz.lowpass(quality: 4)))
      def filter(filter, in_place: true)
        # TODO: some way of modulating filter cutoff e.g. with an ADSR envelope or with a tone
        filter = filter.hz if filter.is_a?(Numeric)
        filter = filter.lowpass if filter.is_a?(Tone)
        filter.wrap(self, in_place: in_place)
      end

      # Wraps this arithmetic signal graph in a softclip effect.
      def softclip(threshold = 0.25, limit = 1.0)
        MB::Sound::Filter::SampleWrapper.new(
          MB::Sound::SoftestClip.new(threshold: threshold, limit: limit),
          self
        )
      end
    end
  end
end
