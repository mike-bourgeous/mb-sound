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

        attr_reader :base_filter

        # Initializes a sample wrapper for the given +filter+ (which must
        # provide a #process method) and +source+ (which must provide a #sample
        # method).
        #
        # Set +:in_place+ to false if problems occur due to in-place filter
        # processing.
        def initialize(filter, source, in_place: true)
          @base_filter = filter
          @source = source
          @in_place = in_place

          if @base_filter.respond_to?(:sample_rate) && @base_filter.sample_rate != source.sample_rate
            if @base_filter.respond_to?(:sample_rate=)
              @base_filter.sample_rate = source.sample_rate
            else
              raise "Filter sample rate #{@base_filter.sample_rate} differs from source sample rate #{source.sample_rate}"
            end
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
          # TODO: Drain FIR filters and delays after a source returns nil
          return nil if buf.nil? || buf.empty?
          buf = MB::M.zpad(buf, count) if buf.length < count

          buf.inplace! if @in_place
          buf = @base_filter.process(buf)
          buf&.not_inplace!
        end

        # See GraphNode#sources.
        def sources
          if @base_filter.respond_to?(:sources)
            # + instead of | because duplicate connections should be shown
            [@source] + @base_filter.sources
          else
            [@source]
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

        # Pass other methods through to the wrapped object.
        def method_missing(m, *a)
          @base_filter.send(m, *a)
        end
      end
    end
  end
end
