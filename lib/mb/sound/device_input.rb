module MB
  module Sound
    # Records sound from a sound card through miniaudio (the fast_audio C
    # extension; see MB::Sound::FastAudio::Capture): CoreAudio on macOS
    # (no JACK needed), and JACK, PulseAudio/PipeWire, or ALSA on Linux.
    # The sound card's capture thread fills a queue in C, and #read waits
    # (without holding Ruby's GVL) until enough audio has arrived, so live
    # input paces itself by the sound card's clock.  If more than +:latency+
    # seconds pile up (e.g. Ruby paused), the oldest audio is skipped so the
    # input stays near real time.
    #
    # Like DeviceOutput, settings come from a latency profile
    # (DeviceOutput::PROFILES; AUDIO_PROFILE) and the same environment
    # variables (AUDIO_BACKEND, AUDIO_BUFFER, AUDIO_PERIOD, AUDIO_LATENCY,
    # AUDIO_SAMPLE_RATE, AUDIO_DEVICE_RATE, AUDIO_RESAMPLE, JACK_CLIENT_NAME),
    # which take precedence over the constructor's arguments, plus
    # INPUT_DEVICE (or DEVICE) for the device's index or part of its name
    # (see .devices).  When the sound card captures at another rate, the
    # audio is resampled to +:sample_rate+.
    #
    # Example:
    #     inp = MB::Sound::DeviceInput.new(channels: 2)
    #     left, right = inp.read(800)
    #     inp.close
    #
    #     # As a graph node (see MB::Sound.input with INPUT_TYPE=device)
    #     play MB::Sound::DeviceInput.new(channels: 1).filter(1000.hz.lowpass)
    class DeviceInput
      include GraphNode
      include GraphNode::IOSampleMixin

      # Lists the capture devices of the first working backend (see
      # DeviceOutput.backends): an Array of Hashes with :index, :name, and
      # :default.
      def self.devices(backends: nil)
        DeviceOutput.devices(backends: backends, kind: :capture)
      end

      attr_reader :channels, :sample_rate, :device_rate, :buffer_size, :backend, :device_name, :profile, :period

      # Opens and starts recording from the sound card: +:channels+ channels
      # at +:sample_rate+, from +:device+ (an index or part of a name; default:
      # the system default input).  +:profile+, +:buffer_size+ (the default
      # read size for graphs), +:period+, +:latency+ (the most audio kept
      # waiting before the oldest is skipped), +:backends+, +:device_rate+,
      # and +:resample+ work as for DeviceOutput.  +:test_pattern+ replaces
      # the sound card's audio with a counting pattern (for specs; see
      # FastAudio::Capture.new).
      def initialize(
        channels: 2, sample_rate: 48000, device: nil, profile: nil, buffer_size: nil, latency: nil, period: nil,
        backends: nil, device_rate: nil, resample: :fastest, test_pattern: false
      )
        raise ArgumentError, 'Channels must be positive' if channels < 1

        profile = (ENV['AUDIO_PROFILE'] || profile || :default).to_s.delete_prefix(':').to_sym
        settings = DeviceOutput::PROFILES.fetch(profile) {
          raise ArgumentError, "Unknown audio profile #{profile.inspect} (#{DeviceOutput::PROFILES.keys.join(', ')})"
        }
        @profile = profile

        device = ENV['INPUT_DEVICE'] || ENV['DEVICE'] || device
        requested_rate = Integer(ENV['AUDIO_SAMPLE_RATE'] || sample_rate)
        latency = Float(ENV['AUDIO_LATENCY'] || latency || settings[:latency])
        period = Integer(ENV['AUDIO_PERIOD'] || period || settings[:period] || 0)
        device_rate = Integer(ENV['AUDIO_DEVICE_RATE'] || device_rate || 0)
        resample = ENV['AUDIO_RESAMPLE'] || resample
        resample = :off if resample == false || resample.nil?
        quality = DeviceOutput::RESAMPLE_QUALITIES.fetch(resample.to_s.delete_prefix(':').to_sym) {
          raise ArgumentError, "Unknown resampler #{resample.inspect} (#{DeviceOutput::RESAMPLE_QUALITIES.keys.join(', ')})"
        }
        backends = DeviceOutput.backends(backends)

        @channels = channels
        @buffer_size = Integer(ENV['AUDIO_BUFFER'] || buffer_size || settings[:buffer_size])
        queue = [(latency * requested_rate).round, @buffer_size * 2, 64].max

        @capture = FastAudio::Capture.new(
          backends, DeviceOutput.device_index(device, backends: backends, kind: :capture), DeviceOutput.client_name,
          channels, requested_rate, device_rate, period, queue, quality, test_pattern
        )

        @sample_rate = @capture.sample_rate.to_f
        @device_rate = @capture.device_rate.to_f
        @backend = @capture.backend
        @device_name = @capture.device_name
        @period = @capture.period
        @device_buffer = @period * @capture.periods

        if @capture.resampling?
          warn "#{@device_name} records at #{@device_rate.round} Hz; resampling to #{requested_rate} Hz (#{resample})"
        elsif @sample_rate != requested_rate
          warn "#{@device_name} records at #{@sample_rate.round} Hz instead of #{requested_rate} Hz"
        end

        DeviceOutput.track(self, true)
      end

      # Returns +frames+ frames of recorded audio, one Numo::SFloat per
      # channel, waiting (without the GVL) until enough has arrived.
      def read(frames)
        @capture.read(frames)
      end

      # Graphs may read any number of frames at a time.
      def strict_buffer_size?
        false
      end

      # Seconds from sound reaching the sound card's input to #read
      # returning it, not counting the driver: the sound card's buffer plus
      # audio waiting in the queue.
      def latency
        (@capture.stats[:queued] + @device_buffer) / @device_rate
      end

      # True if recorded audio is resampled from the sound card's rate.
      def resampling?
        @capture.resampling?
      end

      # The most frames (at the sound card's rate) kept waiting before the
      # oldest are skipped.
      def queue_limit
        @capture.queue_limit
      end

      # Statistics from the C extension: :queued and :pending frames,
      # :frames_captured (the sound card's clock), :overruns (callbacks that
      # found the queue full), and :skipped (frames skipped to stay near
      # real time).
      def stats
        @capture.stats
      end

      # Stops recording.  Safe to call more than once.
      def close
        @capture.close
        DeviceOutput.track(self, false)
        nil
      end

      def closed?
        @capture.closed?
      end

      def inspect
        rate = resampling? ? "#{@device_rate.round}Hz->#{@sample_rate.round}Hz" : "#{@sample_rate.round}Hz"
        "#<#{self.class.name} #{@backend} #{@device_name.inspect} #{@channels}ch #{rate} #{@profile}#{' closed' if closed?}>"
      end
      alias to_s inspect
    end
  end
end
