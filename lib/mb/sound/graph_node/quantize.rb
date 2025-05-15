module MB
  module Sound
    module GraphNode
      class Quantize
        include GraphNode

        # Sample rate (does not affect behavior of this node).
        attr_reader :sample_rate

        # Quantization increment (e.g. 0.1 to quantize to steps of 0.1).
        attr_reader :increment

        # Creates a quantization graph node with the given +:upstream+ node and
        # quantization +:increment+ which may be a Number or another GraphNode.
        # The sample rate for this node will be taken from the upstream node.
        #
        # An +:increment+ of zero, NaN, or Infinity means no quantization.  The
        # sign (positive or negative) of the +:increment+ does not matter.
        def initialize(upstream:, increment:)
          raise 'Upstream must respond to :sample' unless upstream.respond_to?(:sample)
          raise 'Upstream must respond to :sample_rate' unless upstream.respond_to?(:sample_rate)

          @upstream = upstream
          @sample_rate = upstream.sample_rate

          unless increment.is_a?(Numeric) || (increment.respond_to?(:sample) && !increment.is_a?(Array))
          end

          case increment
          when Numeric
            @increment = increment
            @increment = 0 unless @increment.finite? # clear NaN or Infinity

          when GraphNode
            unless increment.sample_rate == upstream.sample_rate
              raise "Increment sample rate #{increment.sample_rate} does not match upstream sample rate #{upstream.sample_rate}"
            end

            @increment = increment

          else
            raise "Increment must be a Numeric or a GraphNode (got #{increment.class})"
          end
        end

        # Requests +count+ samples from the upstream node given to the
        # constructor, quantizes the samples to the increment given to the
        # constructor (or the sample-by-sample increment if the increment is a
        # GraphNode), and returns the result.
        def sample(count)
          data = @upstream.sample(count)
          return nil if data.nil? || data.empty?

          if @increment.respond_to?(:sample)
            inc = @increment.sample(count)
            return nil if inc.nil? || inc.empty?
          else
            inc = @increment
            return data if inc == 0
          end

          if inc.is_a?(Numo::NArray)
            data = data[0...inc.length] if inc.length < data.length
            inc = inc[0...data.length] if data.length < inc.length

            mask = inc.ne(0) & inc.isfinite
            unless mask.all?
              # There are zeros, nans, or infinities, so we need to mask them.
              # FIXME: this only handles zeros, not nans or infinities
              inc = inc.dup + ~mask
              result = (data.dup.inplace / inc).round * inc
              return data * ~mask + result * mask
            end
          end

          (data / inc).round * inc
        end
      end
    end
  end
end
