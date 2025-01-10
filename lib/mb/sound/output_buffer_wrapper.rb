require 'forwardable'

module MB
  module Sound
    # A wrapper around an output object that uses circular buffers to allow
    # writes of arbitrary size, instead of requiring writes to be equal to the
    # output's buffer size.
    class OutputBufferWrapper
      extend Forwardable

      include GraphNode
      include GraphNode::IOSampleMixin

      def_delegators :@output, :rate, :channels, :buffer_size, :closed?

      # Creates a buffer wrapper with the given +output+ instance (e.g.
      # MB::Sound::FFMPEGOutput or MB::Sound::JackFFI::Output).
      #
      # If :always_pad is true, then #flush will zero-pad the data it writes to
      # a multiple of the output buffer size even if the output does not
      # require it.  See MB::Sound::FFMPEGOutput#strict_buffer_size?.
      def initialize(output, always_pad: false)
        [:write, :rate, :channels, :buffer_size].each do |req_method|
          raise "Output must respond to #{req_method.inspect}" unless output.respond_to?(req_method)
        end

        @always_pad = !!always_pad
        @output = output
        setup_circular_buffers(@output.buffer_size)
      end

      # Writes the given +data+ (an Array of Numo::NArray, with one Numo::NArray
      # per output channel) to the output.
      def write(data)
        raise 'Data must be an Array of Numo::NArray' unless data.is_a?(Array) && data.all?(Numo::NArray)
        raise "Must have #{@output.channels} channels; got #{data.length}" if data.length != @output.channels

        setup_circular_buffers(data[0].length)

        data.each.with_index do |c, idx|
          @circbufs[idx].write(c)
        end

        while @circbufs[0].length >= @output.buffer_size
          @output.write(@circbufs.map { |c| c.read(@output.buffer_size) })
        end
      end

      # Writes all data in the circular buffers to the output.  Data will be
      # zero padded to the buffer size if the output's strict_buffer_size?
      # method returns true, or if it does not have that method.
      def flush
        if @always_pad || !@output.respond_to?(:strict_buffer_size?) || @output.strict_buffer_size?
          until @circbufs[0].empty?
            count = MB::M.min(@circbufs[0].length, @output.buffer_size)
            @output.write(@circbufs.map { |c| MB::M.zpad(c.read(count), @output.buffer_size) })
          end
        elsif !@circbufs[0].empty?
          @output.write(@circbufs.map { |c| c.read(c.length) })
        end
      end

      # If the output has a close method, then this will write any remaining
      # data (with zero padding to match the output buffer size if needed) and
      # then close the output.
      #
      # See #flush.
      def close
        raise 'Output does not respond to :close' unless @output.respond_to?(:close)

        flush

        @output.close
      end

      private

      def setup_circular_buffers(count)
        # TODO: maybe dedupe with BufferAdapter and InputBufferWrapper

        @bufsize = ((2 * @output.buffer_size + count) / @output.buffer_size) * @output.buffer_size
        @circbufs ||= Array.new(@output.channels)

        for idx in 0...@output.channels
          # Give us a buffer that can handle a multiple of the buffer size that
          # is strictly greater than the write count.
          @circbufs[idx] ||= CircularBuffer.new(buffer_size: @bufsize, complex: false)

          if @circbufs[idx].buffer_size < @bufsize
            # TODO: add in-place resizing to CircularBuffer if this is too slow
            newbuf = CircularBuffer.new(buffer_size: @bufsize, complex: @circbufs[idx].complex)
            newbuf.write(@circbufs[idx].read(@circbufs[idx].length)) unless @circbufs[idx].empty?
            @circbufs[idx] = newbuf
          end
        end
      end
    end
  end
end
