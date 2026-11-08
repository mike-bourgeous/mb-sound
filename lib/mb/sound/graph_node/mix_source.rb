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
          @data = Array.new(channels) { Numo::SFloat[] }
          @copies = Array.new(channels) # (reused by #channel_data)
          @offsets = Array.new(channels, 0) # (where the next piece starts; see #channel_data)
          @read_ahead = 0
          @fifos = nil # (per channel [buffer, spare, length] while #read_ahead > 0)
        end

        # Frames of silence the channels start with, so a chain whose nodes
        # read ahead of their output (a #resample; see GraphNode::ReadAhead)
        # reads written frames: the chain hears the mix that many frames
        # late.  0 (the default) serves each written buffer as it is.
        attr_reader :read_ahead

        # Sets #read_ahead (frames), before the first #write.
        def read_ahead=(frames)
          raise ArgumentError, "read_ahead must be a non-negative Integer (got #{frames.inspect})" unless frames.is_a?(Integer) && frames >= 0

          @read_ahead = frames
          @fifos = frames > 0 ? Array.new(@outputs.length) { [Numo::SFloat.zeros(frames + 1024), Numo::SFloat.zeros(frames + 1024), frames] } : nil
        end

        # A MixSource has no upstream nodes.
        def sources
          {}.freeze
        end

        # Sets the buffer that the channels return next: an Array of
        # Numo::NArray with one element per channel.
        def write(data)
          raise ArgumentError, "Expected #{@outputs.length} channels (got #{data.length})" unless data.length == @outputs.length
          if @fifos
            data.each_with_index { |d, idx| fifo_append(@fifos[idx], d) }
          else
            @data = data
            @offsets.fill(0)
          end
        end

        # For internal use by Channel#sample.  Returns a copy of one channel of
        # the latest buffer (in a buffer of its own, reused every span).
        #
        # A read of fewer samples than the buffer holds is the next piece of
        # it (the reads of a span must add up to the buffer).  A read past
        # the written frames raises: a node read ahead of its output without
        # saying so (#read_ahead; before fix-bus-resample-1 a second whole
        # read got the same buffer again, so a resampler's lookahead read
        # the first buffer twice and delayed the chain by a buffer).
        def channel_data(index, count)
          return fifo_read(index, count) if @fifos

          d = @data[index]
          return channel_piece(index, d, count) if count < d.length && count > 0
          unless count == d.length && @offsets[index] == 0
            raise ArgumentError, "A mix chain asked for #{count} samples #{@offsets[index]} samples into a #{d.length}-sample mix buffer; " \
              "a node in it reads ahead without saying how far (GraphNode::ReadAhead)"
          end
          @offsets[index] = d.length
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
            raise ArgumentError, "A mix chain asked for #{count} samples #{off} samples into a #{d.length}-sample mix buffer; " \
              "a node in it reads ahead without saying how far (GraphNode::ReadAhead)"
          end
          @offsets[index] = off + count
          d[off...(off + count)].dup
        end
        private :channel_piece

        # Appends +d+ to channel FIFO +f+ ([buffer, spare, length]).
        def fifo_append(f, d)
          buf, spare, len = f
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

        # The next +count+ frames of channel +index+'s FIFO (see
        # #read_ahead), in a buffer reused while reads keep their length.
        def fifo_read(index, count)
          f = @fifos[index]
          buf, spare, len = f
          if count > len
            raise ArgumentError, "A mix chain read #{count} frames with #{len} written (#{@read_ahead} frames of read-ahead); " \
              "a node in it reads further ahead than it says (GraphNode::ReadAhead)"
          end
          c = @copies[index]
          c = @copies[index] = Numo::SFloat.zeros(count) unless c && c.length == count
          c[0...count] = buf[0...count] unless Kernels.copy_range(c, 0, buf, 0, count)
          rest = len - count
          spare[0...rest] = buf[count...len] if rest > 0 && !Kernels.copy_range(spare, 0, buf, count, rest)
          f[0] = spare
          f[1] = buf
          f[2] = rest
          c
        end
        private :fifo_read

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
