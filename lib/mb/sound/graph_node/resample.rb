module MB
  module Sound
    module GraphNode
      # This graph node converts from one sample rate to another.  The upstream
      # sample rate is detected from the source node.
      #
      # TODO: what algorithms will this support?
      class Resample
        include GraphNode
        include BufferHelper

        attr_reader :sample_rate, :ratio

        # Creates a resampling graph node with the given +:upstream+ node and
        # +:sample_rate+.
        def initialize(upstream:, sample_rate:)
          raise 'Upstream must respond to :sample' unless upstream.respond_to?(:sample)
          raise 'Upstream must respond to :sample_rate' unless upstream.respond_to?(:sample_rate)

          @upstream = upstream
          @sample_rate = sample_rate.to_f
          @ratio = upstream.sample_rate.to_f / @sample_rate
          @error = 0
        end

        # Returns the upstream as the only source for this node.
        def sources
          [@upstream]
        end

        # Returns +count+ samples at the new sample rate, while requesting
        # sufficient samples from the upstream node to fulfill the request.
        def sample(count)
          exact_required = @ratio * count + @error
          required = exact_required.floor
          @error = exact_required - required

          raise "Ratio #{@ratio} too low for count #{count} (tried to read zero samples from upstream)" if required == 0

          puts "#{self.__id__} Reading #{required} samples to return #{count}, to go from #{@upstream.sample_rate} to #{@sample_rate}; error is #{@error}" # XXX

          # FIXME: use a circular buffer if upstreams don't like oscillating
          # between N and N+1 samples
          data = @upstream.sample(required)
          return nil if data.nil? || data.empty?

          if data.length < required
            count = count * data.length / required
            required = data.length
            return nil if count == 0
          end

          # TODO: use something smarter than zero-order hold
          # TODO: have we already implemented usable code in a fractionally
          # addressed delay line or something?
          # XXX setup_buffer(length: count)

          # TODO: reuse the existing buffer instead of regenerating a
          # "linspace" every time, or maybe keep a buffer for required and
          # required+1
          Numo::SFloat.linspace(0, required - 1, count).inplace.map { |v|
            data[v.round]
          }
        end
      end
    end
  end
end
