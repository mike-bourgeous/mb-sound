module MB
  module Sound
    # Adds methods to any
    module ArithmeticMixin
      # Creates a mixer that adds this mixer's output to +other+.  Part of a
      # DSL experiment for building up a signal graph.
      def +(other)
        other.or_for(nil) if other.is_a?(Tone) # Default to playing other tones forever
        Mixer.new([self, other])
      end

      # Creates a mixer that subtracts +other+ from this mixer's output.  Part
      # of a DSL experiment for building up a signal graph.
      def -(other)
        other.or_for(nil) if other.is_a?(Tone) # Default to playing other tones forever
        Mixer.new([self, [other, -1]])
      end

      # Creates a multiplier that multiplies +other+ by this mixer's output.
      # Part of a DSL experiment for building up a signal graph.
      def *(other)
        other.or_for(nil) if other.is_a?(Tone) # Default to playing other tones forever
        other.or_at(1) if other.is_a?(Tone) # Keep amplitude high if multiplying tones
        Multiplier.new([self, other])
      end

      # Applies the given filter to this sample source or sample chain.
      # Defaults to generating a low-pass filter if given a frequency in Hz.
      #
      # Example:
      #     MB::Sound.play(500.hz.ramp.filter(1200.hz.lowpass(quality: 4)))
      def filter(filter, in_place: true)
        filter = filter.hz if filter.is_a?(Numeric)
        filter = filter.lowpass if filter.is_a?(Tone)
        filter.wrap(self, in_place: in_place)
      end
    end
  end
end
