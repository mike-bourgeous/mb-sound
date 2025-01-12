module MB
  module Sound
    class Filter
      # A parallel set of filters, all fed the same input, with the outputs
      # summed.
      class FilterSum < Filter
        # Initializes a filter sum with the given filters.  All filters receive
        # the original input, and are added to produce the final output.
        def initialize(*filters)
          filters = filters[0] if filters.length == 1 && filters[0].is_a?(Array)
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

        # Returns the sample rate of the first filter that has a sample rate.
        def rate
          @filters.each do |f|
            begin
              return f.rate if f.respond_to?(:rate)
            rescue NotImplementedError
            end
          end

          raise NotImplementedError, 'No filter in the chain has a sample rate'
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
