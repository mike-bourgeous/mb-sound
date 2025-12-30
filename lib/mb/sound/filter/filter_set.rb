module MB
  module Sound
    class Filter
      # Subclass for multi-filter classes like FilterChain and FilterSum with
      # helpers for managing extra inputs, calling multiple filters, etc.
      class FilterSet < Filter
        class FilterCycleError < RuntimeError; end
        class FilterSampleRateError < RuntimeError; end

        class NoFiltersGivenError < ArgumentError
          def initialize(msg = nil)
            super(['No filters were given', msg].compact.join(': '))
          end
        end

        attr_reader :sample_rate, :filters

        # Initializes filter and input list.  Individual filters may also be a
        # Hash of { filter: f, inputs: { name: src } } to specify inputs.
        #
        # +:sample_rate+ - Sample rate, or nil to use the first filter's rate.
        # +:filters+ - The Array of Filters or filter-describing Hashes.
        # +:inputs+ - An Array with indices matching the filter list,
        #             containing Hashes with named GraphNode, Numo::NArray, or
        #             Numeric sources for dynamic control of filter parameters.
        def initialize(sample_rate:, filters:, inputs:)
          filters = filters[0] if filters.is_a?(Array) && filters.length == 1 && filters[0].is_a?(Array)
          inputs ||= []

          raise NoFiltersGivenError if filters.nil? || filters.empty?

          @filters = []
          @inputs = inputs

          filters.each_with_index do |f, idx|
            case f
            when Hash
              raise "Inputs for filter #{idx} specified as both Hash and inputs Array" if @inputs[idx]

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

          @sample_rate = sample_rate&.to_f
          @sample_rate ||= @filters.first.sample_rate
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

          @inputs.map! { |inp|
            inp.map { |k, v|
              [k, SampleWrapper.sample_or_narray(v, field: k, unit: nil, si: nil, range: nil, sample_rate: @sample_rate)]
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

        # Returns true if this FilterSet, or any nested FilterSet contained
        # directly within it, contains (or is) the given +filter+.  This method
        # will not work if a filter cycle is created despite the cycle
        # detection in the constructor.
        def has_filter?(filter)
          filter.equal?(self) ||
            @filters.include?(filter) ||
            @filters.select { |f| f.is_a?(FilterSet) }.any? { |f| f.has_filter?(filter) }
        end

        private

        # For internal use.  Processes +data+ through the filter at index
        # +idx+, sampling data from extra inputs if given.
        #
        # Returns nil if any of the extra inputs returned nil.
        def call_filter(idx, data)
          f = @filters[idx]
          if @inputs[idx]
            inputs = @inputs[idx].transform_values { |inp| inp.sample(data.length) }

            # Handle end-of-stream from inputs
            return nil if inputs.any?(&:nil?)

            # Handle short reads from inputs
            len = [data.length, *inputs.values.map(&:length)].min
            if len < data.length
              data = data[0...len]
              inputs = inputs.transform_values { |v| v.length < len ? v[0...len] : v }
            end

            f.dynamic_process(data, **inputs)
          else
            f.process(data)
          end
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

              chains << [f, f.filters] if f.is_a?(FilterSet) && idx >= 0
            end
          end
        end
      end
    end
  end
end
