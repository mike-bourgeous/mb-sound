module MB
  module Sound
    module MIDI
      # A Source over live MIDI input (a MIDI::Input: JACK MIDI on the
      # script's shared JACK client, else RtMidi's CoreMIDI or ALSA
      # sequencer).  Each #read polls the input and gives its messages stream
      # times, as Events (see Source; read it through a Stream, e.g.
      # `MIDI::Stream.live` or `MIDI::Stream.for(source)`).
      #
      # Timing (+:timing+, or MIDI_TIMING, which takes precedence):
      #
      # :exact (default) keeps the spacing of the input's timestamps and
      # plays every event a constant latency after it arrived, so rhythms
      # come through sample-exactly instead of snapped to buffers:
      #
      # - JACK input with a JACK +:output+ (a DeviceOutput on JACK): both use
      #   JACK's frame clock.  An event at JACK frame F is placed on the
      #   output sample that reaches the ports at frame F + L (see
      #   DeviceOutput#jack_clock).  Exact to the sample, with no drift.
      # - RtMidi input, or JACK input without a JACK output: the input's
      #   clock (RtMidi's deltas added up, or unwrapped JACK frames) is
      #   anchored to stream time when the first events arrive: the newest
      #   event of that read is placed at "now" plus L (with an +:output+,
      #   now is the stream time playing at the moment, `from - queued`;
      #   without one, the start of the read, and L is one buffer, the
      #   read's length), and later events keep their spacing from it.  If
      #   the mapping drifts by more than L (clock drift, a paused session,
      #   or an offline render running faster than real time), the source
      #   re-anchors the same way (#reanchors counts these).  A DLL that
      #   follows drift smoothly can replace this later (see #track_drift).
      #
      # L is +:latency+ if given, else the smallest constant latency that
      # keeps events from arriving too late with the output's queue: the
      # queue limit plus one device period plus one read (buffer).  The
      # Session writes in bursts (DeviceOutput fills the queue, then waits
      # until half of it has played), so a MIDI read can come up to the whole
      # queue after the event arrived.  With DeviceOutput's :default profile
      # (50 ms queue, 128-frame period, 512-sample buffers) L is about 63 ms;
      # :low is about 18 ms.  (Measured on the dummy JACK server with
      # 256-frame periods and 512-sample buffers, events sent at cycle
      # starts needed up to the queue plus 416 frames; L allowed the queue
      # plus 768.)  L follows the output's (adaptive) queue limit;
      # event times never go backwards when it changes.
      #
      # :asap places every event at the start of the read that polled it
      # (lower average latency, but timing snapped to buffers and jittered by
      # the output queue).
      #
      # Events that would land before the start of the read (#late_events;
      # e.g. after a session stall) are moved to the start of the read.
      # Events after the end of the read wait for later reads.
      #
      # Live input has no content position: #seek and #restart do nothing,
      # and the source never ends while open (#ended? is true once it has
      # been closed and every event read).
      #
      # Examples:
      #     out = MB::Sound::DeviceOutput.new
      #     src = MB::Sound::MIDI::LiveSource.new(connect: 'Launchkey', output: out)
      #     stream = MB::Sound::MIDI::Stream.new(src)
      #     MB::Sound::MIDI::Stream.live(connect: 'Launchkey', timing: :asap)
      class LiveSource
        include Source

        # The timing modes (see the class comment).
        TIMINGS = [:exact, :asap].freeze

        # The MIDI::Input (or a compatible object with #read_raw,
        # #frame_times?, #frame_rate, and #close) being read.
        attr_reader :input

        # :exact or :asap (see the class comment).
        attr_reader :timing

        # The output whose clock :exact timing follows (nil for none).
        attr_reader :output

        # Events moved to the start of a read because they would have been
        # earlier.
        attr_reader :late_events

        # Times a free-running input clock was re-anchored after the mapping
        # drifted (see the class comment).
        attr_reader :reanchors

        # Reads +input+ (a MIDI::Input), or opens one with +:connect+ and
        # +input_options+ (see MIDI::Input.new), which #close then closes.
        # +:output+ is the output the events will play on (a DeviceOutput),
        # whose clock :exact timing follows.  +:latency+ (seconds or a
        # Length) overrides the automatic constant latency.
        def initialize(input = nil, connect: nil, timing: nil, output: nil, latency: nil, **input_options)
          timing = ENV['MIDI_TIMING'] if ENV['MIDI_TIMING'] && !ENV['MIDI_TIMING'].empty?
          @timing = (timing || :exact).to_s.delete_prefix(':').to_sym
          raise ArgumentError, "Unknown MIDI timing #{timing.inspect} (#{TIMINGS.join(', ')})" unless TIMINGS.include?(@timing)

          @owned = input.nil?
          @input = input || Input.new(connect: connect, **input_options)
          @output = output
          if latency
            latency = Length.seconds(latency)
            @fixed_latency = latency.is_a?(Float) ? latency.rationalize : latency.to_r
          end

          @pending = []
          @last_time = nil
          @late_events = 0
          @reanchors = 0
          @closed = false

          # Free-running input clocks (see #free_times)
          @anchor = nil
          @input_us = 0
          @frame_total = nil
          @last_frame = nil
          @latency = nil

          @node_type_name = 'MIDI Live'
        end

        # The constant latency (Rational seconds from an event's arrival to
        # when it plays) used by the latest read with :exact timing, or nil
        # before then (and for :asap).
        def latency
          @latency
        end

        # Follows a new +output+'s clock from the next read (e.g. after the
        # background session switched outputs; see
        # PlaybackMethods#use_output).  A free-running input clock is
        # anchored again at the next events.
        def output=(output)
          @output = output
          @anchor = nil
        end

        # True if :exact timing currently places JACK events by the output's
        # JACK frame clock (see the class comment).
        def frame_exact?
          @timing == :exact && @input.frame_times? && !jack_clock.nil?
        end

        # Live input has no content position, so this does nothing (the
        # stream's notes are left alone).
        def seek(_time)
          self
        end

        # Does nothing (see #seek).
        def restart
          self
        end

        # True once the source has been closed and every event was read.
        def ended?
          @closed && @pending.empty?
        end

        # Stops reading, and closes the input if this source opened it.  Safe
        # to call more than once.
        def close
          return nil if @closed

          @closed = true
          @input.close if @owned
          nil
        end

        def closed?
          @closed
        end

        def to_s
          port = @input.respond_to?(:port) ? " #{@input.port}" : ''
          "#{node_type_name}#{port}"
        end

        private

        # Polls the input, gives new messages stream times, and returns the
        # waiting events before +to+ (see Source#read_events).
        def read_events(from, to)
          raw = @closed ? [] : @input.read_raw
          stamp(raw, from, to).each_with_index do |time, idx|
            time = @last_time if @last_time && time < @last_time
            @last_time = time

            if time < from
              time = from
              @late_events += 1
            end

            @pending.concat(Event.parse_all(raw[idx][1], time: time))
          end

          count = @pending.bsearch_index { |e| e.time >= to } || @pending.length
          @pending.shift(count)
        end

        # Stream times (Rationals, before the late and monotonic clamps) for
        # the +raw+ messages polled by a read of [+from+, +to+).
        def stamp(raw, from, to)
          return [] if raw.empty?
          return Array.new(raw.length, from) if @timing == :asap

          clock = @input.frame_times? ? jack_clock : nil
          clock ? frame_times(raw, clock, from, to) : free_times(raw, from, to)
        end

        # The output's JACK clock, if both it and the input are on JACK.
        def jack_clock
          @output.respond_to?(:jack_clock) ? @output.jack_clock : nil
        end

        # Places JACK events by the JACK output's clock: the event at frame
        # F goes on the queued frame that reaches the ports at F + L.  The
        # read's +from+ is the next frame the output will queue (the Session
        # writes each buffer after reading it), so queued frame x is at
        # stream time from + (x - write_pos) / rate.
        def frame_times(raw, clock, from, to)
          rate = Integer(@input.frame_rate)
          latency = latency_frames(from, to, rate)
          @latency = Rational(latency, rate)
          base = clock[:read_pos] - clock[:write_pos] + latency

          raw.map { |frame, _|
            delta = ((frame - clock[:frame_time] + 0x8000_0000) & 0xffff_ffff) - 0x8000_0000
            from + Rational(base + delta, rate)
          }
        end

        # The constant latency in frames at +rate+ (see the class comment).
        def latency_frames(from, to, rate)
          return (@fixed_latency * rate).round if @fixed_latency

          buffer = ((to - from) * rate).ceil
          clock_output? ? @output.queue_limit + @output.period + buffer : buffer
        end

        # True if the output reports its queue (DeviceOutput).
        def clock_output?
          @output.respond_to?(:queue_limit) && @output.respond_to?(:stats) &&
            @output.respond_to?(:period) && @output.respond_to?(:device_rate)
        end

        # Places events by a free-running input clock (RtMidi deltas, or JACK
        # frames without a JACK output) anchored to stream time (see the
        # class comment).
        def free_times(raw, from, to)
          inputs = raw.map { |stamp, _| input_seconds(stamp) }
          newest = inputs.last

          if clock_output?
            rate = @output.device_rate.round
            latency = Rational(latency_frames(from, to, rate), rate)
            target = from - Rational(@output.stats[:queued], rate) + latency
          else
            latency = @fixed_latency || (to - from)
            target = from + latency
          end
          @latency = latency

          if @anchor
            mapped = newest + @anchor
            if mapped > target + latency || mapped < from - latency
              @anchor = nil
              @reanchors += 1
            end
          end
          @anchor ||= target - newest
          track_drift(newest, target)

          inputs.map { |t| t + @anchor }
        end

        # Hook for drift correction between the input clock and the output
        # (later: a delay-locked loop that adjusts @anchor smoothly).  Called
        # with the input time of the newest event of each read and the stream
        # time where an event arriving now would be placed.  Does nothing
        # yet; the re-anchoring in #free_times bounds the drift by the
        # latency.
        def track_drift(input_time, target)
        end

        # Converts a raw timestamp to Rational seconds on the input's clock:
        # RtMidi deltas are added up (to whole microseconds), and JACK frame
        # times are unwrapped (JACK's frame counter is 32 bits).
        def input_seconds(stamp)
          if @input.frame_times?
            if @last_frame
              @frame_total += ((stamp - @last_frame + 0x8000_0000) & 0xffff_ffff) - 0x8000_0000
            else
              @frame_total = 0
            end
            @last_frame = stamp
            Rational(@frame_total, Integer(@input.frame_rate))
          else
            @input_us += (stamp * 1_000_000).round
            Rational(@input_us, 1_000_000)
          end
        end
      end
    end
  end
end
