require 'set'

module MB
  module Sound
    class Filter
      # A linear chain of filters, with the output of one applied to the input of
      # the next.
      class FilterChain < FilterSet
        class FilterDuplicationError < RuntimeError; end

        # Initializes a filter chain with the given filters.  Filters are applied
        # first-to-last/left-to-right, so the first filter at the left receives
        # the original input, and the last filter produces the final output.
        #
        # Individual filters may be a Hash of the form { filter: f, inputs: {
        # name: src } } where src is a GraphNode, Numo::NArray, or Numeric, to
        # control that named parameter on the filter's #dynamic_process method.
        def initialize(*filters)
          super(sample_rate: nil, filters: filters, inputs: [])
        end

        # Processes +data+ through each filter in the chain.  Returns the final
        # sample buffer, or nil if any filters returned nil.
        def process(data)
          acc = call_filter(0, data)
          for idx in 1...@filters.length
            acc = call_filter(idx, acc)
            return nil if acc.nil?
          end
          acc
        end

        # Resets all underlying filters to the given value, if they all support
        # #reset.  Each later filter in the chain receives the result of the
        # previous filter's #reset.
        def reset(value)
          raise 'Not all filters support #reset' unless @filters.all? { |f| f.respond_to?(:reset) }

          @filters.reduce(value) { |v, f| f.reset(v) }
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

        # Appends another filter to this filter chain.  Building up a filter
        # chain this way is something like O(n^2), as every filter is checked
        # for duplication and cycles.  Raises an error if a cycle would be
        # created or a filter is already in the chain.
        #
        # This method tries to detect duplication and cycles, but cannot
        # prevent all scenarios where a filter would end up in multiple chains.
        # Filters are not designed to handle being used in more than one
        # context as they contain internal state, so this should be avoided.
        # That is, a filter of any type should be used directly in only one
        # place, or it should be added to only one chain.
        def chain(next_filter)
          raise FilterDuplicationError, 'Cannot add a filter that is already in a chain to that chain again' if has_filter?(next_filter)
          raise FilterDuplicationError, 'Cannot add a chain to another chain that already contains it' if next_filter.has_filter?(self)

          filters = @filters + [next_filter]

          check_for_cycle

          @filters = filters.freeze

          self
        end
      end
    end
  end
end
