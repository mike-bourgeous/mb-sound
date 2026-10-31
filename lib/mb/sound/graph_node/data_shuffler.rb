module MB
  module Sound
    module GraphNode
      # Seamlessly plays samples in a random order over and over.
      class DataShuffler
        include GraphNode
        # (draws a new order as it plays, caught up by sleepers:
        # #catch_up_shuffle)
        node_traits memory: :short, random: :catch_up_shuffle, fresh: 'its shuffled blocks and random stream (not moved yet)'

        # TODO: should the data be resampled if we get a new sample rate?
        attr_accessor :sample_rate

        # The seed of the shuffle order (see #initialize).
        attr_reader :seed

        # Creates a shuffling source with the given Array of Numo::NArray sound
        # samples.  The order comes from its own Random started from +seed+
        # (an Integer; a seed drawn from MB::Sound.next_seed by default, so
        # MB::Sound.seed or RANDOM_SEED repeat it; before fixes-13 it used
        # Ruby's global Random, so renders differed every run).
        def initialize(data, sample_rate: 48000, seed: nil)
          # TODO: 2D NArray?
          raise 'Data must be an Array of Numo::NArray' unless data.is_a?(Array) && data.length > 0 && data.all?(Numo::NArray)

          # TODO: allow changing the data?  take data from a live stream of audio?
          # TODO: quickfade edges of shuffled blocks?  use overlapping windows?  how can we introduce overlapping windows into the node graph when there are IIR filters?
          @seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
          @rng = Random.new(@seed)
          @data = data.map(&:dup)
          @queue = @data.shuffle(random: @rng)
          @sample_rate = sample_rate

          # At least 16k buffer overhead allowing #sample +count+ to be up to 16k.
          @cbuf = MB::Sound::CircularBuffer.new(buffer_size: MB::M.max(@data.map(&:length).max + 16000, 48000))
        end

        # Returns +count+ frames from the queue of shuffled sound clips.
        def sample(count)
          while @cbuf.length < count
            @queue = @data.shuffle(random: @rng) if @queue.empty?
            @cbuf.write(@queue.shift)
          end

          @cbuf.read(count)
        end

        # NodeTraits' catch-up: plays (and drops) +frames+ samples, so a
        # voice that slept goes on with the clips and orders it would have
        # drawn awake.
        def catch_up_shuffle(frames)
          sample(frames)
          nil
        end
      end
    end
  end
end
