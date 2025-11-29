module MB
  module Sound
    module GraphNode
      # Seamlessly plays samples in a random order over and over.
      class DataShuffler
        include GraphNode

        # TODO: should the data be resampled if we get a new sample rate?
        attr_accessor :sample_rate

        # Creates a shuffling source with the given Array of Numo::NArray sound
        # samples.
        def initialize(data, sample_rate: 48000)
          # TODO: 2D NArray?
          raise 'Data must be an Array of Numo::NArray' unless data.is_a?(Array) && data.length > 0 && data.all?(Numo::NArray)

          # TODO: allow changing the data?  take data from a live stream of audio?
          # TODO: quickfade edges of shuffled blocks?  use overlapping windows?  how can we introduce overlapping windows into the node graph when there are IIR filters?
          @data = data.map(&:dup)
          @queue = @data.shuffle
          @sample_rate = sample_rate

          # At least 16k buffer overhead allowing #sample +count+ to be up to 16k.
          @cbuf = MB::Sound::CircularBuffer.new(buffer_size: MB::M.max(@data.map(&:length).max + 16000, 48000))
        end

        # Returns +count+ frames from the queue of shuffled sound clips.
        def sample(count)
          while @cbuf.length < count
            @queue = @data.shuffle if @queue.empty?
            @cbuf.write(@queue.shift)
          end

          @cbuf.read(count)
        end
      end
    end
  end
end
