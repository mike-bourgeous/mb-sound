require 'set'

module MB
  module Sound
    class Filter
      # A linear chain of filters, with the output of one applied to the input of
      # the next.
      class FilterChain < Filter
        class FilterDuplicationError < RuntimeError; end
        class FilterCycleError < RuntimeError; end
        class NoFiltersGivenError < RuntimeError; end
        class FilterSampleRateError < RuntimeError; end

        attr_reader :filters, :sample_rate

        # Initializes a filter chain with the given filters.  Filters are applied
        # first-to-last/left-to-right, so the first filter at the left receives
        # the original input, and the last filter produces the final output.
        def initialize(*filters)
          filters = filters[0] if filters.is_a?(Array) && filters[0].is_a?(Array) && filters.length == 1

          raise NoFiltersGivenError, 'No filters were given' if filters.empty?
          @filters = filters

          check_for_cycle

          # TODO: Maybe merge with code in FilterSum (or remove FilterSum), FilterBank
          @sample_rate = @filters.first.sample_rate
          @filters[1..-1].each.with_index do |f, idx|
            if f.sample_rate != @sample_rate
              if f.respond_to?(:sample_rate=)
                f.sample_rate = @sample_rate
              else
                raise FilterSampleRateError, "Filter #{f} at index #{idx} has sample rate #{f.sample_rate.inspect}; expected #{@sample_rate.inspect}"
              end
            end
          end
        end

        # Changes the sample rate of all filters in this chain to the given new
        # +rate+, if they support changing sample rates.
        def sample_rate=(rate)
          if @filters.all?() { |f| f.respond_to?(:sample_rate=) }
            @filters.each do |f|
              f.sample_rate = rate
            end
          else
            raise "Cannot change sample rate on one or more of #{@filters.map(&:class).uniq.join(', ')}"
          end

          @sample_rate = rate.to_f
        end
        alias at_rate sample_rate=

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
        # chain is something like O(n^2), as every filter is checked for
        # duplication and cycles.  Raises an error if a cycle would be created
        # or a filter is already in the chain.
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

          @filters << next_filter

          begin
            check_for_cycle
          rescue
            @filters.delete_at(-1)
            raise
          end

          self
        end

        # Returns true if this FilterChain, or any nested FilterChain contained
        # within it, contains (or is) the given +filter+.  This method will not
        # work if a filter cycle is created despite the cycle detection in the
        # constructor.
        def has_filter?(filter)
          filter.equal?(self) ||
            @filters.include?(filter) ||
            @filters.select { |f| f.is_a?(FilterChain) }.any? { |f| f.has_filter?(filter) }
        end

        protected

        # Raises an error if this filter chain has a cycle or any duplicated
        # filters.
        def check_for_cycle
          traversed = {}

          chains = [self]

          traversed[self] = { idx: -1, from: self }

          chains.each do |c|
            c.filters.each_with_index do |f, idx|
              if seen = traversed[f]
                raise FilterCycleError, "Filter #{f} at position #{idx} within #{c} was already seen at index #{seen[:idx]} within #{seen[:from]}"
              end

              traversed[f] = { idx: idx, from: c }

              chains << f if f.is_a?(FilterChain) && idx >= 0
            end
          end
        end
      end
    end
  end
end
