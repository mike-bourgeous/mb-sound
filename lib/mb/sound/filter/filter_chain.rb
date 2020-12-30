module MB
  module Sound
    class Filter
      # A linear chain of filters, with the output of one applied to the input of
      # the next.
      class FilterChain < Filter
        # Initializes a filter chain with the given filters.  Filters are applied
        # first-to-last/left-to-right, so the first filter at the left receives
        # the original input, and the last filter produces the final output.
        def initialize(*filters)
          @filters = filters
        end

        # Processes +samples+ through each filter in the chain.  Returns the
        # final sample buffer.
        def process(samples)
          @filters.reduce(samples) { |input, f| f.process(input) }
        end

        # Processes +samples+ through the weighted_process method of each filter
        # in the chain.  Returns the final sample buffer.
        def weighted_process(samples, strength)
          @filters.reduce(samples) { |input, f| f.weighted_process(input, strength) }
        end

        # Resets all underlying filters to the given value, if they all support
        # #reset.
        def reset(value)
          raise 'Not all filters support #reset' unless @filters.all? { |f| f.respond_to?(:reset) }

          @filters.each { |f| f.reset(value) }
        end

        # Computes the combined response of all filters at the given angular
        # frequency on the unit circle, by multiplying the responses of all of
        # the filters.  Raises an error if any underlying filters do not support
        # the #response method.
        def response(omega)
          raise 'Not all filters support #response' unless @filters.all? { |f| f.respond_to?(:response) }

          @filters.reduce(1.0) { |acc, f| acc * f.response(omega) }
        end

        # Computes the combined z-plane response of all filters by multiplying
        # the responses of all filters, at the given complex Z-plane coordinate.
        # Raises an error if any underlying filters do not support the
        # #z_response method.
        def z_response(z)
          raise 'Not all filters support #z_response' unless @filters.all? { |f| f.respond_to?(:z_response) }

          @filters.reduce(1.0) { |acc, f| acc * f.z_response(z) }
        end

        # Returns a Hash containing the combined set of z-plane :poles and :zeros
        # from all filters, if all underlying filters respond to #polezero.
        def polezero
          raise 'Not all filters support #polezero' unless @filters.all? { |f| f.respond_to?(:polezero) }

          @filters.reduce({ poles: [], zeros: [] }) { |acc, f|
            fpz = f.polezero
            acc[:poles] += fpz[:poles]
            acc[:zeros] += fpz[:zeros]
            acc
          }
        end
      end
    end
  end
end
