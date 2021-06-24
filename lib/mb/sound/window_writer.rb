module MB
  module Sound
    # Writes overlapping time domain frames to an output stream.  The output
    # stream is not closed, so more audio can be written and the caller should
    # close the output stream.
    class WindowWriter
      attr_reader :channels, :length, :buffer_size

      # Initializes a new window writer with the given +output_stream+ and
      # +window+ function.  The +window+ must be provided to set the size and
      # spacing of frames, but will only be applied to the incoming audio if it
      # specifies a post-processing window (e.g. see Sound::Window::DoubleHann).
      # If the window does not specify a post-processing/synthesis window, then
      # the output window will effectively be a rectangular window.
      #
      # The +pad_factor+ parameter is provided for the benefit of e.g. FFT which
      # may send more audio than the actual window size if it was also padded.
      # The pad factor of an input should match the pad factor of an output.
      def initialize(output_stream, window, skip_overlap: false, pad_factor: 1)
        @output_stream = output_stream
        @channels = output_stream.channels
        @buffer_size = output_stream.buffer_size
        @window = window
        @pad_factor = pad_factor

        @length = window.length * pad_factor
        @hop = window.hop
        @overlap = @length - @hop
        @post_window = MB::M.zpad(window.post_window, @length, alignment: 0.5) if window.post_window
        @overlap_gain = window.overlap_gain

        @out_bufs = output_stream.channels.times.map { Numo::SFloat.zeros(@length) }
        @output = []

        @skip_overlap = skip_overlap
        @skip_overlap = 100 if skip_overlap && (!skip_overlap.is_a?(Numeric) || skip_overlap < 0)
        @dc_gap = Numo::SFloat.zeros(@skip_overlap.to_i) if @skip_overlap && @skip_overlap > 0
      end

      # Adds the given +audio+ (an array of NArrays, one for each channel) to the
      # output buffers, writing data to the output stream as it's ready (all
      # overlapping frames have been added).  Returns the number of time-domain
      # samples per channel written to the output stream (so no matter how many
      # channels there are, that return value will be the same).
      def write(audio)
        raise "Output stream has #{@output_stream.channels} channels, but tried to write #{audio.size}" unless audio.size == @output_stream.channels
        raise "Tried to write #{audio.first.size} samples, but buffer size is #{@length}" unless @length == audio.first.size

        if @skip_overlap
          # Write one hop at a time, spread out
          wrote = @output_stream.write(audio)
          wrote += @output_stream.write([@dc_gap] * audio.size) if @dc_gap
        else
          @out_bufs.each_with_index do |c, idx|
            if @overlap > 0
              # Add (whole buffer)
              a = audio[idx].not_inplace! * @overlap_gain

              # It seems like NArray has some weird rules for when array
              # multiplication happens in place, so this is done not in place
              a = a * @post_window if @post_window

              c[0..-1] = c[0..-1] + a

              # Extract first hop
              @output[idx] = c[0..(@hop - 1)].clone

              # Shift buffer
              c[0..(@overlap - 1)] = c[@hop..-1]
              c[@overlap..-1] = 0
            else
              @output[idx] = audio[idx]
            end
          end

          wrote = @output_stream.write(@output)
        end

        wrote
      end

      # Writes enough zeros to flush all audio through the output buffer.
      def drain
        zeros = [Numo::SFloat.zeros(@length)] * @output_stream.channels
        (@length / @hop).times do
          write(zeros)
        end
      end
    end
  end
end
