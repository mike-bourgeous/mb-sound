module MB
  module Sound
    # Base functionality for input streams that read 32-bit little-endian
    # floats from a byte-wise IO stream (e.g. STDIN, or a program via popen).
    #
    # See FFMPEGInput for an example.
    class IOInput < IOBase
      include GraphNode
      include IOSampleMixin

      attr_reader :frames_read

      # Initializes an IO-reading audio input stream for the given I/O object
      # and number of channels.  The first parameter may be a command to pass
      # to IOBase#run (an Array or a String).
      def initialize(io_or_cmd, channels, buffer_size)
        raise 'IO must respond to :read' unless io_or_cmd.is_a?(Array) || io_or_cmd.respond_to?(:read)
        io_or_cmd = [io_or_cmd, 'r'] if io_or_cmd.is_a?(Array)
        super(io_or_cmd, channels, buffer_size)
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
    end
  end
end
