module MB
  module Sound
    module GraphNode
      # A source of zeros for a fixed number of +seconds+, then the end of the
      # stream (a short last buffer, then nil).  Oscillators and constants
      # play forever, so this is how graphs append a finite tail, e.g. to let
      # a reverb ring out after its input ends:
      #
      #     input.and_then(MB::Sound.silence(2)).reverb(:hall)
      #
      # Created with GenerationMethods#silence.
      class Silence
        include GraphNode
        include SampleRateHelper

        # The length as given: seconds (Numeric), a Length (e.g. 480.samples),
        # or a Duration (converted at the current tempo).
        attr_reader :length

        def initialize(length, sample_rate: 48000)
          fixed = length.is_a?(Numeric) || (length.is_a?(MB::Sound::Length) && length.fixed?)
          raise ArgumentError, "Silence needs a length >= 0: seconds or a Length (got #{length.inspect})" unless fixed && length.to_r >= 0

          @length = length
          @samples_unit = length.is_a?(MB::Sound::Length::Samples)
          @sample_rate = sample_rate.to_f
          @remaining = MB::Sound::Length.samples(length, sample_rate: @sample_rate).round
          @buf = nil
          @node_type_name = 'Silence'
        end

        def sample(count)
          return nil if @remaining <= 0

          count = @remaining if count > @remaining
          @remaining -= count
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          @buf.fill(0)
        end

        # The length in seconds at the current sample rate.
        def seconds
          MB::Sound::Length.seconds(@length, sample_rate: @sample_rate)
        end

        # Changes the sample rate, keeping the remaining length in seconds (a
        # length in samples keeps its sample count).
        def sample_rate=(rate)
          @remaining = (@remaining * rate.to_f / @sample_rate).round unless @samples_unit
          super
        end

        def sources
          {}
        end
      end
    end
  end
end
