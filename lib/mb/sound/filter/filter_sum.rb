module MB
  module Sound
    class Filter
      # A parallel set of filters, all fed the same input, with the outputs
      # summed.
      class FilterSum < Filter
        # Initializes a filter sum with the given filters.  All filters receive
        # the original input, and are added to produce the final output.
        def initialize(*filters)
          @filters = filters
        end

        # Processes the given sequence of samples (the array index is time)
        # through all filters, adding the output of each filter at each time
        # index.
        def process(samples)
          @filters.map { |f|
            f.process(samples)
          }.reduce { |acc, d|
            acc ? acc + d.not_inplace! : d.clone.inplace!
          }.not_inplace!
        end

        # Returns the summed responses of all filters.
        def response(omega)
          raise 'Not all filters support #response' unless @filters.all? { |f| f.respond_to?(:response) }

          @filters.reduce(0.0) { |acc, f|
            acc + f.response(omega)
          }
        end
      end
    end
  end
end
