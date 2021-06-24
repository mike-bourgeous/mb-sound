module MB
  module Sound
    # A sound input stream that opens the `arecord` command in a pipe and reads
    # 32-bit little-endian float data from it, for recording directly from a
    # sound card.
    #
    # Note: as a starting point, set the buffer size equal to the hop size used
    # in any processing algorithms.
    #
    # TODO: It might be possible to use ruby-ffi to interact with ALSA
    # directly, as is done with mb-sound-jackffi.
    class AlsaInput < IOInput
      attr_reader :device, :rate

      # Initializes an ALSA input stream for the given device name, sample rate,
      # and number of channels.  Alsa will be told to use the given buffer size
      # (number of samples per channel per buffer) as well.  Warning: does no
      # error checking to see whether arecord was able to open the device!
      #
      # The INPUT_DEVICE or DEVICE environment variable may be used to override
      # any device specified by the calling code.
      def initialize(device:, rate:, channels:, buffer_size: nil)
        @device = ENV['INPUT_DEVICE'] || ENV['DEVICE'] || device
        @rate = rate.to_i

        super(
          [
            'arecord',
            '-t', 'raw',
            '-f', 'FLOAT_LE',
            '-r', "#{@rate}",
            '-c', "#{channels.to_i}",
            ->() { "--buffer-size=#{@buffer_size.to_i}" },
            '-D', "#{@device}",
            '-q',
          ],
          channels,
          buffer_size
        )
      end
    end
  end
end
