module MB
  module Sound
    # Base functionality for audio output streams that writes 32-bit
    # little-endian floats to a byte-wise IO stream (e.g. STDOUT, or an
    # application opened with IO.popen).
    class IOOutput
      attr_reader :channels, :frames_written

      # Initializes an IO-writing audio output stream for the given IO object
      # and number of channels.
      def initialize(io, channels)
        raise 'IO must respond to :write' unless io.respond_to?(:write)
        raise 'Channels must be an int >= 1' unless channels.is_a?(Integer) && channels >= 1

        @io = io
        @channels = channels
        @frame_bytes = channels * 4
        @frames_written = 0
      end

      # Returns true if the output has been closed.
      def closed?
        @io.nil? || @io.closed?
      end

      # Writes +data+ (an Array of Numo::NArrays) to the IO given to the
      # constructor as raw 32-bit little-endian floats.  Data is written in
      # interleaved frames, with one frame containing one sample for every
      # channel.
      def write(data)
        raise IOError, 'Output is closed' if @io.nil? || @io.closed?
        raise ArgumentError, "Received #{data.length} channels when #{@channels} were expected" if data.length != @channels

        buf = String.new(capacity: data.first.size * @frame_bytes)
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

      # Closes the input IO object.  Returns the process exit status object if
      # the IO object was opened by popen.
      def close
        return unless @io

        old_result = $?
        @io.close
        @io = nil
        new_result = $?

        new_result == old_result ? nil : new_result
      end
    end
  end
end
