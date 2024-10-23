module MB
  module Sound
    # An input stream that returns chunks from an Array or Numo::NArray.
    class ArrayInput
      include GraphNode
      include GraphNode::IOSampleMixin

      attr_reader :channels, :frames, :rate, :offset, :remaining, :buffer_size, :repeat

      # Initializes an audio stream that returns slices from the given +data+ (an
      # Array of Arrays or Numo::NArrays, one for each channel).  If the lengths
      # of each channel do not match, the shorter channels will return zeros
      # until all channels have ended.
      def initialize(data:, rate: 48000, buffer_size: 800, repeat: false)
        @buffer_size = buffer_size
        @channels = data.length
        @frames = data.map(&:length).max

        data = data.map { |v| Numo::NArray.cast(v) }

        case
        when data.any?(Numo::DComplex)
          @dtype = Numo::DComplex

        when data.any?(Numo::SComplex)
          if data.any?(Numo::DFloat) || data.any?(Numo::Int32) || data.any?(Numo::Int64)
            @dtype = Numo::DComplex
          else
            @dtype = Numo::SComplex
          end

        when data.any?(Numo::DFloat) || data.any?(Numo::Int32) || data.any?(Numo::Int64)
          @dtype = Numo::DFloat

        else
          @dtype = Numo::SFloat
        end

        # Convert all arrays to have the same type and length
        @data = data.map { |v|
          @dtype.zeros(@frames).tap { |c|
            c[0...v.length] = v if @frames > 0 && v.length > 0
          }
        }

        @rate = rate

        @remaining = @frames
        @offset = 0
        @repeat = !!repeat
      end

      # Causes the next call to #read to start at the given frame +offset+ from
      # the start of the internal arrays.
      def seek_set(offset)
        raise 'Offset must be less than total frames' if offset >= @frames
        raise 'Offset must be >= 0' if offset < 0
        @offset = offset
        @remaining = @frames - @offset
      end
      alias offset= seek_set

      # Moves the current read pointer by +offset+, which may be negative.  The
      # resulting read pointer will be clamped to the start and end of the array.
      def seek_rel(offset)
        @offset += offset
        @offset = 0 if @offset < 0
        @offset = @frames if @offset > @frames
        @remaining = @frames - @offset
      end

      # Reads up to +frames+ frames starting from the current read pointer within
      # the internal arrays.  Returns less than +frames+ if near the end and
      # not repeating, or empty arrays if at the end.
      def read(frames = @buffer_size)
        raise 'Must read at least one frame' if frames < 1

        start = @offset

        if @remaining < frames
          if @repeat
            extra = frames - @remaining

            # TODO: Handle the case where frames is more than twice the length
            # of the total loop, or is more than the length of the loop plus
            # the remaining frames
            if extra == frames
              # TODO: this case should never execute because of the outermost if statement
              ret = @data.map { |c| c[0...frames] }
            else
              ret = @data.map { |c| c[start...@frames].concatenate(c[0...extra]) }
            end

            @remaining = @frames - extra
            @offset = extra

            return ret
          end

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
