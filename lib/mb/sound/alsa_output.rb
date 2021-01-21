require 'shellwords'

module MB
  module Sound
    # A sound output stream that opens the `aplay` command in a pipe and writes
    # 32-bit little-endian float data to it, for playing directly to a sound
    # card.
    #
    # Note: as a starting point, set the buffer size equal to the hop size used
    # in any processing algorithms.
    #
    # TODO: It might be possible to use ruby-ffi to interact with ALSA directly.
    class AlsaOutput < MB::Sound::IOOutput
      attr_reader :device, :rate, :channels, :buffer_size

      DEFAULT_BUFFER = 1024

      # Initializes an ALSA output stream for the given device name, sample rate,
      # and number of channels.  Alsa will also be told to use the given buffer
      # size.  Warning: does no error checking to see whether aplay was able to
      # open the device!
      def initialize(device:, rate:, channels:, buffer_size: 512)
        @device = device.shellescape
        @rate = rate.to_i
        @channels = channels.to_i
        @buffer_size = buffer_size&.to_i || DEFAULT_BUFFER
        @pipe = IO.popen(["sh", "-c", "aplay -t raw -f FLOAT_LE -r '#{@rate}' -c '#{@channels}' --buffer-size=#{@buffer_size} -D #{@device.shellescape} -q"], "w")
        MB::Sound::U.pipe_size(@pipe, @buffer_size * @channels * 4)

        super(@pipe, channels)
      end
    end
  end
end
