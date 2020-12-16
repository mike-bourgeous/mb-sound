module MB
  module Sound
    # Base functionality for input streams that read 32-bit little-endian
    # floats from a byte-wise IO stream (e.g. STDIN, or a program via popen).
    #
    # See FFMPEGInput for example.
    class IOInput
      attr_reader :channels, :frames_read

      # Initializes an IO-reading audio input stream for the given I/O object and
      # number of channels.
      def initialize(io, channels)
        raise 'IO must respond to :read' unless io.respond_to?(:read)
        raise 'Channels must be an int >= 1' unless channels.is_a?(Integer) && channels >= 1

        @io = io
        @channels = channels
        @frame_bytes = channels * 4
        @frames_read = 0
      end

      # Reads +frames+ frames of raw 32-bit floats for +@channels+ channels from
      # the IO given to the constructor.  Returns an array of @channels NArrays.
      def read(frames)
        raise IOError, "Input is closed" if @io.nil? || @io.closed?

        bytes = @io.read(frames * @frame_bytes)
        return [ Numo::SFloat[] ] * @channels if bytes.nil? # end of file

        raise 'Bytes read was not a multiple of frame size' unless bytes.size % @frame_bytes == 0

        # @frame_bytes is already scaled by the number of channels
        frames_read = bytes.size / @frame_bytes
        @frames_read += frames_read

        data = Numo::SFloat.from_binary(bytes).reshape(frames_read, @channels)
        @channels.times.map { |c|
          data[nil, c]
        }
      end

      # Closes the input IO object.  Returns the process exit status object if
      # the IO object was opened by popen.
      def close
        return unless @io
        @io.close
        result = @io.respond_to?(:pid) ? $? : nil
        @io = nil
        result
      end
    end
  end
end
