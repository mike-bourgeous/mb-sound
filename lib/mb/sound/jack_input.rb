require 'shellwords'

module MB
  module Sound
    # An audio input stream that opens the `jack-stdout` command in a pipe and
    # reads 32-bit little-endian float data from it, for recording directly
    # from a jackd audio network.
    #
    # Note: as a starting point, set the buffer size equal to the hop size used
    # in any processing algorithms.  This needs to be at least one half of the
    # jackd period size.  The jack-stdout internal buffer will be set larger to
    # handle jitter in processing time.
    class JackInput < MB::Sound::IOInput
      attr_reader :channels, :ports, :buffer_size, :rate

      # Initializes a JACK input stream for the given list of port names (pass
      # `nil` to try to leave a port disconnected; this will give a nonexistent
      # port name to jack-stdout for connection).  Alternatively, you can pass an
      # integer for +ports+ to allocate that many disconnected ports.  Uses
      # 4x the given buffer size.
      #
      # The sample rate given should match whatever rate jackd is using.
      #
      # Note: as a starting point, set the buffer size equal to the hop size
      # used in any processing algorithms.  This needs to be at least twice the
      # jackd buffer size.
      #
      # Examples:
      #
      # Recording from the first two system input channels:
      #     MB::Sound::JackInput.new(ports: ['system:capture_1', 'system:capture_2']
      #
      # Creating 8 unconnected input ports:
      #     MB::Sound::JackInput.new(ports: 8)
      #
      # Connecting to either the system input ports, or to ports with prefix
      # specified by the INPUT_DEVICE or DEVICE environment variable
      # (environment variables override the +device:+ key):
      #     # Will default to the system capture ports if the env vars are not set
      #     MB::Sound::JackOutput.new(ports: { device: nil, count: 8 })
      #
      #     # Will connect to ZynAddSubFX, if it's running
      #     ENV['INPUT_DEVICE'] = 'zynaddsubfx:out_'
      #     MB::Sound::JackInput.new(ports: { device: nil, count: 2 })
      def initialize(ports:, rate: 48000, buffer_size: 2048)
        case ports
        when Integer
          ports = [nil] * ports
        when Hash
          prefix = ENV['INPUT_DEVICE'] || ENV['DEVICE'] || ports[:device] || 'system:capture_'
          ports = ports[:count].times.map { |c|
            "#{prefix}#{c + 1}"
          }
        end

        @ports = ports
        @rate = rate
        @channels = @ports.size
        @buffer_size = buffer_size&.to_i || 2048
        ports = @ports.map { |n| (n || "invalid port #{rand(100000)}").shellescape }.join(' ')

        @pipe = IO.popen(["sh", "-c", "jack-stdout -L -e floating-point -q -S #{@buffer_size} #{ports}"], "r")

        super(@pipe, @channels)
      end
    end
  end
end
