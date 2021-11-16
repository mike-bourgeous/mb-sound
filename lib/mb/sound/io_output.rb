module MB
  module Sound
    # Base functionality for audio output streams that writes 32-bit
    # little-endian floats to a byte-wise IO stream (e.g. STDOUT, or an
    # application opened with IO.popen).
    #
    # See FFMPEGOutput for an example.
    class IOOutput < IOBase
      attr_reader :frames_written, :rate # TODO: Maybe move :rate into IOBase

      # Initializes an IO-writing audio output stream for the given IO object
      # and number of channels.  The first parameter may be an Array of
      # arguments to pass to IOBase#run.
      def initialize(io, channels, buffer_size, rate:)
        raise 'IO must respond to :write' unless io.is_a?(Array) || io.respond_to?(:write)
        io = [io, 'w'] if io.is_a?(Array)
        super(io, channels, buffer_size)
        @frames_written = 0
        @rate = rate
      end

      # Writes +data+ (an Array of Numo::NArrays) to the IO given to the
      # constructor as raw 32-bit little-endian floats.  Data is written in
      # interleaved frames, with one frame containing one sample for every
      # channel.
      def write(data)
        raise IOError, 'Output is closed' if @io.nil? || @io.closed?
        raise ArgumentError, "Received #{data.length} channels when #{@channels} were expected" if data.length != @channels

        buf = String.new(capacity: data.first.size * @frame_bytes, encoding: Encoding::ASCII_8BIT)
        data.first.size.times do |idx|
          buf << data.map { |c| c[idx] }.pack('e*')
        end

        bytes = @io.write(buf)
        raise 'Bytes written was not a multiple of frame size' unless bytes % @frame_bytes == 0

        frames = bytes / @frame_bytes
        puts "Warning: wrote #{frames} frames when #{data.first.size} were requested" if frames != data.first.size

        @frames_written += frames

        frames
      end
    end
  end
end
