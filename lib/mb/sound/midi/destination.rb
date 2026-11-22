module MB
  module Sound
    module MIDI
      # A MIDI destination a track plays to: a hardware synth's input or
      # another program's MIDI input port, on one MIDI channel, with the
      # program and bank to select when the track starts (console
      # `midi_out`, MidiOutMethods#midi_out).  It is a voice like a sampler
      # instrument: `track :kronos, midi_out('KRONOS', channel: 1)` makes a
      # patch track whose graph is a MIDI::OutNode reading the track's clip,
      # so everything that plays a track plays the synth (bg, scenes,
      # flows, generators, swaps, stops, mutes, pause).
      #
      # Timing: notes leave so that the synth sounds when mb-sound's own
      # audio for the same frame reaches the speakers.  On JACK (the
      # Session's audio output on JACK and the port a JACK port) each
      # message goes on the exact JACK frame its session frame's audio
      # leaves on (DeviceOutput#jack_frame_of), plus +offset+ (the synth's
      # own response, a monitoring path; negative for early), through the
      # port's timed queue (FastAudio::JackMIDIOutput#write_at): sample
      # exact, and notes already queued keep their frames when the output
      # queue changes depth.  Other paths (RtMidi) send when the render
      # thread makes the note (not aligned; see design/notes/midi.md).
      # Offline renders send nothing to devices.  Live input (an armed
      # track's keyboard) is sent at once (#send_now).
      #
      # Ports: every destination aimed at one device port shares one
      # MIDI::Output (on JACK, one port of the shared client, connected to
      # the device); +port:+ names a port of our own that nothing is
      # connected to, for other programs to connect to.
      #
      # +log: true+ records [frame, bytes] pairs instead of sending (frame:
      # the session frame plus the offset), for specs and checks.
      class Destination
        # The shared outputs, by the port they connect to (or our own port
        # name for +port:+), and every destination made (for panics).
        @outputs = {}
        @all = ObjectSpace::WeakMap.new
        @lock = Mutex.new

        class << self
          # Every destination made (that is still referenced).
          def all
            @lock.synchronize { @all.keys }
          end

          # All notes off on every destination now (console `panic`).
          def panic_all
            all.each(&:panic)
            nil
          end

          # Closes every shared output after all notes off (ExitClose, at
          # exit: a hardware synth must not drone on after mb-sound ends).
          def close
            panic_all
            outs = @lock.synchronize { o = @outputs.values; @outputs.clear; o }
            outs.each { |o| o.close unless o.closed? }
            nil
          end

          # The shared MIDI::Output for +key+ (made by the block if needed).
          def output_for(key)
            @lock.synchronize {
              o = @outputs[key]
              o = nil if o&.closed?
              @outputs[key] = o || yield
            }.tap { ExitClose.register(self) }
          end

          # Remembers +dest+ (see .all).
          def note(dest)
            @lock.synchronize { @all[dest] = true }
          end

          # The open shared outputs, by what they connect to.
          def outputs
            @lock.synchronize { @outputs.reject { |_, o| o.closed? } }
          end
        end

        # The destination's name as given (part of a port name), or nil for
        # a +port:+ of our own.
        attr_reader :target

        # The MIDI channel, 1 to 16 (as on the synths' displays).
        attr_reader :channel

        # The program selected when the track starts (1 to 128), or nil.
        attr_reader :program

        # The bank selected before the program: [MSB, LSB] (CC 0, CC 32), an
        # MSB alone, or nil.
        attr_reader :bank

        # Knobs bound to controllers on this destination: { knob name => CC
        # number } (`cc: { cut: 74 }`): while the track plays, turning the
        # knob sends the controller (its position along the knob's range,
        # 0..127), mirroring `knob :cut, ..., cc: 74` for input.
        attr_reader :ccs

        # True if the destination gets MIDI clock while its track plays
        # (`clock: true`): 24 ticks per quarter note from the transport,
        # Start (or Song Position and Continue) when the track starts or the
        # timeline jumps or resumes, Stop when it stops, pauses, or jumps.
        def clock?
          @clock
        end

        # Our own port's name for +port:+, or nil.
        attr_reader :port_name

        # The port this destination found (a MIDI::Ports::Port), or nil.
        attr_reader :port

        # The [frame, bytes] pairs sent so far with +log: true+ (else nil).
        attr_reader :log

        # See the class description.
        def initialize(target = nil, channel: 1, program: nil, bank: nil, offset: 0, port: nil, cc: nil, clock: false, log: false)
          raise ArgumentError, 'Give midi_out a destination name (part of a port name) or port: (a port of our own), not both' if target && port
          raise ArgumentError, "Give midi_out a destination: midi_out('KRONOS'), or port: 'name' for a port others connect to" if target.nil? && port.nil? && !log

          @channel = Destination.check_channel(channel)
          @program = Destination.check_program(program)
          @bank = Destination.check_bank(bank)
          @ccs = Destination.check_ccs(cc)
          raise ArgumentError, "clock: is true or false (got #{clock.inspect})" unless clock == true || clock == false
          @clock = clock
          @target = target&.to_s
          @port_name = port&.to_s
          @log = log ? [] : nil
          @offset = nil
          @offset_seconds = 0r
          @offset_frames = 0
          @offset_rate = nil
          self.offset = offset
          @status_base = @channel - 1
          @held = Array.new(128, 0) # notes on our channel sent and not ended, by key (for #panic)
          @output = nil
          @port = nil
          @error = nil
          @failed = false
          connect unless log
          Destination.note(self)
        end

        # The channel number checked: 1..16.  0 raises (channels count from
        # 1 here; a silent 0 would send to the wrong synth).
        def self.check_channel(channel)
          unless channel.is_a?(Integer) && channel.between?(1, 16)
            hint = channel == 0 ? ' (channels count from 1, as on the synths: channel 1 is the first)' : ''
            raise ArgumentError, "MIDI channels are 1 to 16 (got #{channel.inspect})#{hint}"
          end
          channel
        end

        # The program number checked: 1..128 or nil.
        def self.check_program(program)
          return nil if program.nil?
          unless program.is_a?(Integer) && program.between?(1, 128)
            hint = program == 0 ? ' (programs count from 1, as on most synth displays)' : ''
            raise ArgumentError, "MIDI programs are 1 to 128 (got #{program.inspect})#{hint}"
          end
          program
        end

        # The knob-to-controller binds checked: { knob name => CC number
        # (0..119) }, frozen (empty for nil).
        def self.check_ccs(cc)
          return {}.freeze if cc.nil?
          unless cc.is_a?(Hash) && cc.all? { |k, v| k.is_a?(Symbol) && v.is_a?(Integer) && v.between?(0, 119) }
            raise ArgumentError, "cc: binds knobs to controllers: { cut: 74, res: 71 } (knob names => CC numbers 0..119; got #{cc.inspect})"
          end
          cc.dup.freeze
        end

        # The bank checked: an MSB (0..127), [MSB, LSB], or nil.
        def self.check_bank(bank)
          return nil if bank.nil?
          ok = bank.is_a?(Integer) ? bank.between?(0, 127) : (bank.is_a?(Array) && bank.length == 2 && bank.all? { |b| b.is_a?(Integer) && b.between?(0, 127) })
          raise ArgumentError, "bank: is a bank select MSB (0..127) or [MSB, LSB] (CC 0 and CC 32; got #{bank.inspect})" unless ok
          bank.is_a?(Array) ? bank.dup.freeze : bank
        end

        # How much later than mb-sound's audio of the same frame the
        # destination's messages leave (a Length or seconds; negative for
        # earlier): the synth's own response, a monitoring path.
        def offset
          @offset
        end

        # Changes the offset (a Length, e.g. 4.ms, or seconds); applies to
        # messages sent from now on.
        def offset=(value)
          seconds = value.respond_to?(:to_seconds) ? value.to_seconds : value
          raise ArgumentError, "offset: takes a Length or seconds (e.g. 4.ms; got #{value.inspect})" unless seconds.is_a?(Numeric)
          @offset = value
          @offset_seconds = seconds.to_r
          @offset_rate = nil
        end

        # Seconds between rendering a frame and this destination's messages
        # for it leaving, on +output+ (an audio output; the background
        # Session's by default): the output's latency now (the queue plus
        # the card's buffer) plus the offset.  What a recording of the
        # synth would compensate besides the synth and the input (see
        # design/notes/midi.md, MIDI out).
        def send_delay(output = Session.existing&.output)
          lat = output.respond_to?(:latency) ? output.latency : 0
          lat + @offset_seconds
        end

        # True if the destination has a port to send to (or logs).
        def connected?
          !@log.nil? || (!@output.nil? && !@output.closed?)
        end

        # Why the destination isn't connected (a String), or nil.
        attr_reader :error

        # The shared MIDI::Output, or nil (see #connected?).
        def output
          @output
        end

        # A MIDI::OutNode playing +source+ (a Clip, Kit, Stream, or anything
        # MIDI::Stream.for takes) to this destination: what a track's patch
        # builds for each clip.
        def play(source)
          stream = source.is_a?(Stream) ? source : Stream.for(source)
          OutNode.new(stream, self)
        end

        # Sends a test note now (immediately, not timed): C4 by default for
        # +length+ seconds, so you can hear which synth is which.  Returns
        # self.
        def test(note = 60, velocity: 100, length: 0.3)
          note = note.respond_to?(:to_midi) ? note.to_midi.note : note
          send_now(0x90, note, velocity)
          out = @output
          if out&.timed? && (now = FastAudio.jack_frame_time)
            # (the note-off on JACK's clock: no thread)
            rate = Jack.info&.dig(:sample_rate) || 48000
            note_held(@status_base | 0x80, note, 0)
            out.write_at((now + (length * rate).round) & 0xffff_ffff, 0x80 | @status_base, note, 0)
          else
            Thread.new { sleep length; send_now(0x80, note, 0) }
          end
          self
        end

        # All notes off now on this destination's channel (+:all+: on all 16
        # channels of its port): queued timed messages dropped, note-offs
        # for the keys it holds, then all sound off (CC 120) and all notes
        # off (CC 123).
        def panic(channels = nil)
          raise ArgumentError, "panic takes nothing (this channel) or :all (got #{channels.inspect})" unless channels.nil? || channels == :all
          @output&.discard_timed
          128.times do |k|
            next if @held[k] <= 0
            @held[k] = 0
            send_now(0x80, k, 0)
          end
          send_now(0xb0, 120, 0)
          send_now(0xb0, 123, 0)
          if channels == :all && @output && !@output.closed?
            16.times do |ch|
              next if ch == @status_base
              @output.write([0xb0 | ch, 120, 0])
              @output.write([0xb0 | ch, 123, 0])
            end
          end
          self
        end

        # Sends a channel message now (immediately; live input, tests,
        # panics): +kind+ the status's high nibble (0x90 note-on, ...), the
        # channel added.
        def send_now(kind, data1, data2 = 0)
          status = kind | @status_base
          note_held(status, data1, data2)
          if @log
            @log << [nil, message_bytes(status, data1, data2)]
            return
          end
          out = @output or return
          out.write(message_bytes(status, data1, data2)) unless out.closed?
        rescue IOError, FastAudio::Error, FastMIDI::Error => e
          note_failure(e)
        end

        # Sends a channel message (+kind+ the status's high nibble) for
        # session frame +frame+ of +session+ (see the class description).
        # Called on the render thread by OutNode.
        def send_at(session, frame, kind, data1, data2 = 0)
          status = kind >= 0xf0 ? kind : kind | @status_base
          note_held(status, data1, data2)
          rate = session ? session.sample_rate : 48000
          if !@offset_rate.equal?(rate)
            @offset_frames = (@offset_seconds * rate).round
            @offset_rate = rate
          end

          if @log
            @log << [frame + @offset_frames, message_bytes(status, data1, data2)]
            return
          end
          out = @output or return
          # (offline renders send nothing; a Session writing to a sound card
          # is live even when a caller drives its buffers)
          return if out.closed? || session.nil?
          o = session.output
          return unless session.realtime? || o.respond_to?(:jack_frame_of)

          if out.timed?
            ahead = frame + @offset_frames - session.write_frame
            j = o.respond_to?(:jack_frame_of) ? o.jack_frame_of(scale_ahead(o, ahead)) : nil
            if j.nil?
              # (audio not on JACK: from JACK's clock plus the output's latency)
              now = FastAudio.jack_frame_time or return
              lat = o.respond_to?(:latency) ? (o.latency * rate).round : 0
              j = now + lat + ahead
            end
            out.write_at(j & 0xffff_ffff, status, data1, data2)
          else
            out.write(message_bytes(status, data1, data2))
          end
        rescue IOError, FastAudio::Error, FastMIDI::Error => e
          note_failure(e)
        end

        # Prints back as the console call that makes it.
        def to_ruby
          args = []
          args << @target.inspect if @target
          args << "channel: #{@channel}" unless @channel == 1
          args << "program: #{@program}" if @program
          args << "bank: #{@bank.inspect}" if @bank
          args << "offset: #{RubyValue.to_ruby(@offset)}" unless @offset_seconds.zero?
          args << "cc: { #{@ccs.map { |k, v| "#{k.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) ? "#{k}:" : "#{k.inspect} =>"} #{v}" }.join(', ')} }" unless @ccs.empty?
          args << 'clock: true' if @clock
          args << "port: #{@port_name.inspect}" if @port_name
          args << 'log: true' if @log && @target.nil? && @port_name.nil?
          "midi_out(#{args.join(', ')})"
        end

        def to_s
          where = @port ? @port.name : (@port_name ? "#{@port_name} (ours)" : (@log ? 'log' : 'nowhere'))
          "#<MIDI destination #{where} ch #{@channel}#{" prog #{@program}" if @program}#{' (not connected)' unless connected?}>"
        end
        alias inspect to_s

        private

        # Finds the port and opens (or shares) the output; on failure warns
        # in live mode (the track stays silent) and raises elsewhere.
        def connect
          if @port_name
            @output = Destination.output_for([:own, @port_name]) { Output.new(port_name: @port_name) }
            return
          end

          @port = begin
            Ports.find(@target, :out)
          rescue Ports::NotFound
            # (a port of this process named on purpose: a loopback into our
            # own MIDI input, e.g. a library synth playing `midi`)
            Ports.find(@target, :out, own: true)
          end
          @output = Destination.output_for([@port.api, @port.name]) {
            if @port.api == :jack
              Output.new(api: :jack).tap { |o| FastAudio.jack_connect(o.port, @port.name) }
            else
              Output.new(connect: @port.index, api: @port.api)
            end
          }
        rescue Ports::NotFound, Ports::Ambiguous, FastAudio::Error, FastMIDI::Error => e
          @error = e.message
          MB::Sound.live_error(e)
        end

        def scale_ahead(o, ahead)
          return ahead unless o.respond_to?(:device_rate) && o.device_rate != o.sample_rate
          (ahead * o.device_rate / o.sample_rate).round
        end

        def note_held(status, data1, data2)
          kind = status & 0xf0
          if kind == 0x90 && data2 > 0
            @held[data1] += 1
          elsif (kind == 0x80 || kind == 0x90) && @held[data1] > 0
            @held[data1] -= 1
          end
        end

        def message_bytes(status, data1, data2)
          k = status & 0xf0
          if status >= 0xf8 || status == 0xfa || status == 0xfb || status == 0xfc
            [status]
          elsif k == 0xc0 || k == 0xd0
            [status, data1]
          else
            [status, data1, data2]
          end
        end

        def note_failure(e)
          return if @failed
          @failed = true
          warn "MIDI out #{self}: #{e.class}: #{e.message} (further errors not shown)"
        end
      end
    end
  end
end
