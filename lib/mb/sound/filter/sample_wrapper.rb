require 'forwardable'

module MB
  module Sound
    class Filter
      # Provides a #sample method that processes another #sample source through
      # a Filter.  It's easiest to use the MB::Sound::Filter#wrap method or the
      # MB::Sound::GraphNode#filter method to create a sample wrapper.
      #
      # Example:
      #     500.hz.lowpass.wrap(123.hz.saw)
      #     # or
      #     123.hz.saw.filter(500.hz.lowpass)
      class SampleWrapper
        extend Forwardable
        include MB::Sound::GraphNode
        include MB::Sound::GraphNode::SampleRateHelper

        class WrapperArgumentError < ArgumentError
          def initialize(msg = nil, field: nil, source: nil)
            msg ||= 'Pass a Numeric, a Numo::NArray, or a non-Array object that responds to :sample, such as Tone or IOInput'
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
          @source = source.get_sampler
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

          # Set while sampling (here so every wrapper has one instance
          # variable layout; see GraphNode::IvarPreset)
          @ringing = nil
          @frozen_copy = nil
          @own_buf = nil
          @sampled_inputs = nil

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
        #
        # Filters with a #ring_out method (Filter::Delay) ring out after the
        # source ends (returns nil, or a short buffer): the wrapper stops
        # sampling the source and returns the filter's tail until it ends.
        def sample(count)
          return @base_filter.ring_out(count) if @ringing

          buf = @source.sample(count)

          # FIXME: FFMPEGInput -> SampleWrapper crackles and doesn't filter,
          # but FFMPEGInput -> Mixer -> SampleWrapper is fine.
          # FIXME: maybe related to resampling issues from ffmpeginput??

          # TODO: Maybe this nil/empty/short handling could be consolidated?
          if buf.nil? || buf.empty?
            return nil unless rings_out?

            @ringing = true
            return @base_filter.ring_out(count)
          end

          short = buf.length < count && rings_out?

          if @in_place
            buf = (@frozen_copy ||= GraphNode::FrozenCopy.new).copy(buf) if buf.frozen? # a shared buffer (see Tee)
            buf.inplace!
          elsif buf.is_a?(Numo::SFloat) && (@base_filter.is_a?(SVF) || (@base_filter.is_a?(FilterChain) && @base_filter.filters.first.is_a?(SVF)))
            # SVFs filter an inplace SFloat in place: into a reused buffer
            # of the wrapper's own, instead of a new output each buffer
            # (the same values; the source's buffer stays untouched)
            @own_buf = Numo::SFloat.zeros(buf.length) if @own_buf.nil? || @own_buf.length != buf.length
            buf = MB::Sound::FastArithmetic.copy(@own_buf, buf)&.inplace! || buf
          end
          buf = SampleWrapper.call_filter(@base_filter, buf, @inputs, scratch: (@sampled_inputs ||= {}))
          buf&.not_inplace!
          return buf unless short && buf

          # The source's last (short) buffer: the tail starts right after it
          @ringing = true
          tail = @base_filter.ring_out(count - buf.length)
          tail ? buf.concatenate(tail) : buf
        end

        # True if the filter rings out after the source ends (see #sample).
        def rings_out?
          @inputs.empty? && @base_filter.respond_to?(:ring_out) && @base_filter.rings_out?
        end

        # Feedback loops (GraphNode::FeedbackLoop, Plan::Loop): a delay
        # (Filter::Delay with no feedback of its own, wet 1, dry 0) reads its
        # delay line once per sample before the sample's write, and an SVF
        # filters one sample at a time.  Other filters have no loop ops.
        def loop_describe(p)
          case @base_filter
          when MB::Sound::Filter::Delay
            d = @base_filter
            unless d.wet == 1 && d.dry == 0
              raise Plan::Unsupported.new(self, 'a delay inside a feedback loop takes no wet: or dry: of its own (build them into the loop)')
            end

            ring = Plan::Loop::Ring.new(self)
            v = p.delay_read(ring)
            p.defer(ring, @source)
            v

          when MB::Sound::Filter::SVF
            f = @base_filter
            gain = @inputs[:gain] || (f.gain || 1.0)
            p.svf(f, p[@source], cutoff: p[@inputs.fetch(:cutoff)], quality: p[@inputs.fetch(:quality)], gain: p[gain])

          when MB::Sound::Filter::Cookbook
            # A direct form biquad (`structure: :biquad`), per sample as its
            # dynamic kernel (Plan::Loop::Op::Biquad)
            if (why = plan_unsupported_reason)
              raise Plan::Unsupported.new(self, why)
            end
            p.biquad(@base_filter, p[@source], cutoff: p[@inputs.fetch(:cutoff)], quality: p[@inputs.fetch(:quality)])

          else
            raise Plan::Unsupported.new(self, "#{@base_filter.class.name.sub('MB::Sound::', '')} has no loop ops (delays and SVF and biquad filters run inside feedback loops)")
          end
        end

        include Plan::Describable

        # Plan layer (see Plan::Describable): SVF filters with their cutoff,
        # quality, and gain inputs (Plan::Op::FilterSvf), cookbook biquads,
        # and GraphNode#smooth (Filter::Smooth, Plan::Op::Smooth).
        def plan_describe(p)
          f = @base_filter
          case f
          when MB::Sound::Filter::Smooth
            reset = @inputs[:reset]
            p.smooth(p[@source], f.smoother, NO_JUMPS, reset: reset && p[reset])
          when MB::Sound::Filter::SVF
            gain_node = @inputs[:gain]
            gain = gain_node ? p[gain_node] : p.const(f.gain || 1.0)
            p.filter_svf(f, p[@source], cutoff: p[@inputs.fetch(:cutoff)], quality: p[@inputs.fetch(:quality)],
                         gain: gain, gain_input: !gain_node.nil?)
          when MB::Sound::Filter::Cookbook
            p.filter_biquad(f, p[@source], cutoff: p[@inputs.fetch(:cutoff)], quality: p[@inputs.fetch(:quality)])
          else
            raise Plan::Unsupported.new(self, plan_unsupported_reason)
          end
        end

        # Filter::Smooth's jump offsets in plans (none: resets come from the
        # reset input).
        NO_JUMPS = [].freeze

        def plan_unsupported_reason
          case @base_filter
          when MB::Sound::Filter::Smooth
            return 'smoothing with inputs other than reset' unless (@inputs.keys - [:reset]).empty?

            nil
          when MB::Sound::Filter::SVF
            return 'an SVF without cutoff and quality inputs' unless @inputs.key?(:cutoff) && @inputs.key?(:quality)
            return 'an SVF with inputs other than cutoff, quality, and gain' unless (@inputs.keys - [:cutoff, :quality, :gain]).empty?

            nil
          when MB::Sound::Filter::Cookbook
            return 'a cookbook filter without cutoff and quality inputs' unless @inputs.keys.sort == [:cutoff, :quality]
            return 'a cookbook filter type without a C kernel' unless MB::Sound::Filter::Cookbook::FILTER_TYPE_IDS.key?(@base_filter.filter_type)

            nil
          else
            "a #{@base_filter.class.name.sub('MB::Sound::', '')} filter"
          end
        end

        # Ivars of Filter::Cookbook that its dynamic kernel changes.
        PLAN_BIQUAD_IVARS = [:@omega, :@b0, :@b1, :@b2, :@a1, :@a2, :@x1, :@x2, :@y1, :@y2, :@quality, :@center_frequency, :@cutoff].freeze

        def plan_snapshot
          SampleWrapper.filter_state(@base_filter)
        end

        def plan_restore(snapshot)
          SampleWrapper.restore_filter_state(@base_filter, snapshot) if snapshot
        end

        # The running state of filter +f+ as plain values (a cookbook
        # biquad's, an SVF's, or every filter's of a FilterChain: `peq`
        # bands, since sound-design-2's Session::Carry), or nil for other
        # filters.
        def self.filter_state(f)
          case f
          when MB::Sound::Filter::Cookbook then PLAN_BIQUAD_IVARS.map { |v| f.instance_variable_get(v) }
          when MB::Sound::Filter::SVF then [f.instance_variable_get(:@state).dup, f.cutoff, f.quality, f.gain]
          when MB::Sound::Filter::Smooth then [:smooth, f.smoother.plan_snapshot]
          when MB::Sound::Filter::FilterChain
            states = f.filters.map { |x| filter_state(x) }
            states.include?(nil) ? nil : [:chain, states]
          end
        end

        # True if .filter_state keeps filter +f+'s state.
        def self.filter_state?(f)
          case f
          when MB::Sound::Filter::Cookbook, MB::Sound::Filter::SVF, MB::Sound::Filter::Smooth then true
          when MB::Sound::Filter::FilterChain then f.filters.all? { |x| filter_state?(x) }
          else false
          end
        end

        # Puts back a .filter_state.
        def self.restore_filter_state(f, snapshot)
          case f
          when MB::Sound::Filter::Cookbook
            PLAN_BIQUAD_IVARS.each_with_index { |v, i| f.instance_variable_set(v, snapshot[i]) }
          when MB::Sound::Filter::FilterChain
            f.filters.zip(snapshot[1]).each { |x, st| restore_filter_state(x, st) }
          when MB::Sound::Filter::Smooth
            f.smoother.plan_restore(snapshot[1])
          else
            state, cutoff, quality, gain = snapshot
            f.instance_variable_get(:@state).replace(state)
            f.instance_variable_set(:@cutoff, cutoff)
            f.instance_variable_set(:@quality, quality)
            f.instance_variable_set(:@gain, gain)
          end
        end

        # See GraphNode#sources.
        # Settings for the response preview (Plot::Panels): the filter's
        # structure (:svf or :cookbook; nil for others), type, sample rate,
        # and cutoff, quality, and gain, with constant inputs applied
        # (cutoff: 800 as the filter will play it).
        def preview_data
          f = @base_filter
          structure = f.is_a?(Filter::SVF) ? :svf : (f.is_a?(Filter::Cookbook) ? :cookbook : nil)
          return nil unless structure

          # Constant and knob inputs at their current values
          set = param_info.transform_values(&:value).select { |_, v| v.is_a?(Numeric) }
          cutoff = (set[:cutoff] || f.cutoff).to_f
          quality = (set[:quality] || f.quality)&.to_f
          {
            structure: structure, filter_type: f.filter_type, sample_rate: @sample_rate.to_f,
            cutoff: cutoff, quality: quality,
            gain: structure == :svf ? (set[:gain] || f.gain)&.to_f : nil,
            db_gain: structure == :cookbook ? f.db_gain&.to_f : nil,
            label: "#{f.filter_type} #{cutoff.round(1)} Hz#{" Q #{quality.round(3)}" if quality}",
          }
        end

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
        def respond_to?(m, include_all = false)
          super || @base_filter.respond_to?(m, include_all)
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
        #
        # +scratch+ is an optional Hash reused by the caller for the sampled
        # inputs (otherwise a new one per call).
        def self.call_filter(filter, data, inputs, scratch: nil)
          return nil if data.nil? || data.empty?

          if inputs && !inputs.empty?
            sampled = scratch || {}
            sampled.clear if sampled.length != inputs.length
            inputs.each do |name, inp|
              sampled[name] = inp.sample(data.length)
            end

            # Handle end-of-stream from inputs
            minlen = maxlen = data.length
            sampled.each_value do |i|
              return nil if i.nil? || i.empty?
              minlen = i.length if i.length < minlen
              maxlen = i.length if i.length > maxlen
            end

            # Handle short reads from inputs
            if minlen != maxlen
              data = data[0...minlen]
              sampled.each_key do |name|
                v = sampled[name]
                sampled[name] = v[0...minlen] if v.length != minlen
              end
            end

            filter.dynamic_process(data, **sampled)

          else
            filter.process(data)
          end
        end
      end
    end
  end
end
