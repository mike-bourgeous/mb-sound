require 'shellwords'

module MB
  module Sound
    # A sound input stream that opens the `arecord` command in a pipe and reads
    # 32-bit little-endian float data from it, for recording directly from a
    # sound card.
    #
    # Note: as a starting point, set the buffer size equal to the hop size used
    # in any processing algorithms.
    #
    # TODO: It might be possible to use ruby-ffi to interact with ALSA directly.
    class AlsaInput < MB::Sound::IOInput
      attr_reader :device, :rate, :channels, :buffer_size

      DEFAULT_BUFFER = 512

      # Initializes an ALSA input stream for the given device name, sample rate,
      # and number of channels.  Alsa will be told to use the given buffer
      # size as well.  Warning: does no error checking to see whether arecord was
      # able to open the device!
      def initialize(device:, rate:, channels:, buffer_size: nil)
        @device = ENV['INPUT_DEVICE'] || ENV['DEVICE'] || device
        @rate = rate.to_i
        @buffer_size = buffer_size&.to_i || DEFAULT_BUFFER
        @channels = channels.to_i
        @pipe = IO.popen(["sh", "-c", "arecord -t raw -f FLOAT_LE -r '#{@rate}' -c '#{@channels}' --buffer-size=#{@buffer_size} -D #{@device.shellescape} -q"], "r")

        super(@pipe, @channels)
      end
    end
  end
end
