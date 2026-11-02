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
      # non-realtime Sessions, so they never hear it.
      #
      # The trim only turns down (0 dB at most; audio-safety-2, 2026-11-01:
      # a +15 dB trim from the level check hard-clipped everything over
      # -15 dBFS after the master gain, the maintainer's "limiting and
      # clipping" on a -10 dBFS sine).  A louder request is set to 0 dB
      # with a note to raise the system or interface volume instead, so
      # live output is the mix's own up to full scale.  Peaks over full
      # scale (a mix already over, e.g. with `master_gain 6.db`) are still
      # clipped with a warning (at most one every MONITOR_WARN_SECONDS).
      module MonitorTrim
        # The most the trim may be: 0 dB (it only attenuates).
        MAX_MONITOR_GAIN = 1.0

        # What a louder request says (the trim is set to 0 dB).
        LOUDER_NOTE = 'The monitor trim only turns down (0 dB at most, so live output never clips from it); ' \
                      'set it to 0 dB.  For more level, raise the system or audio interface volume'

        # Seconds between clip warnings.
        MONITOR_WARN_SECONDS = 10

        # How long a changed trim glides to its new gain (seconds).
        RAMP_SECONDS = 0.02

        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # The monitor trim (linear; 1.0 by default).
          def monitor_gain
            @monitor_gain || 1.0
          end

          # Sets the monitor trim (linear, 0 to MAX_MONITOR_GAIN, e.g.
          # `-6.db`).  More than 0 dB sets 0 dB with a warning
          # (LOUDER_NOTE).
          def monitor_gain=(gain)
            unless gain.is_a?(Numeric) && gain.real? && gain >= 0
              raise ArgumentError, "The monitor gain must be a gain of 0 dB or less, e.g. -6.db (got #{gain.inspect})"
            end
            if gain > MAX_MONITOR_GAIN * (1 + 1e-9)
              warn format("\e[33mMonitor trim %+.1f dB asked: %s\e[0m", 20 * Math.log10(gain), LOUDER_NOTE)
              gain = MAX_MONITOR_GAIN
            end
            @monitor_gain = [gain.to_f, MAX_MONITOR_GAIN].min
          end

          # Clips +bufs+ (channels already multiplied by a trim of +gain+)
          # to full scale if they went over, warning at most once every
          # MONITOR_WARN_SECONDS.  Returns the (possibly new) Array and
          # whether it clipped.  Also used by foreground #play.  (A safety
          # net: since the trim only attenuates, it can't fire from the
          # trim itself.)
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
          @monitor_applied = nil # (the trim the last buffer ended at; see #monitored)
        end

        # The buffer to write: +mix+ times the trim, clipped to full scale
        # (with a warning) if the trim pushed it over.  Returns +mix+ itself
        # when there is no trim.  A changed trim glides from the gain the
        # last buffer ended at, at most a full-scale change per
        # RAMP_SECONDS (linear in gain), so turning the volume doesn't
        # click (play-ui-1: bin/play.rb's volume keys).
        def monitored(mix)
          gain = Session.monitor_gain
          from = @monitor_applied || gain
          return mix unless @monitor
          if gain == 1.0 && from == 1.0
            @monitor_applied = 1.0
            return mix
          end

          n = mix[0]&.length.to_i
          if from != gain && n > 0
            # (at most a full-scale change per RAMP_SECONDS, so a big step
            # takes several buffers and a small one a few milliseconds)
            step = 1.0 / (RAMP_SECONDS * output.sample_rate)
            k = ((gain - from).abs / step).ceil.clamp(1, n)
            to = from + (gain - from).clamp(-k * step, k * step)
            ramp = Numo::SFloat.new(n).fill(to)
            ramp[0...k] = Numo::SFloat.linspace(from, to, k + 1)[1..]
            @monitor_applied = to
            out = mix.map { |c| c * ramp }
          else
            @monitor_applied = gain
            out = mix.map { |c| c * gain }
          end
          out, clipped = Session.monitor_clip(out, [from, gain].max)
          @monitor_clips += 1 if clipped
          out
        end
      end
    end
  end
end
