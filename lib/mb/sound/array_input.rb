module MB
  module Sound
    # An input stream that returns chunks from an Array or Numo::NArray.
    class ArrayInput
      attr_reader :channels, :frames, :rate, :offset, :remaining, :buffer_size

      # Initializes an audio stream that returns slices from the given +data+ (an
      # Array of Arrays or Numo::NArrays, one for each channel).  If the lengths
      # of each channel do not match, the shorter channels will return zeros
      # until all channels have ended.
      def initialize(data:, rate: 48000, buffer_size: 800)
        @buffer_size = buffer_size
        @channels = data.length
        @frames = data.map(&:length).max
        @data = data.map { |v|
          # Compensate for arrays of differing lengths (TODO: support Complex data)
          Numo::SFloat.zeros(@frames).tap { |c|
            c[0...v.length] = v if @frames > 0 && v.length > 0
          }
        }
        @rate = rate

        @remaining = @frames
        @offset = 0
      end

      # Causes the next call to #read to start at the given frame +offset+ from
      # the start of the internal arrays.
      def seek_set(offset)
        raise 'Offset must be less than total frames' if offset >= @frames
        raise 'Offset must be >= 0' if offset < 0
        @offset = offset
        @remaining = @frames - @offset
      end

      # Moves the current read pointer by +offset+, which may be negative.  The
      # resulting read pointer will be clamped to the start and end of the array.
      def seek_rel(offset)
        @offset += offset
        @offset = 0 if @offset < 0
        @offset = @frames if @offset > @frames
        @remaining = @frames - @offset
      end

      # Reads up to +frames+ frames starting from the current read pointer within
      # the internal arrays.  Returns less than +frames+ if near the end, or
      # empty arrays if at the end.
      def read(frames = @buffer_size)
        raise 'Must read at least one frame' if frames < 1

        start = @offset
        if @remaining < frames
          frames = @remaining
        end
        @remaining -= frames
        @offset += frames

        if frames > 0
          @data.map { |c| c[start...(start + frames)] }
        else
          [ Numo::SFloat[] ] * @channels
        end
      end
    end
  end
end
