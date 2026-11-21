module MB
  module Sound
    # What the sound card gives the live console (console-offers-1,
    # 2026-11-21; the PipeWire quantum study's option A, "say what it
    # gets"): one line when a DeviceOutput opens (also after `latency` and
    # `use_output` change it), the pull size (frames the sound server or
    # card takes per callback) once it is known, a one-time warning when
    # the pull is larger than mb-sound's buffer, and a line when the JACK
    # server's period changes.  JACK through PipeWire locks the period
    # ("quantum") at whatever it was when the client joined, often 1024, so
    # 512-frame writes were pulled in 1024-frame blocks: the screens got new
    # audio half as often and the sound came later, and nothing said so.
    #
    # Only in live mode (bin/sound.rb; MB::Sound.live?): DeviceOutput#initialize
    # calls .opened, and the console calls .poll after each line it runs
    # (and once at startup), on its own thread: nothing here runs on the
    # render or device threads, and nothing blocks.  The JACK pull is known
    # at open (the server's buffer size); other backends' is the largest
    # callback so far, read once a second of audio has played.
    #
    #     Audio out: jack "sound" (PipeWire's JACK) at 48000 Hz, buffer 512 frames (latency :default), pulls 1024 frames
    #
    # `latency` with no argument prints .facts (the same, the queue, and the
    # underruns so far).
    module DeviceReport
      # Seconds of audio played before a measured (non-JACK) pull counts.
      PULL_AFTER = 1.0

      # What .poll follows: the newest open DeviceOutput, the pull it last
      # reported (nil until known), and whether its open line printed.
      State = Struct.new(:output, :pull, :announced)

      @lock = Mutex.new
      @opened = nil
      @state = nil
      @warned = false
      @pipewire = nil

      class << self
        # Called by DeviceOutput#initialize: in live mode, remembers
        # +output+ for the next .poll.
        def opened(output)
          return unless MB::Sound.live?

          @lock.synchronize { @opened = output }
          nil
        end

        # Prints what changed since the last call (the console's thread,
        # after each line): an output's open line, a pull measured later,
        # a JACK period change; warns once when a pull is larger than the
        # buffer.  Returns nil.
        def poll
          out = @lock.synchronize {
            o = @opened
            @opened = nil
            o
          }
          if out && !out.closed?
            p = pull(out)
            @state = State.new(out, p, true)
            Internal.console_puts(open_line(out, p))
            check(out, p)
            return nil
          end

          st = @state
          return nil unless st
          if st.output.closed?
            @state = nil
            return nil
          end
          p = pull(st.output)
          return nil if p.nil? || p == st.pull

          was = st.pull
          st.pull = p
          Internal.console_puts(was ? "Audio out: #{server(st.output)} now pulls #{p} frames at a time (was #{was})" : "Audio out: #{server(st.output)} pulls #{p} frames at a time")
          check(st.output, p)
          nil
        end

        # Frames the sound server or card takes at a time from +out+: a
        # JACK output's server buffer size, else the largest callback so
        # far once PULL_AFTER seconds have played (nil before, and for
        # outputs that aren't a DeviceOutput).
        def pull(out)
          return nil unless out.is_a?(DeviceOutput) && !out.closed?

          if out.backend == :jack
            n = Jack.info&.dig(:buffer_size).to_i
            n > 0 ? n : nil
          else
            s = out.stats
            s[:frames_played] >= out.device_rate * PULL_AFTER && s[:max_callback] > 0 ? s[:max_callback] : nil
          end
        end

        # mb-sound's buffer in the card's frames (the Session's block, at
        # the card's rate when it resamples).
        def buffer_frames(out)
          (out.buffer_size * out.device_rate / out.sample_rate).round
        end

        # The open line: backend, device, rate, buffer, profile, period,
        # and the pull when known (+pull+, else how it will be known).
        def open_line(out, pull = pull(out))
          rate = out.resampling? ? "#{out.sample_rate.round} Hz resampled to #{out.device_rate.round} Hz" : "#{out.device_rate.round} Hz"
          name = out.backend == :jack ? "client #{out.device_name.inspect}" : out.device_name.inspect
          period = out.backend == :jack ? '' : ", period #{out.period}"
          tail = pull ? ", pulls #{pull} frames" : ", pull size known after a second of sound (`latency` shows it)"
          "Audio out: #{out.backend} #{name}#{pipewire_jack?(out) ? " (PipeWire's JACK)" : ''} at #{rate}, buffer #{out.buffer_size} frames (latency #{out.profile.inspect})#{period}#{tail}"
        end

        # The facts `latency` prints for +out+ (lines): the open line, the
        # queue and latency, the underruns (xruns) so far.
        def facts(out)
          return "Audio out: not open (it opens when something plays)" if out.nil?
          return "Audio out: #{out.class.name.split('::').last} at #{out.sample_rate.round} Hz, buffer #{out.buffer_size} frames (no sound card#{Internal.detect_output == :null ? ', OUTPUT_TYPE=null' : ''})" unless out.is_a?(DeviceOutput)
          return "Audio out: #{out.inspect}" if out.closed?

          s = out.stats
          st = out.adapt_state
          ms = ->(frames) { (frames * 1000.0 / out.device_rate).round }
          queue = "Queue: #{ms.(st[:base_queue])} ms"
          queue += st[:adaptive] ? " (adaptive#{st[:queue_limit] == st[:base_queue] ? '' : ", now #{ms.(st[:queue_limit])} ms"}, up to #{ms.(out.max_queue)} ms)" : ' (fixed)'
          queue += "; latency now #{(out.latency * 1000).round} ms (the queue plus the card's buffer)"
          xruns = "Underruns (xruns): #{s[:underruns]} so far"
          xruns += ", #{s[:concealed_gaps]} concealed (#{ms.(s[:concealed])} ms)" if s[:concealed_gaps].to_i > 0
          if out.backend == :jack && (j = Jack.info)
            xruns += "; JACK skipped #{j[:skipped_cycles]} cycle#{'s' unless j[:skipped_cycles] == 1}"
          end
          p = pull(out)
          lines = [open_line(out, p), queue, xruns]
          lines << "Pull: #{pull_advice(out, p)}" if p && p > buffer_frames(out)
          lines.join("\n")
        end

        # True if +out+ is a JACK output through PipeWire's libjack (the
        # library loaded from PipeWire's folder, e.g. .../pipewire-0.3/jack/
        # through pw-jack or its ld.so drop-in; PipeWire's libjack talks only
        # to PipeWire, jackd2's only to jackd).  Read once from
        # /proc/self/maps (Linux; false elsewhere).
        def pipewire_jack?(out)
          return false unless out.respond_to?(:backend) && out.backend == :jack

          @pipewire = jack_library.to_s.include?('pipewire') if @pipewire.nil?
          @pipewire
        end

        # The path of the libjack the process loaded, or nil.
        def jack_library
          return nil unless File.readable?('/proc/self/maps')

          File.foreach('/proc/self/maps') do |l|
            path = l.split(' ', 6)[5]&.strip
            return path if path && File.basename(path).start_with?('libjack.so')
          end
          nil
        rescue SystemCallError
          nil
        end

        # Plain words for what pulls: "PipeWire", "the JACK server", or
        # "the sound card".
        def server(out)
          return 'PipeWire' if pipewire_jack?(out)
          out.backend == :jack ? 'the JACK server' : 'the sound card'
        end

        # What to do when +out+ is pulled in blocks of +pull+ frames,
        # larger than its buffer.
        def pull_advice(out, pull)
          b = buffer_frames(out)
          rate = out.device_rate.round
          times = pull % b == 0 ? (pull / b == 2 ? 'twice' : "#{pull / b} times") : format('%.1f times', pull.fdiv(b))
          often = pull == 2 * b ? 'half as often' : 'less often'
          what = "#{server(out)} pulls #{pull} frames at a time, #{times} mb-sound's #{b}-frame buffer, " \
                 "so the screens get new audio #{often} and sound comes later"
          fix =
            if pipewire_jack?(out)
              "PipeWire keeps the period (quantum) it had when mb-sound joined: start with PIPEWIRE_QUANTUM=#{b}/#{rate} bin/sound.rb, " \
                "or set it for everything with `pw-metadata -n settings 0 clock.force-quantum #{b}` (0 undoes it)"
            elsif out.backend == :jack
              "set the JACK server's period (buffer size) to #{b} frames (jackd -p #{b}, or your JACK control app)"
            else
              "set the sound server's period (buffer size) to #{b} frames"
            end
          "#{what}; #{fix}"
        end

        # Warns once per process when +pull+ is larger than +out+'s buffer.
        def check(out, pull)
          return if @warned || pull.nil? || pull <= buffer_frames(out)

          @warned = true
          warn "Audio out: #{pull_advice(out, pull)}"
        end

        # Forgets what was reported (specs).
        def reset!
          @lock.synchronize { @opened = nil }
          @state = nil
          @warned = false
          @pipewire = nil
        end
      end
    end
  end
end
