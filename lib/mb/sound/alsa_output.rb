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
    # TODO: It might be possible to use ruby-ffi to interact with ALSA
    # directly, as is done with mb-sound-jackffi.
    class AlsaOutput < MB::Sound::IOOutput
      attr_reader :device, :rate

      # Initializes an ALSA output stream for the given device name, sample rate,
      # and number of channels.  Alsa will also be told to use the given buffer
      # size.  Warning: does no error checking to see whether aplay was able to
      # open the device!
      def initialize(device:, rate:, channels:, buffer_size: nil)
        @device = device.shellescape
        @rate = rate.to_i

        super(
          [
            'aplay',
            '-t', 'raw',
            '-f', 'FLOAT_LE',
            '-r', "#{@rate}",
            '-c', "#{channels}",
            "--buffer-size=#{buffer_size}",
            '-D', "#{@device}",
            '-q'
          ],
          channels,
          buffer_size
        )
      end
    end
  end
end
