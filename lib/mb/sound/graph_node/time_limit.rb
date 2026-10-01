module MB
  module Sound
    module GraphNode
      # Passes its source through for a number of seconds, then ends the
      # stream (a short last buffer, then nil), cutting the source off.
      # Ends sooner if the source does.  Oscillators and constants play
      # forever, so this is how to cut a sound off at a fixed time; for a
      # musical ending, use an envelope (e.g. GraphNode#adsr).
      #
      # Created with GraphNode#until.
      #
      # Example (bin/sound.rb):
      #     play 220.hz.ramp.at(-6.db).until(2)
      #     # A triangle cut off mid-cycle, then 0.2 s for the filter to ring
      #     play 50.hz.triangle.until(3).and_then(silence(0.2)).filter(:lowpass, cutoff: 400, quality: 25)
      class TimeLimit
        include GraphNode
        include SampleRateHelper

        # The source node.
        attr_reader :source

        # The length in seconds.
        attr_reader :seconds

        def initialize(source, seconds)
          unless seconds.is_a?(Numeric) && seconds >= 0
            raise ArgumentError, "Give #until a length in seconds >= 0 (got #{seconds.inspect})"
          end

          @source = source.get_sampler
          @seconds = seconds
          @sample_rate = @source.sample_rate.to_f
          @elapsed = 0
          @node_type_name = 'Until'
        end

        # Returns up to +count+ samples of the source, fewer at the end of
        # the time limit, then nil.
        def sample(count)
          remaining = (@seconds * @sample_rate).round - @elapsed
          return nil if remaining <= 0

          count = remaining if count > remaining
          data = @source.sample(count)
          @elapsed += data.length if data
          data
        end

        # Changes the sample rate, keeping the elapsed time in seconds.
        def sample_rate=(rate)
          old_rate = @sample_rate
          super
          @elapsed = (@elapsed * @sample_rate / old_rate).round
          self
        end
        alias at_rate sample_rate=

        def sources
          { input: @source }
        end

        def to_s
          "#{super} -- #{MB::M.sigfigs(@seconds, 4)}s"
        end
      end
    end
  end
end
