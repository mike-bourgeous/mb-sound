module MB
  module Sound
    # Writes audio to multiple output streams.  All output streams must accept
    # the same buffer size.  If some streams support fewer channels
    class MultiWriter
      class SampleRateMismatch < ArgumentError; end
      class BufferSizeMismatch < ArgumentError; end
      class ChannelCountMismatch < ArgumentError; end

      attr_reader :sample_rate, :buffer_size, :channels

      # Initializes a multiple-output writer with the given Array of output
      # streams.  All output streams must have the same buffer size and sample
      # rate.
      def initialize(streams)
        raise 'All output streams must respond to :write' unless streams.all? { |s| s.respond_to?(:write) }
        @streams = streams

        @sample_rate = streams[0].sample_rate
        unless streams.all? { |s| s.sample_rate == @sample_rate }
          raise SampleRateMismatch, "All output streams must have the same sample rate (got #{streams.map(&:sample_rate)})"
        end

        @buffer_size = streams[0].buffer_size
        unless streams.all? { |s| s.buffer_size == @buffer_size }
          raise BufferSizeMismatch, "All output streams must have the same buffer size (got #{streams.map { |s| "#{s.class.name} => #{s.buffer_size}" }.join(', ') })"
        end

        @channels = streams.map(&:channels).max
      end

      # Writes the given +data+ to all of the output streams that were given to
      # the constructor.  There must be enough channels provided to match the
      # channel count of the output stream with the most channels.
      def write(data)
        raise ChannelCountMismatch, "Expected #{@channels} channels, got #{data.length}" unless data.length == @channels

        @streams.each do |s|
          s.write(data[0...s.channels])
        end
      end
    end
  end
end
