module MB
  module Sound
    # Writes overlapping FFT frames to an output sound stream.  The output stream
    # must be closed separately when done writing.
    #
    # Uses WindowWriter, so see that class for more details.
    class FFTWriter
      # Initializes a new FFT writer with the given output stream and window
      # function.  The window must be provided even if there is no
      # post-processing window applied.
      def initialize(output_stream, window, skip_overlap: false, pad_factor: 1)
        @window_writer = WindowWriter.new(output_stream, window, skip_overlap: skip_overlap, pad_factor: pad_factor)
      end

      # Adds the given dfts to the output buffers, writing data to the output
      # stream as it's ready.  Returns the number of time-domain frames written
      # to the output stream.
      def write(dfts)
        raise "Output stream has #{@window_writer.channels} channels, but tried to write #{dfts.size}" unless dfts.size == @window_writer.channels

        @fft_size = dfts.first.size

        samples = MB::Sound.real_ifft(dfts, odd_length: @window_writer.length.odd?)

        @window_writer.write(samples)
      end

      # Writes enough zeros to flush all audio through the output buffer.
      #
      # TODO: calculate how much delay is added by all of the buffers, how much
      # draining is actually required (especially if the input buffers are
      # drained), and maybe try chopping off the first and/or last bits of audio
      # to match the original length of a file
      def drain
        @window_writer.drain
      end
    end
  end
end
