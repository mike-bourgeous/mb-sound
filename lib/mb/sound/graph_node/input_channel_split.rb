require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Splits the channels from an Input with a #read method into separate graph
      # nodes for each input channel.  Sampling a channel's node twice causes the
      # next frame/buffer/window of data to be read from the input.
      #
      # The easiest way to use this class is with the IOSampleMixin#split method.
      #
      # Example:
      #     # Runnable in bin/sound.rb
      #     l, r = file_input('sounds/synth0.flac').split
      #     play [l.filter(500.hz.lowpass), r.filter(500.hz.highpass)]
      #
      # See also the Tee class, which is very similar.
      class InputChannelSplit
        extend Forwardable

        # Raised when any channel's internal buffer overflows.  This would
        # happen if the downstream buffer size is significantly larger than the
        # input's buffer size, or if one channel is being read more than
        # another.
        class ChannelBufferOverflow < MB::Sound::CircularBuffer::BufferOverflow; end

        # An individual channel of an input channel splitter, returned by
        # InputChannelSplit#channels.
        #
        # TODO: Maybe this can be deduplicated with Tee.
        class InputChannelNode
          extend Forwardable

          include GraphNode

          def_delegators :@split, :sample_rate, :sample_rate=, :at_rate, :sources, :buffer_size

          # For internal use by InputChannelSplit.  Initializes one output
          # channel of the split.
          def initialize(split, channel, name)
            @split = split
            @channel = channel
            @graph_node_name = name
          end

          # Retrieves the next +count+ samples for this channel.
          #
          # This method may modify and return the same object multiple times,
          # so duplicate the returned buffer if you need to retain multiple
          # past buffers.
          def sample(count)
            @split.internal_sample(self, @channel, count)
          end
        end

        # The source node feeding into this InputChannelSplit, in an array (see
        # GraphNode#sources).
        attr_reader :sources

        # The channels from the InputChannelSplit (see IOSampleMixin#split).
        attr_reader :channels

        def_delegators :@source, :sample_rate, :buffer_size

        # Creates a InputChannelSplit from the given +source+, with up to
        # +:max_channels+ channels.  Generally for internal use by
        # IOSampleMixin#split.
        def initialize(source, max_channels: nil)
          raise 'Source for a InputChannelSplit must respond to #read' unless source.respond_to?(:read)

          @source = source
          @sources = [source].freeze

          max_channels = source.channels if max_channels.nil? || source.channels < max_channels

          @channels = max_channels.times.map { |idx|
            # TODO: Get channel names from inputs that support them
            InputChannelNode.new(self, idx, "#{source.graph_node_name}: Channel #{idx}")
          }.freeze

          bufsize = MB::M.max(source.buffer_size * 3, 48000)
          @cbufs = Array.new(max_channels) {
            CircularBuffer.new(buffer_size: bufsize)
          }

          @done = false
        end

        # For internal use by InputChannelNode#sample.  Returns the current
        # buffer of +count+ samples for the channel at index +channel+ from the
        # source node.  The +count+ must be the same for every channel.
        #
        # If the +channel+ has already seen the current buffer, or if the source
        # buffer has not yet been read, then a new buffer (containing all
        # channels) is read from the source node.
        def internal_sample(node, channel, count)
          # TODO: maybe dedupe with Tee?

          while !@done && @cbufs[channel].length < count
            read_once
          end

          return nil if @done && @cbufs[channel].empty?

          @cbufs[channel].read(MB::M.min(@cbufs[channel].length, count)).not_inplace!
        end

        # Raises an error indicating that inputs split to graph nodes cannot
        # change sample rate.
        def sample_rate=(new_rate)
          raise NotImplementedError, "Cannot change sample rate on an input channel #{self}; try appending a .resample node"
        end
        alias at_rate sample_rate=

        private

        # Reads one buffer from the upstream input and stores each channel in a
        # separate circular buffer.  This allows temporary desyncing between
        # channels, which may happen if the input buffer size is e.g. 800 but
        # the node graph is running with a buffer size of 1024.
        def read_once
          buf = @source.read(@source.buffer_size)

          if buf.nil? || buf.empty? || buf.any?(&:empty?)
            @done = true
          else
            @cbufs.each_with_index do |c, idx|
              begin
                c.write(buf[idx])
              rescue MB::Sound::CircularBuffer::BufferOverflow => e
                raise ChannelBufferOverflow, "Channel #{idx + 1} of #{@channels.count} buffer is full; " \
                  "is one channel being sampled more than others?  Buffers: #{@cbufs.map(&:length)}"
              end
            end
          end
        end
      end
    end
  end
end
