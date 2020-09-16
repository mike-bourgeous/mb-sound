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
        bytes = @io.read(frames * @frame_bytes)
        return [ Numo::SFloat[] ] * @channels if bytes.nil? # end of file

        raise 'Bytes read was not a multiple of frame size' unless bytes.size % @frame_bytes == 0

        frames_read = bytes.size / @frame_bytes
        @frames_read += frames_read / @channels

        # TODO: each_slice + transpose is probably slow; do something faster
        bytes.unpack('e*').each_slice(@channels).to_a.transpose.map { |c| Sound.array_to_narray(c) }
      end
    end
  end
end
