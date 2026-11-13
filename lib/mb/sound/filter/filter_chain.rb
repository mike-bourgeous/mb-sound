require 'set'

module MB
  module Sound
    class Filter
      # A linear chain of filters, with the output of one applied to the input of
      # the next.  (FilterSet, its base class shared with FilterSum, was folded
      # in when filterbank-1 removed FilterSum.)
      class FilterChain < Filter
        class FilterDuplicationError < RuntimeError; end

        node_traits memory: :short

        class FilterCycleError < RuntimeError; end
        class FilterSampleRateError < RuntimeError; end

        class NoFiltersGivenError < ArgumentError
          def initialize(msg = nil)
            super(['No filters were given', msg].compact.join(': '))
          end
        end

        attr_reader :sample_rate, :filters

        # Initializes a filter chain with the given filters.  Filters are applied
        # first-to-last/left-to-right, so the first filter at the left receives
        # the original input, and the last filter produces the final output.
        #
        # Individual filters may be a Hash of the form { filter: f, inputs: {
        # name: src } } where src is a GraphNode, Numo::NArray, or Numeric, to
        # control that named parameter on the filter's #dynamic_process method.
        def initialize(*filters)
          filters = filters[0] if filters.length == 1 && filters[0].is_a?(Array)
          raise NoFiltersGivenError if filters.nil? || filters.empty?

          @filters = []
          @inputs = []

          filters.each_with_index do |f, idx|
            case f
            when Hash
              @filters << f.fetch(:filter)
              @inputs[idx] = f.fetch(:inputs)

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
                raise FilterSampleRateError, "Filter #{f} at index #{idx} has different sample rate #{f.sample_rate.inspect} (expecting #{@sample_rate})"
              end
            end
          end

          check_for_cycle

          @inputs.map!.with_index { |inp, idx|
            inp.map { |k, v|
              [k, SampleWrapper.sample_or_narray(v, filter: @filters[idx], field: k, sample_rate: @sample_rate)]
            }.to_h
          }

          @filters.freeze
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

        # Sets the sample rate of all filters, if they support changing it.
        def sample_rate=(rate)
          raise 'Not all filters support #sample_rate=' unless @filters.all? { |f| f.respond_to?(:sample_rate=) }

          @sample_rate = rate.to_f
          @filters.each do |f|
            f.sample_rate = @sample_rate
          end

          self
        end
        alias at_rate sample_rate=

        # Returns true if this FilterChain, or any nested FilterChain contained
        # directly within it, contains (or is) the given +filter+.  This method
        # will not work if a filter cycle is created despite the cycle
        # detection in the constructor.
        def has_filter?(filter)
          filter.equal?(self) ||
            @filters.include?(filter) ||
            @filters.select { |f| f.is_a?(FilterChain) }.any? { |f| f.has_filter?(filter) }
        end


        # Processes +data+ through each filter in the chain.  Returns the final
        # sample buffer, or nil if any filters returned nil.
        def process(data)
          acc = call_filter(0, data)
          idx = 0
          while (idx += 1) < @filters.length # (not `for` over a Range: a Range a call)
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

        private

        # For internal use.  Processes +data+ through the filter at index
        # +idx+, sampling data from extra inputs if given.
        #
        # Returns nil if any of the extra inputs returned nil.
        def call_filter(idx, data)
          SampleWrapper.call_filter(@filters[idx], data, @inputs[idx], scratch: ((@sampled_inputs ||= [])[idx] ||= {}))
        end

        # Raises an error if this filter set has a cycle or duplicated filters.
        def check_for_cycle(filters = @filters)
          traversed = {}

          chains = [[self, filters]]

          traversed[self] = { idx: -1, from: self }

          chains.each do |c, flist|
            flist.each_with_index do |f, idx|
              if seen = traversed[f]
                raise FilterCycleError, "Filter #{f} at position #{idx} within #{c} was already seen at index #{seen[:idx]} within #{seen[:from]}"
              end

              traversed[f] = { idx: idx, from: c }

              chains << [f, f.filters] if f.is_a?(FilterChain) && idx >= 0
            end
          end
        end
      end
    end
  end
end
