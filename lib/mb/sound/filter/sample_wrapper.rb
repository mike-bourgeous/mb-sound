require 'forwardable'

module MB
  module Sound
    class Filter
      # Provides a #sample method that processes another #sample source through
      # a Filter.  It's easiest to use the MB::Sound::Filter#wrap method or the
      # MB::Sound::GraphNode#filter method to create a sample wrapper.
      #
      # Example:
      #     500.hz.lowpass.wrap(123.hz.ramp)
      #     # or
      #     123.hz.ramp.filter(500.hz.lowpass)
      class SampleWrapper
        extend Forwardable
        include MB::Sound::GraphNode
        include MB::Sound::GraphNode::SampleRateHelper

        class WrapperArgumentError < ArgumentError
          def initialize(msg = nil, field: nil, source: nil)
            msg ||= 'Pass a Numeric, a Numo::NArray, or a non-Array object that responds to :sample, such as Tone, Oscillator, or IOInput'
            msg << " for #{field}" if field
            msg << " (got #{source})" if source
            super(msg)
          end
        end

        attr_reader :base_filter

        # Initializes a sample wrapper for the given +filter+ (which must
        # provide a #process method) and +source+ (which must provide a #sample
        # method).
        #
        # Set +:in_place+ to false if problems occur due to in-place filter
        # processing.
        #
        # The +:inputs+ Hash gives extra nodes to sample from for extra
        # parameters to a filter's #dynamic_process method.
        def initialize(filter, source, in_place: false, inputs: {})
          @node_type_name = "SampleWrapper/#{filter.class.name.rpartition('::').last}: #{filter}"
          @base_filter = filter
          @source = source.get_sampler.named("#{@node_type_name} input")
          @in_place = in_place

          @sample_rate = source.sample_rate
          if @base_filter.respond_to?(:sample_rate) && @base_filter.sample_rate != @sample_rate
            if @base_filter.respond_to?(:sample_rate=)
              @base_filter.sample_rate = @source.sample_rate
            else
              raise "Filter sample rate #{@base_filter.sample_rate} differs from source sample rate #{@source.sample_rate}"
            end
          end

          @inputs = inputs.map { |k, v|
            [k, SampleWrapper.sample_or_narray(v, filter: @base_filter, field: k, sample_rate: @sample_rate)]
          }.to_h

          # TODO: detect and provide defaults for omitted inputs?
          unless @inputs.empty? || @base_filter.respond_to?(:dynamic_process)
            raise 'Cannot provide extra inputs to a filter that does not respond to #dynamic_process'
          end

          # TODO: Maybe there's a better way to propagate default gains and durations?
          if @source.respond_to?(:or_at)
            class << self
              def_delegators :@source, :or_at, :or_for
            end
          end
        end

        # Processes +count+ samples from the source through the filter and
        # returns the result.
        def sample(count)
          buf = @source.sample(count)

          # FIXME: FFMPEGInput -> SampleWrapper crackles and doesn't filter,
          # but FFMPEGInput -> Mixer -> SampleWrapper is fine.

          # TODO: Maybe this nil/empty/short handling could be consolidated?
          # TODO: Drain ring-out from filters and delays after a source returns nil
          return nil if buf.nil? || buf.empty?

          buf.inplace! if @in_place
          buf = SampleWrapper.call_filter(@base_filter, buf, @inputs)
          buf&.not_inplace!
        end

        # See GraphNode#sources.
        def sources
          if @base_filter.respond_to?(:sources)
            {
              input: @source,
              **@inputs,
              **@base_filter.sources
            }
          else
            { input: @source, **@inputs }
          end
        end

        # Returns the sample rate of the filter if it has one, or the source if
        # not.
        def sample_rate
          if @base_filter.respond_to?(:sample_rate)
            @base_filter.sample_rate
          else
            @source.sample_rate
          end
        end

        # Changes the sample rate of the source and filter.
        def sample_rate=(new_rate)
          if @base_filter.respond_to?(:sample_rate)
            raise "Filter #{@base_filter} cannot change sample rate on #{self}" unless @base_filter.respond_to?(:sample_rate=)
            @base_filter.sample_rate = new_rate
          end

          super
        end
        alias at_rate sample_rate=

        # Resets the underlying filter to behave as if it has received the
        # given +value+ for a very long time, if it supports #reset.
        def reset(value = 0)
          if @base_filter.respond_to?(:reset)
            @base_filter.reset(value)
          else
            raise NotImplementedError, "Filter #{@base_filter} does not implement #reset"
          end
        end

        # See GraphNode#to_s
        def to_s
          "#{super} -- #{source_names.join(', ')} -- #{@base_filter}"
        end

        # See GraphNode#to_s_graphviz
        def to_s_graphviz
          info = @base_filter.respond_to?(:to_s_graphviz) ? @base_filter.to_s_graphviz : @base_filter.to_s
          <<~EOF
          #{super}---------------
          #{source_names.join("\n")}
          ---------------
          #{info}
          EOF
        end

        # Claim to support methods the base filter supports as well as our own.
        def respond_to?(m)
          super || @base_filter.respond_to?(m)
        end

        # Pass other methods through to the wrapped object.
        def method_missing(m, *a)
          @base_filter.send(m, *a)
        end

        # If given an object with :sample, returns the object itself.  If
        # given a numeric value, returns an object with a :sample method that
        # returns that value as a constant indefinitely.  If given a
        # Numo::NArray, returns an ArrayInput that wraps it, without looping.
        # Otherwise, raises an error.
        def self.sample_or_narray(v, filter:, field:, sample_rate:)
          case v
          when Numeric
            info = { unit: nil, si: nil, range: nil }

            # Retrieve parameter info from the filter class, if available
            if filter && filter.class.constants.include?(:DYNAMIC_INPUTS)
              parameter = filter.class.const_get(:DYNAMIC_INPUTS)[field]
              info = info.compact.merge(parameter) if parameter
            end

            # Call Procs for dynamic parameter attribute definitions
            # TODO: update these if sample rates change, etc.?
            info = info.transform_values { |v|
              v = v.call(filter) if v.respond_to?(:call)
              v
            }

            MB::Sound::GraphNode::Constant.new(v, sample_rate: sample_rate, **info)

          when Numo::NArray
            MB::Sound::ArrayInput.new(data: [v], sample_rate: sample_rate)

          else
            if v.respond_to?(:sample) && !v.is_a?(Array)
              # TODO: Might need a better way to detect sampleable audio
              # objects, as opposed to Ruby objects with a sample method that
              # returns a random sampling.  Or maybe I should rename all of
              # my sample methods to something else.
              v.get_sampler.tap { |n|
                n.sample_rate = sample_rate if n.sample_rate != sample_rate
              }
            else
              raise WrapperArgumentError.new(field: field, source: v)
            end
          end
        end

        # Calls #process (if no inputs are given) or #dynamic_process (if
        # there are extra inputs) on the given +filter+ with the given +data+
        # and extra +inputs+, handling nil and short reads.
        def self.call_filter(filter, data, inputs)
          return nil if data.nil? || data.empty?

          if inputs && inputs.any?
            inputs = inputs.transform_values { |inp| inp.sample(data.length) }

            # Handle end-of-stream from inputs
            return nil if inputs.values.any? { |i| i.nil? || i.empty? }

            # Handle short reads from inputs
            minlen, maxlen = [data.length, *inputs.values.map(&:length)].minmax
            if minlen != maxlen
              data = data[0...minlen]
              inputs = inputs.transform_values { |v| v.length != minlen ? v[0...minlen] : v }
            end

            filter.dynamic_process(data, **inputs)

          else
            filter.process(data)
          end
        end
      end
    end
  end
end
