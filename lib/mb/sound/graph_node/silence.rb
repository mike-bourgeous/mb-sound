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

        # The length in seconds.
        attr_reader :seconds

        def initialize(seconds, sample_rate: 48000)
          raise ArgumentError, "Silence needs a length in seconds >= 0 (got #{seconds.inspect})" unless seconds.is_a?(Numeric) && seconds >= 0

          @seconds = seconds
          @sample_rate = sample_rate.to_f
          @remaining = (seconds * @sample_rate).round
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

        # Changes the sample rate, keeping the remaining length in seconds.
        def sample_rate=(rate)
          @remaining = (@remaining * rate.to_f / @sample_rate).round
          super
        end

        def sources
          {}
        end
      end
    end
  end
end
