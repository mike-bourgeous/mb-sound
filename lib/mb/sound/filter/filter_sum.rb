module MB
  module Sound
    class Filter
      # A parallel set of filters, all fed the same input, with the outputs
      # summed.
      #
      # TODO: maybe remove this?  for implementing something like a multiband
      # compressor we'd just build parallel graph node chains
      class FilterSum < Filter
        attr_reader :sample_rate

        # Initializes a filter sum with the given filters.  All filters receive
        # the original input, and are added to produce the final output.
        def initialize(*filters)
          filters = filters[0] if filters.length == 1 && filters[0].is_a?(Array)
          @filters = filters

          @sample_rate = @filters.first.sample_rate
          @filters[1..-1].each.with_index do |f, idx|
            if f.sample_rate != @sample_rate
              if f.respond_to?(:sample_rate=)
                f.sample_rate = @sample_rate
              else
                raise "Filter #{f} at index #{idx} has different sample rate #{f.sample_rate.inspect} (expecting #{@sample_rate})"
              end
            end
          end
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

        # Resets all filters to the given steady state +value+.  Raises an
        # error if any filters do not support #reset.
        def reset(value = 0)
          raise 'Not all filters support #reset' unless @filters.all? { |f| f.respond_to?(:reset) }
          @filters.each do |f|
            f.reset(value)
          end
        end

        # Sets the sample rate of all filters, if they support changing it.
        def sample_rate=(rate)
          raise 'Not all filters support #sample_rate=' unless @filters.all? { |f| f.respond_to?(:sample_rate=) }

          @sample_rate = rate.to_f
          @filters.each do |f|
            f.sample_rate = @sample_rate
          end
        end
        alias at_rate sample_rate=
      end
    end
  end
end
