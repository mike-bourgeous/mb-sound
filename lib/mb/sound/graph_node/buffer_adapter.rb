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
        include GraphNode

        attr_reader :upstream_count

        # Creates a buffer adapter with the given +:upstream+ node to sample,
        # using the given +:upstream_count+ as the value passed to the upstream
        # sample method.
        def initialize(upstream:, upstream_count:)
          raise 'Upstream must respond to :sample' unless upstream.respond_to?(:sample)
          raise 'Upstream count must be a positive Integer' unless upstream_count.is_a?(Integer) && upstream_count > 0

          @upstream = upstream
          @upstream_count = upstream_count
          @complex = false
        end

        # Returns the upstream as the only source for this node.
        def sources
          [@upstream]
        end

        # Returns +count+ samples, using as many or as few reads from the
        # upstream as needed to fulfill the request.
        def sample(count)
          puts "\e[1;35mReading #{count} on #{self} with upstream #{@upstream} and current length of #{@circbuf&.length || 0}\e[0m" # XXX

          setup_circular_buffer(count)

          while @circbuf.length < count
            puts "\e[1;36m  Have #{@circbuf.length} out of #{count}.  Asking upstream #{@upstream} for #{@upstream_count}.\e[0m" # XXX
            v = @upstream.sample(@upstream_count)
            @complex ||= v.is_a?(Numo::SComplex) || v.is_a?(Numo::DComplex)
            @circbuf.write(v)
          end

          puts "\e[1;32m  Now have #{@circbuf.length}, returning #{count}.\e[0m" # XXX

          @circbuf.read(count).not_inplace!
        end

        private

        def setup_circular_buffer(count)
          # Give us a buffer that can handle a multiple of the upstream count
          # that is strictly greater than the read count.
          @bufsize = ((2 * @upstream_count + count) / @upstream_count) * @upstream_count
          @circbuf ||= CircularBuffer.new(buffer_size: @bufsize, complex: @complex)

          # TODO: resize buffer if needed
          # TODO: convert to complex if needed
          if @circbuf.buffer_size != @bufsize || @circbuf.complex != @complex
            raise NotImplementedError, 'TODO: allow resizing the buffer or switching data types'
          end
        end
      end
    end
  end
end
