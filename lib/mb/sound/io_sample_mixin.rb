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
        data = read(count)
        return nil if data.nil? || data.empty? || data[0].empty?

        buf = data[0]
        buf = MB::M.zpad(buf, count) if buf.length < count
        buf
      end
    end
  end
end
