module MB
  module Sound
    module GraphNode
      # Feeds buffers of audio that were rendered elsewhere into a node graph,
      # one output node per channel.  Used by Session to run the mix of every
      # player through a master effects chain (see Session#master).
      #
      # Call #write with each new buffer before sampling the chain.  Every
      # channel returns a copy of its channel of the latest buffer, so graphs
      # may sample a channel more than once and modify what they get.  The
      # chain must ask for the number of frames that was written, or for
      # consecutive pieces of it (a Synth reading its lanes in windows split
      # at its grid; omnibus17, Kez's K10: a bus chain through a Synth
      # raised "asked for 799 samples" with plans off, which fused regions
      # had hidden since fuse-more-1), so nodes that change the sample
      # count (e.g. #resample or #oversample) can't be used downstream.
      #
      # Example:
      #     src = MB::Sound::GraphNode::MixSource.new(channels: 2)
      #     chain = src.outputs.map { |c| c.softclip }
      #     src.write([Numo::SFloat[0.5, 1, 2], Numo::SFloat[0, -1, -2]])
      #     chain.map { |c| c.sample(3) }
      class MixSource
        include MultiOutput

        # One channel of a MixSource.
        class Channel
          extend Forwardable

          include GraphNode
          include NodeOutput

          def_delegators :@owner, :sample_rate, :sources

          # For internal use by MixSource.
          def initialize(owner, index)
            @owner = owner
            @index = index
            @graph_node_name = "Mix channel #{index + 1}"
          end

          # Returns a copy of this channel of the latest buffer given to
          # MixSource#write.  Raises an error if +count+ doesn't match that
          # buffer's length.
          def sample(count)
            @owner.channel_data(@index, count)
          end

          # Raises an error unless +rate+ is the mix's sample rate; a
          # MixSource can't change its rate.
          def sample_rate=(rate)
            @owner.sample_rate = rate
          end
          alias at_rate sample_rate=
        end

        # The sample rate of the mix.
        attr_reader :sample_rate

        # The channel nodes (see Channel).
        attr_reader :outputs
        alias channels outputs

        # Creates a mix source with +:channels+ outputs at +:sample_rate+.
        def initialize(channels:, sample_rate: 48000)
          raise ArgumentError, 'Channels must be a positive Integer' unless channels.is_a?(Integer) && channels >= 1

          @sample_rate = sample_rate.to_f
          @outputs = Array.new(channels) { |i| Channel.new(self, i) }.freeze
          @data = Array.new(channels) { Numo::SFloat[] }
          @copies = Array.new(channels) # (reused by #channel_data)
          @offsets = Array.new(channels, 0) # (where the next piece starts; see #channel_data)
        end

        # A MixSource has no upstream nodes.
        def sources
          {}.freeze
        end

        # Sets the buffer that the channels return next: an Array of
        # Numo::NArray with one element per channel.
        def write(data)
          raise ArgumentError, "Expected #{@outputs.length} channels (got #{data.length})" unless data.length == @outputs.length
          @data = data
          @offsets.fill(0)
        end

        # For internal use by Channel#sample.  Returns a copy of one channel of
        # the latest buffer (in a buffer of its own, reused every span).
        #
        # A read of fewer samples than the buffer holds is the next piece of
        # it (the reads of a span must add up to the buffer).
        def channel_data(index, count)
          d = @data[index]
          return channel_piece(index, d, count) if count < d.length && count > 0
          unless count == d.length
            raise ArgumentError, "A master effects chain asked for #{count} samples, but the mix buffer has #{d.length}; nodes that change the sample count (e.g. resample or oversample) can't be used here"
          end
          # A copy (nodes may work on it in place) in a buffer reused
          # every span, like any node's #sample buffer
          c = @copies[index]
          return c if c && c.class == d.class && c.length == d.length && MB::Sound::Kernels.copy(c, d)
          @copies[index] = d.dup
        end

        # The next +count+ samples of buffer +d+ for channel +index+ (see
        # #channel_data).
        def channel_piece(index, d, count)
          off = @offsets[index]
          if off + count > d.length
            raise ArgumentError, "A master effects chain asked for #{count} samples #{off} samples into a #{d.length}-sample mix buffer; " \
              "nodes that change the sample count (e.g. resample or oversample) can't be used here"
          end
          @offsets[index] = off + count == d.length ? 0 : off + count
          d[off...(off + count)].dup
        end
        private :channel_piece

        # Raises an error unless +rate+ matches this mix's sample rate.
        def sample_rate=(rate)
          return self if rate.to_f == @sample_rate
          raise NotImplementedError, "Cannot change the sample rate of a mix from #{@sample_rate} to #{rate}"
        end
        alias at_rate sample_rate=
      end
    end
  end
end
