require 'forwardable'

module MB
  module Sound
    class Filter
      # Provides a #sample method that processes another #sample source through
      # a Filter.  It's easiest to use the MB::Sound::Filter#wrap method or the
      # MB::Sound::ArithmeticMixin#filter method to create a sample wrapper.
      #
      # Example:
      #     500.hz.lowpass.wrap(123.hz.ramp)
      #     # or
      #     123.hz.ramp.filter(500.hz.lowpass)
      class SampleWrapper
        extend Forwardable
        include MB::Sound::ArithmeticMixin

        # Initializes a sample wrapper for the given +filter+ (which must
        # provide a #process method) and +source+ (which must provide a #sample
        # method).
        #
        # Set +:in_place+ to false if problems occur due to in-place filter
        # processing.
        def initialize(filter, source, in_place: true)
          @filter = filter
          @source = source
          @in_place = in_place

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
          return nil if buf.nil? || buf.empty?
          buf = MB::M.zpad(buf, count) if buf.length < count

          buf.inplace! if @in_place
          buf = @filter.process(buf)
          buf.not_inplace!
        end

        # See ArithmeticMixin#sources.
        def sources
          [@source]
        end
      end
    end
  end
end
