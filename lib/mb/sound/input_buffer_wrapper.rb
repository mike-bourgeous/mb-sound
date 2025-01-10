require 'forwardable'

module MB
  module Sound
    # A wrapper around an I/O object that uses circular buffers to allow
    # reads of arbitrary size, instead of requiring reads to be equal to the
    # buffer size.
    class InputBufferWrapper
      extend Forwardable

      include GraphNode
      include GraphNode::IOSampleMixin

      def_delegators :@input, :rate, :channels, :buffer_size, :closed?

      # Creates a buffer wrapper with the given +input+ instance (e.g.
      # MB::Sound::FFMPEGInput or MB::Sound::JackFFI::Input).
      def initialize(input)
        [:read, :rate, :channels, :buffer_size].each do |req_method|
          raise 'Input must respond to req_method' unless upstream.respond_to?(req_method)
          raise 'Input must respond to req_method' unless upstream.respond_to?(req_method)
          raise 'Input must respond to req_method' unless upstream.respond_to?(req_method)
          raise 'Input must respond to req_method' unless upstream.respond_to?(req_method)
        end

        @input = input
      end

      # Reads +frames+ frames from all channels, returning an Array of
      # Numo::NArray.  This may return fewer frames if the end of input (e.g.
      # end of file) has been reached.
      def read(count)
        setup_circular_buffers(count)

        while @circbuf[0].length < count
          v = @input.read(@input.buffer_size)

          # End of input; return whatever we can from the buffer, or nil
          if v.nil? || v.empty? || v.any?(&:empty?)
            return nil if @circbuf[0].length == 0
          end

          v.each.with_index do |c, idx|
            @circbuf[idx].write(c)
          end
        end

        if @circbuf[0].empty?
          raise 'Input is closed' if @input.closed?
          return nil
        elsif @circbuf[0].length < count
          @circbufs.map { |b| b.read(b.length).not_inplace! }
        else
          @circbufs.map { |b| b.read(count).not_inplace! }
        end
      end

      private

      def setup_circular_buffers(count)
        # TODO: maybe dedupe with BufferAdapter

        for idx in 0...@input.channels
          # Give us a buffer that can handle a multiple of the buffer size that
          # is strictly greater than the read count.
          @bufsize = ((2 * @input.buffer_size + count) / @input.buffer_size) * @input.buffer_size
          @circbuf ||= CircularBuffer.new(buffer_size: @bufsize, complex: false)

          if @circbuf.buffer_size < @bufsize
            # TODO: add in-place resizing to CircularBuffer if this is too slow
            newbuf = CircularBuffer.new(buffer_size: @bufsize, complex: @circbuf.complex)
            newbuf.write(@circbuf.read(@circbuf.length)) unless @circbuf.empty?
            @circbuf = newbuf
          end
        end
      end
    end
  end
end
