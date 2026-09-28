module MB
  module Sound
    module GraphNode
      # Passes its source through until the source ends (e.g. a sound file
      # runs out), then outputs silence forever, so effects after it (delays,
      # reverbs) can ring out.  #ended? tells whoever is playing the graph
      # (e.g. the script runner in ScriptingMethods) that the source is done,
      # so it can stop once the output goes quiet.
      #
      # Created with GraphNode#ringdown.
      #
      # Example (bin/sound.rb):
      #     bg file_input('sounds/drums.flac').ringdown.delay(0.25, feedback: -6.db, dry: 1)
      class Ringdown
        include GraphNode
        include SampleRateHelper

        # The source node.
        attr_reader :source

        def initialize(source)
          @source = source.get_sampler
          @sample_rate = @source.sample_rate
          @ended = false
          @buf = nil
        end

        # True once the source has ended.
        def ended?
          @ended
        end

        # Returns +count+ samples of the source, padded with zeros once it
        # ends.
        def sample(count)
          if @ended
            @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
            return @buf.fill(0)
          end

          data = @source.sample(count)
          if data.nil? || data.length < count
            @ended = true
            padded = (data ? data.class : Numo::SFloat).zeros(count)
            padded[0...data.length] = data if data && data.length > 0
            return padded
          end

          data
        end

        def sources
          { input: @source }
        end
      end
    end
  end
end
