module MB
  module Sound
    # Extends any audio I/O object with a #read method with a #sample method
    # for compatibility with the arithmetic DSL.
    module IOSampleMixin
      # Reads +count+ frames (which should match the preferred buffer size of
      # the input object), returning only the first channel from the input.
      # This is for interoperability with the arithmetic DSL in MB::Sound that
      # allows combining Tones, Mixers, Multipliers, and inputs.
      def sample(count)
        read(count)[0]
      end
    end
  end
end
