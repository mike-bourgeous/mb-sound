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
    # Latency settings come from a profile (see PROFILES; :default unless
    # +:profile+ or AUDIO_PROFILE says otherwise), and any of them can be
    # set separately.  Environment variables take precedence over the
    # constructor's arguments:
    #   AUDIO_PROFILE=low              latency profile (low, default, video, safe)
    #   AUDIO_BUFFER=512               frames per write (Session's block size)
    #   AUDIO_PERIOD=128               sound card period in frames
    #   AUDIO_LATENCY=0.05             seconds of audio queued ahead (at least
    #                                  two writes)
    #   AUDIO_BACKEND=jack,pulseaudio  backends to try, in order (see .backends)
    #   OUTPUT_DEVICE=name or DEVICE   device index or part of its name (see .devices)
    #   AUDIO_SAMPLE_RATE=44100        rate of the audio written (default 48000)
    #   AUDIO_DEVICE_RATE=44100        rate to open the sound card at (default:
    #                                  AUDIO_SAMPLE_RATE, else the card's own)
    #   AUDIO_RESAMPLE=fastest         resampler when the card's rate differs:
    #                                  fastest (default), medium, best (sinc),
    #                                  linear, zoh, or off (run at the card's
    #                                  rate; #sample_rate is then the card's)
    #   AUDIO_ADAPTIVE=0               don't grow the queue after dropouts
    #   AUDIO_SET_DEVICE_RATE=1        let CoreAudio switch the card's
    #                                  system-wide rate (macOS; changes it for
    #                                  every app, as in Audio MIDI Setup)
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
      # Latency profiles: frames per write (the block size Session renders),
      # the sound card period in frames (nil for miniaudio's low-latency
      # default, 10 ms), and seconds queued ahead of the sound card (at least
      # two writes).  Chosen with bin/audio_load_check.rb on the user's Mac
      # (2026-10-04; latencies at 48 kHz, plus driver delay):
      # - :low (16-19 ms) for playing light patches live; heavier graphs
      #   (fm_bass at 4x oversampling, fm_bass + stereo_drone) drop out
      # - :default (45-56 ms) had no dropouts with fm_bass, stereo_drone, or
      #   both
      # - :video (about 45-58 ms) writes 400 frames, one 120 fps video frame
      #   at 48 kHz; about 8-10 points more render load than :default (more
      #   calls), which failed fm_bass + stereo_drone at 4x oversampling
      # - :safe (about 110 ms) is the first version's setting, for heavy
      #   graphs or busy machines; its 800-frame writes are 60 fps frames
      PROFILES = {
        low: { buffer_size: 256, period: 128, latency: 0 }.freeze,
        default: { buffer_size: 512, period: 128, latency: 0.05 }.freeze,
        video: { buffer_size: 400, period: 128, latency: 0.05 }.freeze,
        safe: { buffer_size: 800, period: nil, latency: 0.085 }.freeze,
      }.freeze

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

      # libsamplerate converters for +:resample+ (false or :off for none).
      RESAMPLE_QUALITIES = { best: 0, medium: 1, fastest: 2, zoh: 3, linear: 4, off: -1 }.freeze

      attr_reader :channels, :sample_rate, :device_rate, :buffer_size, :backend, :device_name, :device_channels, :profile

      # Opens and starts the sound card.  +:channels+ is how many channels
      # #write takes (a mono output plays on both channels of a stereo
      # device).  +:sample_rate+ is the rate of the audio written (graphs and
      # Sessions run at it).  The sound card opens at +:device_rate+
      # (default: +:sample_rate+), or at its own rate if it can't; when its
      # rate differs from +:sample_rate+, the C extension resamples with
      # +:resample+ (see RESAMPLE_QUALITIES; :fastest sinc by default), or
      # with +resample: false+ doesn't, and #sample_rate is the card's rate.
      # +:set_device_rate+ lets CoreAudio change the card's system-wide rate
      # (macOS).  #device_rate is the card's rate.
      #
      # +:device+ is a device index or part of a device name (see .devices;
      # default: the system default).  +:profile+ is a latency profile from
      # PROFILES (:low, :default, :video, :safe), whose settings
      # +:buffer_size+ (the block size Session renders), +:period+ (the sound
      # card period in frames), and +:latency+ (the most audio queued ahead of
      # the sound card, in seconds) override.  +:backends+ is an Array of
      # backends to try (see .backends).
      #
      # With +:adaptive+ (the default), the queue grows by half after each
      # dropout while audio is being written, up to the :safe profile's
      # queue, with a note on stderr; the write size and period stay.
      def initialize(
        channels: 2, sample_rate: 48000, device: nil, profile: nil, buffer_size: nil, latency: nil, period: nil,
        backends: nil, device_rate: nil, resample: :fastest, set_device_rate: false, adaptive: true, capture: 0
      )
        raise ArgumentError, 'Channels must be positive' if channels < 1

        profile = (ENV['AUDIO_PROFILE'] || profile || :default).to_s.delete_prefix(':').to_sym
        settings = PROFILES.fetch(profile) {
          raise ArgumentError, "Unknown audio profile #{profile.inspect} (#{PROFILES.keys.join(', ')})"
        }
        @profile = profile

        device = ENV['OUTPUT_DEVICE'] || ENV['DEVICE'] || device
        requested_rate = Integer(ENV['AUDIO_SAMPLE_RATE'] || sample_rate)
        latency = Float(ENV['AUDIO_LATENCY'] || latency || settings[:latency])
        period = Integer(ENV['AUDIO_PERIOD'] || period || settings[:period] || 0)
        backends = self.class.backends(backends)

        @channels = channels
        @buffer_size = Integer(ENV['AUDIO_BUFFER'] || buffer_size || settings[:buffer_size])
        @requested_rate = requested_rate

        device_rate = Integer(ENV['AUDIO_DEVICE_RATE'] || device_rate || 0)
        resample = ENV['AUDIO_RESAMPLE'] || resample
        resample = :off if resample == false || resample.nil?
        resample = resample.to_s.delete_prefix(':').to_sym
        quality = RESAMPLE_QUALITIES.fetch(resample) {
          raise ArgumentError, "Unknown resampler #{resample.inspect} (#{RESAMPLE_QUALITIES.keys.join(', ')})"
        }
        set_device_rate = ENV.key?('AUDIO_SET_DEVICE_RATE') ? ENV['AUDIO_SET_DEVICE_RATE'] == '1' : set_device_rate
        @adaptive = ENV.key?('AUDIO_ADAPTIVE') ? ENV['AUDIO_ADAPTIVE'] != '0' : adaptive

        # A mono output still opens two channels, so mono plays on both
        # speakers (and on both JACK playback ports).
        @device_channels = channels == 1 ? 2 : channels
        queue = [(latency * requested_rate).round, @buffer_size * 2, 64].max

        @playback = FastAudio::Playback.new(
          backends, self.class.device_index(device, backends: backends), self.class.client_name,
          channels, @device_channels, requested_rate, device_rate, period, queue, capture,
          quality, set_device_rate, @adaptive ? [max_adaptive_queue(requested_rate), queue].max : 0
        )
        @underruns_seen = 0
        @last_write = nil

        @sample_rate = @playback.sample_rate.to_f
        @device_rate = @playback.device_rate.to_f
        @backend = @playback.backend
        @device_name = @playback.device_name
        @period = @playback.period
        @device_buffer = @period * @playback.periods

        if @playback.resampling?
          warn "#{@device_name} runs at #{@device_rate.round} Hz; resampling from #{requested_rate} Hz (#{resample})"
        elsif @sample_rate != requested_rate
          warn "#{@device_name} runs at #{@sample_rate.round} Hz instead of #{requested_rate} Hz"
        end

        self.class.track(self, true)
      end

      # Queues audio for playback: an Array with one Numo::NArray per
      # channel, all the same length.  Waits (without the GVL) while the
      # queue is full.  Returns the number of frames written.
      def write(data)
        raise "Expected #{@channels} channels, got #{data.length}" unless data.length == @channels
        frames = @playback.write(data)
        adapt if @adaptive
        frames
      end

      # True if the queue grows after underruns (see +:adaptive+).
      def adaptive?
        @adaptive
      end

      # Session may write any number of frames per call.
      def strict_buffer_size?
        false
      end

      # Seconds from a sample being written to it reaching the sound card's
      # output (the queue plus the sound card's own buffer).  Changes as the
      # queue fills and drains.
      def latency
        (@playback.stats[:queued] + @device_buffer) / @device_rate
      end

      # True if written audio is resampled to the sound card's rate.
      def resampling?
        @playback.resampling?
      end

      # Frames queued ahead of the sound card at most, at the card's rate
      # (see +:latency+).  #stats frame counts are at the card's rate too.
      def queue_limit
        @playback.queue_limit
      end

      # The most frames an adaptive output's queue grows to (see
      # +:adaptive+).
      def max_queue
        @playback.max_queue
      end

      # The sound card's period (frames per callback).
      def period
        @period
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
        rate = resampling? ? "#{@sample_rate.round}Hz->#{@device_rate.round}Hz" : "#{@sample_rate.round}Hz"
        "#<#{self.class.name} #{@backend} #{@device_name.inspect} #{@channels}ch #{rate} #{@profile}#{' closed' if closed?}>"
      end
      alias to_s inspect

      private

      # The largest queue (frames at +rate+) an adaptive output grows to: the
      # :safe profile's.
      def max_adaptive_queue(rate)
        (PROFILES[:safe][:latency] * rate).round
      end

      # Grows the queue by half (up to #max_queue) when the sound card ran
      # out of audio while something was writing to it.  A gap between
      # writes (e.g. between sounds played with MB::Sound.play) isn't
      # counted.
      def adapt
        underruns = @playback.stats[:underruns]
        now = MB::U.clock_now
        active = @last_write && now - @last_write < latency + 0.1

        if underruns > @underruns_seen && active
          limit = @playback.queue_limit
          @playback.queue_limit = (limit * 1.5).ceil # clamped to max_queue
          grown = @playback.queue_limit
          if grown > limit
            warn "Audio dropout: raising the output queue to #{(grown * 1000.0 / @device_rate).round} ms"
          end
        end

        @underruns_seen = underruns
        @last_write = now
      end
    end
  end
end
