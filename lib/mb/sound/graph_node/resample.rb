module MB
  module Sound
    module GraphNode
      # This graph node converts from one sample rate to another.  The upstream
      # sample rate is detected from the source node.
      #
      # TODO: what algorithms will this support?
      class Resample
        include BufferHelper

        # Creates a resampling graph node with the given +:upstream+ node and
        # +:sample_rate+.
        def initialize(upstream:, sample_rate:)
          raise 'Upstream must respond to :sample' unless upstream.respond_to?(:sample)
          raise 'Upstream must respond to :sample_rate' unless upstream.respond_to?(:sample_rate)

          @upstream = upstream
          @sample_rate = sample_rate.to_f
          @ratio = @sample_rate / upstream.sample_rate
          @error = 0
        end

        # Returns the upstream as the only source for this node.
        def sources
          [@upstream]
        end

        # Returns +count+ samples at the new sample rate, while requesting
        # sufficient samples from the upstream node to fulfill the request.
        def sample(count)
          required = @ratio * count
          @error += required - required.floor
          required = required.floor

          data = upstream.sample(required)

          # TODO: use something smarter than zero-order hold
          setup_buffer(length: count)

          Numo::SFloat.linspace(0, required, count).inplace.map_with_index { |v, idx|
            data[idx]
          }
        end
      end
    end
  end
end
