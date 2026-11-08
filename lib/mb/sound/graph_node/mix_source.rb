module MB
  module Sound
    module GraphNode
      # Feeds buffers of audio that were rendered elsewhere into a node graph,
      # one output node per channel.  Used by Session to run the mix of every
      # player through a master effects chain (see Session#master).
      #
      # Call #write with each new buffer before sampling the chain.  Each
      # channel is a stream: reads return copies (graphs may modify what
      # they get) of the frames written, in order.  The chain asks for the
      # number of frames that was written, or for consecutive pieces of it
      # (a Synth reading its lanes in windows split at its grid; omnibus17,
      # Kez's K10: a bus chain through a Synth raised "asked for 799
      # samples" with plans off, which fused regions had hidden since
      # fuse-more-1).  Nodes that read ahead of their output (#resample)
      # need frames past the buffer: the Session sets #read_ahead from the
      # chain (GraphNode::ReadAhead), and the channels start that many
      # frames late (fix-bus-resample-1).  A read past the written frames
      # raises.
      #
      # Example:
      #     src = MB::Sound::GraphNode::MixSource.new(channels: 2)
      #     chain = src.outputs.map { |c| c.softclip }
      #     src.write([Numo::SFloat[0.5, 1, 2], Numo::SFloat[0, -1, -2]])
      #     chain.map { |c| c.sample(3) }
      class MixSource
        include MultiOutput
        node_traits memory: :none

        # One channel of a MixSource.
        class Channel
          extend Forwardable

          include GraphNode
          include NodeOutput
          node_traits memory: :none

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
          @copies = Array.new(channels) # (reused by #channel_data for whole-buffer reads)
          @read_ahead = 0
          @written = 0 # (frames in the latest #write)
          # Per channel: [buffer, spare, length] (frames not read yet, in
          # order) and whether the channel was read since the last write
          @fifos = Array.new(channels) { [Numo::SFloat.zeros(1024), Numo::SFloat.zeros(1024), 0] }
          @read = Array.new(channels, false)
        end

        # Frames of silence the channels start with, so a chain whose nodes
        # read ahead of their output (a #resample; see GraphNode::ReadAhead)
        # reads written frames: the chain hears the mix that many frames
        # late.  0 (the default) serves each written buffer as it comes.
        attr_reader :read_ahead

        # Sets #read_ahead (frames), before the first #write.
        def read_ahead=(frames)
          raise ArgumentError, "read_ahead must be a non-negative Integer (got #{frames.inspect})" unless frames.is_a?(Integer) && frames >= 0

          @read_ahead = frames
          @fifos.each do |f|
            f[0] = Numo::SFloat.zeros(frames + 1024)
            f[1] = Numo::SFloat.zeros(frames + 1024)
            f[2] = frames
          end
        end

        # A MixSource has no upstream nodes.
        def sources
          {}.freeze
        end

        # Adds the next buffer the channels return: an Array of
        # Numo::NArray with one element per channel.  A channel nothing
        # read since the last write (its chain doesn't use it, or skipped a
        # buffer) drops what it held but its last #read_ahead frames, as
        # chains that skip a buffer always have.
        def write(data)
          raise ArgumentError, "Expected #{@outputs.length} channels (got #{data.length})" unless data.length == @outputs.length

          @written = data[0]&.length || 0
          i = -1
          while (i += 1) < data.length # (no each_with_index: an imemo a call)
            f = @fifos[i]
            fifo_keep(f, @read_ahead) unless @read[i]
            @read[i] = false
            fifo_append(f, data[i])
          end
        end

        # For internal use by Channel#sample.  Returns a copy of the next
        # +count+ frames of one channel (nodes may work on it in place), in
        # a buffer reused for whole-buffer reads, like any node's #sample
        # buffer.
        #
        # A read of fewer frames than a write gives the next piece of it (a
        # Synth reading in windows), and frames a read leaves wait for the
        # next one (a :min_phase resampler reads just what its output
        # covers).  A read past the written frames raises: a node read
        # ahead of its output without saying so (#read_ahead; before
        # fix-bus-resample-1 a second whole read got the same buffer again,
        # so a resampler's lookahead read the first buffer twice and the
        # chain came out a buffer late).
        def channel_data(index, count)
          f = @fifos[index]
          buf, spare, len = f
          if count > len
            raise ArgumentError, "A mix chain read #{count} frames with #{len} written (#{@read_ahead} frames of read-ahead); " \
              "a node in it reads further ahead than it says (GraphNode::ReadAhead)"
          end
          @read[index] = true

          if count == @written
            c = @copies[index]
            c = @copies[index] = Numo::SFloat.zeros(count) unless c && c.length == count
          else
            c = Numo::SFloat.zeros(count)
          end
          c[0...count] = buf[0...count] unless Kernels.copy_range(c, 0, buf, 0, count)
          rest = len - count
          spare[0...rest] = buf[count...len] if rest > 0 && !Kernels.copy_range(spare, 0, buf, count, rest)
          f[0] = spare
          f[1] = buf
          f[2] = rest
          c
        end

        # Drops all but the last +keep+ frames of channel FIFO +f+.
        def fifo_keep(f, keep)
          buf, spare, len = f
          return if len <= keep

          if keep > 0
            spare[0...keep] = buf[(len - keep)...len] unless Kernels.copy_range(spare, 0, buf, len - keep, keep)
            f[0] = spare
            f[1] = buf
          end
          f[2] = keep
        end
        private :fifo_keep

        # Appends +d+ to channel FIFO +f+ ([buffer, spare, length]).
        def fifo_append(f, d)
          buf, _, len = f
          n = d.length
          if len + n > buf.length
            grown = Numo::SFloat.zeros((len + n) * 2)
            grown[0...len] = buf[0...len] if len > 0
            buf = f[0] = grown
            f[1] = Numo::SFloat.zeros(grown.length)
          end
          buf[len...(len + n)] = d unless Kernels.copy_range(buf, len, d, 0, n)
          f[2] = len + n
        end
        private :fifo_append

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
