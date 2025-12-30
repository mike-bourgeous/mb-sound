module MB
  module Sound
    class Filter
      # A parallel set of filters, all fed the same input, with the outputs
      # summed.
      class FilterSum < FilterSet
        # Initializes a filter sum with the given filters.  All filters receive
        # the original input, and are added to produce the final output.
        #
        # If any filter is a Hash with :filter and :inputs keys, with :inputs a
        # Hash from input Symbol to a GraphNode, then the filter's
        # #dynamic_process method is called instead of #process, with the
        # result of sampling the given inputs.  This allows realtime control of
        # filter parameters on e.g. a cookbook filter.
        def initialize(*filters)
          super(sample_rate: nil, filters: filters, inputs: [])
          @acc = nil
        end

        # Processes the given sequence of samples (the array index is time)
        # through all filters, adding the output of each filter at each time
        # index.  Returns nil if any filters returned nil or their extra inputs
        # returned nil.
        def process(data)
          data.not_inplace!

          # TODO: use buffer helper?
          if @acc.nil? || @acc.length != data.length || @acc.class != data.class
            @acc = data.class.zeros(data.length)
          else
            @acc.fill(0)
          end

          for idx in 0...@filters.length
            result = call_filter(idx, data).not_inplace!
            return nil if result.nil?
            @acc = @acc.inplace + result
          end

          @acc.not_inplace!
        end

        # Returns the summed responses of all filters.
        def response(omega)
          raise 'Not all filters support #response' unless @filters.all? { |f| f.respond_to?(:response) }

          @filters.reduce(0.0) { |acc, f|
            acc + f.response(omega)
          }
        end

        # Resets all filters to the given steady state +value+.  Raises an
        # error if any filters do not support #reset.
        def reset(value = 0)
          raise 'Not all filters support #reset' unless @filters.all? { |f| f.respond_to?(:reset) }

          @filters.each do |f|
            f.reset(value)
          end
        end
      end
    end
  end
end
