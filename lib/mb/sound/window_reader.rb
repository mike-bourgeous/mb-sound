module MB
  module Sound
    # Reads windowed time-domain data from an input stream using a given window
    # function, padding with zeros to drain the buffer at the end.
    class WindowReader
      attr_reader :channels, :length

      def initialize(input_stream, window, pad_factor: 1)
        raise 'Input stream must respond to #read' unless input_stream.respond_to?(:read)
        raise 'Window must respond to #pre_window' unless window.respond_to?(:pre_window)

        @input_stream = input_stream
        @channels = input_stream.channels

        @window = window
        @length = window.length * pad_factor
        @hop = window.hop
        @overlap = @length - @hop
        @pre_window = MB::M.zpad(@window.pre_window, @length, alignment: 0.5).not_inplace!
        @drain = false

        @in_bufs = input_stream.channels.times.map { Numo::SFloat.zeros(@length) }
        @zero = [Numo::SFloat.zeros(@hop)] * input_stream.channels
      end

      # Reads one overlapped window of data.  If the stream returns less than the
      # hop length, then zeros will be appended for the current read, and all
      # zeros returned for subsequent reads until the next read would return only
      # the appended zeros.  After the buffer has been completely drained,
      # returns nil.
      def read
        if !@drain
          input = @input_stream.read(@hop)

          if input.first.size == 0
            # TODO: test with pad factor to see if we can use @window.length instead of padded @length
            @drain = @length / @hop - 1
          elsif input.first.size < @hop
            input = input.map { |c| MB::M.zpad(c, @hop) }
          end
        end

        # Not elsif because the if may set @drain
        if @drain
          if @drain > 0
            input = @zero
            @drain -= 1
          else
            return nil
          end
        end

        @in_bufs.each_with_index do |c, idx|
          if @overlap > 0
            # Shift buffer by hop (TODO: treat buffer as circular?)
            c[0..(@overlap - 1)] = c[@hop..-1]
          end

          # Copy new data into buffer
          c[@overlap..-1] = input[idx]
        end

        @in_bufs.map { |c|
          # This is actually not that slow, but does produce more allocation
          # churn; using another buffer and doing (out.inplace - out + in) *
          # window is slightly faster (suprisingly NArray has no fast copy;
          # copying is slower than subtracting and adding).
          c.not_inplace! * @pre_window
        }
      end
    end
  end
end
