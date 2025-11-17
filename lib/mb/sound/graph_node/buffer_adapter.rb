require 'forwardable'

module MB
  module Sound
    module GraphNode
      # A graph node that samples its upstream graph using a different sample
      # count from whatever is passed to this node's #sample method.
      #
      # This works by calling the upstream GraphNode#sample method as many
      # times as necessary to fill the request passed to #sample here if the
      # upstream buffer size is smaller, and by treating the buffer as a
      # circular buffer if the upstream buffer size is larger.
      class BufferAdapter
        extend Forwardable

        include GraphNode

        attr_reader :upstream_count

        def_delegators :@upstream, :sample_rate, :sample_rate=

        # Creates a buffer adapter with the given +:upstream+ node to sample,
        # using the given +:upstream_count+ as the value passed to the upstream
        # sample method.
        def initialize(upstream:, upstream_count:)
          raise 'Upstream must respond to :sample' unless upstream.respond_to?(:sample)
          raise 'Upstream count must be a positive Integer' unless upstream_count.is_a?(Integer) && upstream_count > 0

          @upstream = upstream.get_sampler
          @upstream_count = upstream_count
        end

        # Returns the upstream as the only source for this node.
        def sources
          [@upstream]
        end

        # Wraps upstream #at_rate to return self instead of upstream.
        def at_rate(new_rate)
          @upstream.at_rate(new_rate)
          self
        end

        # Returns +count+ samples, using as many or as few reads from the
        # upstream as needed to fulfill the request.
        def sample(count)
          setup_circular_buffer(count)

          while @circbuf.length < count
            v = @upstream.sample(@upstream_count)

            # End of input; return whatever we can from the buffer, or nil
            if v.nil? || v.empty?
              return nil if @circbuf.length == 0
              return @circbuf.read(MB::M.min(count, @circbuf.length))
            end

            @circbuf.write(v)
          end

          @circbuf.read(count).not_inplace!
        end

        private

        def setup_circular_buffer(count)
          # TODO: maybe dedupe with InputBufferWrapper

          # Give us a buffer that can handle a multiple of the upstream count
          # that is strictly greater than the read count.
          @bufsize = ((2 * @upstream_count + count) / @upstream_count) * @upstream_count
          @circbuf ||= CircularBuffer.new(buffer_size: @bufsize, complex: false)

          if @circbuf.buffer_size < @bufsize
            @circbuf = @circbuf.dup(@bufsize)
          end
        end
      end
    end
  end
end
