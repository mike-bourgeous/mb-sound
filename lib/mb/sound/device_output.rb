require 'set'

module MB
  module Sound
    # Plays sound on a sound card through miniaudio (the fast_audio C
    # extension; see MB::Sound::FastAudio::Playback): CoreAudio on macOS, and
    # JACK, PulseAudio/PipeWire, or ALSA on Linux, with no daemon or extra
    # packages needed.
    #
    # #write queues audio for the sound card and returns at once while there
    # is room; when the queue holds +:latency+ seconds it waits (without
    # holding Ruby's GVL) until the sound card has played half of it, so the
    # sound card's clock paces whatever is writing.  A C callback feeds the
    # sound card, so Ruby's garbage collection and busy threads don't cause
    # dropouts unless they take longer than the queue.
    #
    # Environment variables take precedence over the constructor's arguments:
    #   AUDIO_BACKEND=jack,pulseaudio  backends to try, in order (see .backends)
    #   OUTPUT_DEVICE=name or DEVICE   device index or part of its name (see .devices)
    #   AUDIO_SAMPLE_RATE=44100        rate to ask for (the device's own rate
    #                                  is used if it can't run at this one)
    #   AUDIO_LATENCY=0.05             seconds of audio queued ahead
    #   AUDIO_PERIOD=256               sound card period in frames
    #   JACK_CLIENT_NAME=name          JACK client name (default: script name)
    #
    # JACK servers are never started; JACK is used when a server (jackd or
    # PipeWire's JACK) is running.  New JACK ports are connected to the
    # physical outputs once at startup, and later rewiring (qjackctl,
    # qpwgraph, session managers) is left alone.
    #
    # Example:
    #     out = MB::Sound::DeviceOutput.new(channels: 2)
    #     out.write([left, right])
    #     out.close
    class DeviceOutput
      # Seconds of audio queued ahead of the sound card by default.
      DEFAULT_LATENCY = 0.085

      # Frames per #write that Session renders by default.
      DEFAULT_BUFFER_SIZE = 800

      @open_outputs = Set.new
      @exit_hook = false

      class << self
        # The backends to try, in order, for +:backends+ (an Array of Symbols
        # or a comma-separated String), the AUDIO_BACKEND environment
        # variable, or the platform default: on Linux, JACK first if a JACK
        # server is running, then PulseAudio (PipeWire), then ALSA; elsewhere
        # miniaudio's order (CoreAudio on macOS).
        def backends(backends = nil)
          backends = ENV['AUDIO_BACKEND'] if ENV['AUDIO_BACKEND'] && !ENV['AUDIO_BACKEND'].empty?
          backends = backends.split(/[\s,]+/) if backends.is_a?(String)
          return backends.map { |b| b.to_s.delete_prefix(':').to_sym } if backends

          if RUBY_PLATFORM =~ /linux/
            # Checked here so that a missing JACK server doesn't print
            # libjack's connection errors.
            jack = jack_running? ? [:jack] : []
            jack + [:pulseaudio, :alsa]
          end
        end

        # Lists the playback devices of the first working backend from
        # .backends: an Array of Hashes with :index, :name, and :default.
        def devices(backends: nil)
          FastAudio.devices(self.backends(backends), client_name)[:playback]
        end

        # The backend .devices and new outputs would use.
        def backend(backends: nil)
          FastAudio.devices(self.backends(backends), client_name)[:backend]
        end

        # Returns the device index for +device+ (an Integer index, a String of
        # digits, or part of a device name, case-insensitive), or -1 for the
        # default device if +device+ is nil, empty, or 'default'.
        def device_index(device, backends: nil)
          return -1 if device.nil? || device.to_s.strip.empty? || device.to_s == 'default'
          return Integer(device) if device.is_a?(Integer) || device.to_s =~ /\A\d+\z/

          list = devices(backends: backends)
          found = list.find { |d| d[:name].downcase.include?(device.to_s.downcase) }
          if found.nil?
            names = list.map { |d| "  #{d[:index]}: #{d[:name]}" }.join("\n")
            raise ArgumentError, "No output device matches #{device.inspect}.  Devices:\n#{names}"
          end

          found[:index]
        end

        # The JACK client name: JACK_CLIENT_NAME, or the script's name.
        def client_name
          name = ENV['JACK_CLIENT_NAME'] || File.basename($0.to_s, '.*')
          name = name.gsub(/[^A-Za-z0-9_.-]+/, '_')
          name = 'mb-sound' if name.empty? || name == '-e' || name == '_e'
          name[0, 63]
        end

        # True if a JACK server (jackd, or PipeWire's JACK) seems to be
        # running.
        def jack_running?
          !`pgrep -x 'jackd|jackdbus' 2>/dev/null`.strip.empty? ||
            !Dir.glob(['/dev/shm/jack-*', "/run/user/#{Process.uid}/jack/*", "/tmp/jack-#{Process.uid}/*"]).empty?
        end

        # Called by outputs as they open and close, so open outputs are
        # closed at exit before Ruby tears down.
        def track(output, open)
          if open
            @open_outputs << output
            unless @exit_hook
              @exit_hook = true
              at_exit { @open_outputs.to_a.each(&:close) }
            end
          else
            @open_outputs.delete(output)
          end
        end
      end

      attr_reader :channels, :sample_rate, :buffer_size, :backend, :device_name, :device_channels

      # Opens and starts the sound card.  +:channels+ is how many channels
      # #write takes (a mono output plays on both channels of a stereo
      # device).  +:sample_rate+ is the rate to ask for; if the device runs
      # at another rate, #sample_rate is the device's rate (a warning is
      # printed).  +:device+ is a device index or part of a device name (see
      # .devices; default: the system default).  +:latency+ is the most audio
      # queued ahead of the sound card, in seconds.  +:buffer_size+ is the
      # block size Session renders.  +:period+ is the sound card period in
      # frames (default: miniaudio's low-latency default).  +:backends+ is
      # an Array of backends to try (see .backends).
      def initialize(channels: 2, sample_rate: 48000, device: nil, buffer_size: nil, latency: nil, period: nil, backends: nil, capture: 0)
        raise ArgumentError, 'Channels must be positive' if channels < 1

        device = ENV['OUTPUT_DEVICE'] || ENV['DEVICE'] || device
        requested_rate = Integer(ENV['AUDIO_SAMPLE_RATE'] || sample_rate)
        latency = Float(ENV['AUDIO_LATENCY'] || latency || DEFAULT_LATENCY)
        period = Integer(ENV['AUDIO_PERIOD'] || period || 0)
        backends = self.class.backends(backends)

        @channels = channels
        @buffer_size = buffer_size || DEFAULT_BUFFER_SIZE
        @requested_rate = requested_rate

        # A mono output still opens two channels, so mono plays on both
        # speakers (and on both JACK playback ports).
        @device_channels = channels == 1 ? 2 : channels
        queue = [(latency * requested_rate).round, @buffer_size * 2, 64].max

        @playback = FastAudio::Playback.new(
          backends, self.class.device_index(device, backends: backends), self.class.client_name,
          channels, @device_channels, requested_rate, period, queue, capture
        )

        @sample_rate = @playback.sample_rate.to_f
        @backend = @playback.backend
        @device_name = @playback.device_name

        if @sample_rate != requested_rate
          warn "#{@device_name} runs at #{@sample_rate.round} Hz instead of #{requested_rate} Hz"
        end

        self.class.track(self, true)
      end

      # Queues audio for playback: an Array with one Numo::NArray per
      # channel, all the same length.  Waits (without the GVL) while the
      # queue is full.  Returns the number of frames written.
      def write(data)
        raise "Expected #{@channels} channels, got #{data.length}" unless data.length == @channels
        @playback.write(data)
      end

      # Session may write any number of frames per call.
      def strict_buffer_size?
        false
      end

      # Seconds from a sample being written to it reaching the sound card's
      # output (the queue plus the sound card's own buffer).  Changes as the
      # queue fills and drains.
      def latency
        (@playback.stats[:queued] + @playback.period * @playback.periods) / @sample_rate
      end

      # Frames queued ahead of the sound card at most (see +:latency+).
      def queue_limit
        @playback.queue_limit
      end

      # The sound card's period (frames per callback).
      def period
        @playback.period
      end

      # Statistics from the C extension: :queued, :frames_written,
      # :frames_played (the sound card's clock, including silence), and
      # :underruns (times the audio ran out while the sound card needed it,
      # counted once per gap).
      def stats
        @playback.stats
      end

      def frames_written
        stats[:frames_written]
      end

      def frames_played
        stats[:frames_played]
      end

      def underruns
        stats[:underruns]
      end

      # The interleaved frames played so far, if +:capture+ was given (for
      # specs): an Array of SFloat channels.
      def captured
        data = @playback.captured
        return nil if data.nil?
        frames = Numo::SFloat.from_binary(data).reshape(true, @device_channels)
        @device_channels.times.map { |c| frames[true, c].dup }
      end

      # Stops the sound card.  Safe to call more than once.
      def close
        @playback.close
        self.class.track(self, false)
        nil
      end

      def closed?
        @playback.closed?
      end

      def inspect
        "#<#{self.class.name} #{@backend} #{@device_name.inspect} #{@channels}ch #{@sample_rate.round}Hz#{' closed' if closed?}>"
      end
      alias to_s inspect
    end
  end
end
