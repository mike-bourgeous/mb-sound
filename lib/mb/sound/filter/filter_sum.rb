module MB
  module Sound
    class Filter
      # A parallel set of filters, all fed the same input, with the outputs
      # summed.
      #
      # TODO: merge with FilterBank maybe, and/or extract some helpers for
      # FilterChain/FilterBank/local processing with dynamic_process.
      class FilterSum < Filter
        attr_reader :sample_rate

        # Initializes a filter sum with the given filters.  All filters receive
        # the original input, and are added to produce the final output.
        #
        # If any filter is a Hash with :filter and :inputs keys, with :inputs a
        # Hash from input Symbol to a GraphNode, then the filter's
        # #dynamic_process method is called instead of #process, with the
        # result of sampling the given inputs.  This allows realtime control of
        # filter parameters on e.g. a cookbook filter.
        def initialize(*filters)
          filters = filters[0] if filters.length == 1 && filters[0].is_a?(Array)

          raise 'No filters were given' if filters.empty?

          @filters = []
          @inputs = []
          filters.each_with_index do |f, idx|
            case f
            when Hash
              @filters << f.fetch(:filter)
              @inputs[idx] = f.fetch(:inputs)
              @inputs[idx].transform_values! { |v|
                # TODO: share sample_or_narray method from CookbookWrapper
                v.is_a?(Numeric) ? v.constant : v
              }
            
            else
              @filters << f
            end
          end

          @filters.each_with_index do |f, idx|
            if @inputs[idx]
              unless f.respond_to?(:dynamic_process)
                raise "Filter #{idx}/#{f} with inputs #{@inputs[idx].keys} does not have a #dynamic_process method"
              end
            else
              raise "Filter #{idx}/#{f} does not have a #process method" unless f.respond_to?(:process)
            end
          end

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

        # For GraphNode/SampleWrapper compatibility.  Returns any inputs given
        # to the constructor and any sources reported by individual filters.
        #
        # TODO: maybe I should just get rid of the Filter API entirely and move
        # everything to GraphNode
        def sources
          src_hash = @inputs.flat_map.with_index { |inp, idx|
            next unless inp
            inp.map { |name, src|
              [:"filter_#{idx}_#{name}", src]
            }
          }.compact.to_h

          @filters.each_with_index do |f, idx|
            if f.respond_to?(:sources)
              src_hash.merge!(f.sources.transform_keys { |k| :"filter_#{idx}_#{k}" })
            end
          end

          src_hash
        end

        # Processes the given sequence of samples (the array index is time)
        # through all filters, adding the output of each filter at each time
        # index.
        def process(samples)
          samples.not_inplace!

          @filters.map.with_index { |f, idx|
            if inputs = @inputs[idx]
              f.dynamic_process(samples, **inputs.transform_values { |inp| inp.sample(samples.length) })
            else
              f.process(samples)
            end
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
