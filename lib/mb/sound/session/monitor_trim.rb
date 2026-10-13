module MB
  module Sound
    class Session
      # The monitor trim: a listening gain for live playback only, applied
      # to what a Session writes to its output, after the master chain (and
      # any limiter in it) and the master gain.  It is one process-wide
      # value (like a volume knob on the speakers), set by
      # PlaybackMethods#monitor_gain and by the listening level check
      # (Help::Level, `help.level`), and it never reaches #render, stems,
      # #record_audio files, taps (vis), or takes: those all see the mix
      # before the trim (maintainer, 2026-10-13: "makes sense then to set a
      # monitor gain").
      #
      # Sessions apply it when +monitor+ is true, by default when they are
      # realtime (the console's background Session); renders use
      # non-realtime Sessions, so they never hear it.  Above 0 dB the trim
      # can push peaks past full scale: the written buffer is then clipped
      # to -1..1 and a warning (at most one every MONITOR_WARN_SECONDS)
      # says by how much, so it never clips unnoticed.
      module MonitorTrim
        # The most the trim may be (a soft tone at -30 dBFS peak brought
        # up to -3 dBFS).
        MAX_MONITOR_GAIN = 10 ** (27 / 20.0)

        # Seconds between clip warnings.
        MONITOR_WARN_SECONDS = 10

        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # The monitor trim (linear; 1.0 by default).
          def monitor_gain
            @monitor_gain || 1.0
          end

          # Sets the monitor trim (linear, 0 to MAX_MONITOR_GAIN, e.g.
          # `6.db`).
          def monitor_gain=(gain)
            unless gain.is_a?(Numeric) && gain.real? && gain >= 0 && gain <= MAX_MONITOR_GAIN * (1 + 1e-9)
              raise ArgumentError, "The monitor gain must be a number from 0 to #{(20 * Math.log10(MAX_MONITOR_GAIN)).round} dB (got #{gain.inspect})"
            end
            @monitor_gain = gain.to_f
          end

          # Clips +bufs+ (channels already multiplied by a trim of +gain+)
          # to full scale if they went over, warning at most once every
          # MONITOR_WARN_SECONDS.  Returns the (possibly new) Array and
          # whether it clipped.  Also used by foreground #play.
          def monitor_clip(bufs, gain)
            return [bufs, false] unless gain > 1.0
            peak = bufs.map { |c| c.abs.max }.max.to_f
            return [bufs, false] unless peak > 1.0

            now = MB::U.clock_now
            if @monitor_warned_at.nil? || now - @monitor_warned_at >= MONITOR_WARN_SECONDS
              @monitor_warned_at = now
              warn format(
                "\e[33mMonitor trim %+.1f dB clipped a peak %.1f dB over full scale (renders and recordings are not affected); " \
                "help.level or monitor_gain to turn it down\e[0m",
                20 * Math.log10(gain), 20 * Math.log10(peak)
              )
            end
            [bufs.map { |c| c.clip(-1.0, 1.0) }, true]
          end
        end

        # True if this Session applies the monitor trim (see MonitorTrim).
        attr_accessor :monitor

        # The number of buffers whose written output the trim clipped.
        attr_reader :monitor_clips

        private

        def init_monitor(monitor)
          @monitor = monitor
          @monitor_clips = 0
        end

        # The buffer to write: +mix+ times the trim, clipped to full scale
        # (with a warning) if the trim pushed it over.  Returns +mix+ itself
        # when there is no trim.
        def monitored(mix)
          gain = Session.monitor_gain
          return mix if !@monitor || gain == 1.0

          out, clipped = Session.monitor_clip(mix.map { |c| c * gain }, gain)
          @monitor_clips += 1 if clipped
          out
        end
      end
    end
  end
end
