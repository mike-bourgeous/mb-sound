module MB
  module Sound
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
      # An individual channel of an input channel splitter, returned by
      # InputChannelSplit#channels.
      #
      # TODO: Maybe this can be deduplicated with Tee.
      class InputChannelNode
        include ArithmeticMixin

        attr_reader :need_sample

        # For internal use by InputChannelSplit.  Initializes one output
        # channel of the split.
        def initialize(split, channel, name)
          @split = split
          @channel = channel
          @graph_node_name = name
        end

        # Retrieves the next buffer for this channel.  The InputChannelSplit
        # will print a warning if any channel is sampled more than once without
        # all channels being sampled once.
        def sample(count)
          @split.internal_sample(self, @channel, count)
        end

        # Returns an Array containing the source node feeding into the
        # InputChannelSplit.
        def sources
          @split.sources
        end
      end

      # The source node feeding into this InputChannelSplit, in an array (see
      # ArithmeticMixin#sources).
      attr_reader :sources
      
      # The channels from the InputChannelSplit (see IOSampleMixin#split).
      attr_reader :channels

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

        # List of channels that have already read the current buffer, to detect
        # when a new buffer is needed.
        @read_channels = Set.new
      end

      # For internal use by InputChannelNode#sample.  Returns the current
      # buffer of +count+ samples for the channel at index +channel+ from the
      # source node.  The +count+ must be the same for every channel.
      #
      # If the +channel+ has already seen the current buffer, or if the source
      # buffer has not yet been read, then a new buffer (containing all
      # channels) is read from the source node.
      def internal_sample(node, channel, count)
        if @read_channels.include?(node)
          if @read_channels.length != @channels.length
            warn "Channel #{channel} on InputChannelSplit #{self} sampled again with #{@read_channels.length} of #{@channels.length} sampled"
          end

          @read_channels.clear
          @buf = nil
        end

        if @buf && @buf[0].length != count
          @buf = @buf.map { |b|
            if b
              if !b.empty?
                MB::M.zpad(b, count)
              else
                nil
              end
            end
          }
        end

        @read_channels << node

        @buf ||= @source.read(count)

        @buf[channel]
      end
    end
  end
end
