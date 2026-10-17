module MB
  module Sound
    module MIDI
      # Minimal live MIDI output: a midi_out port on the script's one JACK
      # client when a JACK server answers (see MIDI::Input and
      # FastAudio::JackMIDIOutput), else RtMidi (MB::Sound::FastMIDI::Output;
      # a virtual source named after the script).  Messages go out right away
      # (on JACK, at the start of the next cycle).  With +:connect+ it also
      # connects to the first destination whose name contains it (or that
      # index; see .ports).  MIDI_API chooses the API as for MIDI::Input.
      # Scheduled output, clocks, and sequencing are part of a later
      # sequence/MIDI/synth overhaul.
      #
      # Overlapping notes on one key are ambiguous for receivers (some count
      # them, most end the note at the first note-off), so by default
      # (+same_key: :restrike+) a note-on for a key this output holds on
      # that channel first sends a note-off for it, and the note-off that
      # would have ended the older note is not sent (see NoteBalancer).
      # +same_key: :raw+ sends every message as given.
      #
      # Example:
      #     out = MB::Sound::MIDI::Output.new(connect: 'Launchkey')
      #     out.write([0x90, 60, 100])
      #     out.write("\x80\x3c\x00".b)
      class Output
        # Keeps note messages written to a MIDI output unambiguous: at most
        # one note per (channel, key) sounds, a note-on for a held key is
        # preceded by a note-off for it, and note-offs for keys not held
        # (the older duplicates' ends) are dropped.  All notes off (CC
        # 123-127) forgets the channel's notes.  Works on raw messages
        # (binary Strings).
        class NoteBalancer
          def initialize
            @held = {}
          end

          # Returns the messages to send for +bytes+ (one message as a
          # binary String): an Array of binary Strings, maybe empty.
          def filter(bytes)
            status = bytes.getbyte(0)
            return [bytes] if status.nil? || status < 0x80 || status >= 0xC0 || bytes.bytesize < 3

            channel = status & 0x0F
            kind = status & 0xF0
            note = bytes.getbyte(1)

            if kind == 0xB0
              @held.delete_if { |(ch, _), _| ch == channel } if note >= 123
              return [bytes]
            end
            return [bytes] if kind == 0xA0

            key = [channel, note]
            if kind == 0x90 && bytes.getbyte(2) > 0
              out = []
              out << [0x80 | channel, note, 0].pack('C*') if @held[key]
              @held[key] = true
              out << bytes
            else
              @held.delete(key) ? [bytes] : []
            end
          end

          # True if +note+ is held on +channel+ (0-based).
          def held?(note, channel: 0)
            @held.key?([channel, note])
          end
        end

        # The overlapping same-key note modes (see the class description).
        SAME_KEY_MODES = [:restrike, :raw].freeze

        # Lists the names of the MIDI destinations an output can connect to.
        def self.ports(api: nil)
          Input.port_names(Input.api(api), :output)
        end

        attr_reader :api, :port_name, :connected_to

        # Opens MIDI output (see the class comment).  +:port_name+ names our
        # port (default: midi_out, or midi_out_2 etc. on JACK if taken; the
        # script's name for CoreMIDI virtual sources).  +:queue_bytes+ is the
        # JACK output queue's size.
        def initialize(connect: nil, port_name: nil, api: nil, queue_bytes: 65536, same_key: :restrike)
          unless SAME_KEY_MODES.include?(same_key)
            raise ArgumentError, "Unknown same_key mode #{same_key.inspect} (use #{SAME_KEY_MODES})"
          end
          @balancer = same_key == :restrike ? NoteBalancer.new : nil
          @api = Input.api(api)
          client = DeviceOutput.client_name

          index = nil
          if connect
            # Searches the other APIs too (see Input.find_port)
            @api, index, @connected_to, lists = Input.find_port(connect, kind: :output, api: api)
            unless index
              raise ArgumentError, "No MIDI destination matches #{connect.inspect}.  Destinations:\n#{Input.port_list(lists)}"
            end
          end

          if @api == :jack
            @port_name = port_name || Jack.port_names('midi_out', 1, numbered: false).first
            @output = FastAudio::JackMIDIOutput.new(client, @port_name, queue_bytes)
            FastAudio.jack_connect(@output.port_name, @connected_to) if @connected_to
          else
            @port_name = port_name || (@api == :core && connect.nil? ? client : 'midi_out')
            @output = Input.rtmidi_quietly { FastMIDI::Output.new(@api, client, index, @port_name) }
          end

          DeviceOutput.track(self, true)
        end

        # Sends one MIDI message: an Array of byte values, a binary String,
        # or a MIDI::Event with bytes (e.g. `C4.to_midi`).
        def write(message)
          if message.is_a?(Event)
            raise ArgumentError, "#{message.type} event has no MIDI bytes" if message.bytes.nil?
            message = message.bytes
          end
          bytes = message.is_a?(String) ? message.b : message.to_a.pack('C*')
          if @balancer
            @balancer.filter(bytes).each { |b| send_raw(b) }
          else
            send_raw(bytes)
          end
          nil
        end
        alias << write

        # This output's port: the full JACK name (client:port), or a
        # description of the RtMidi port.
        def port
          @api == :jack ? (@output.port_name || "#{Jack.client_name}:#{@port_name}") : "#{DeviceOutput.client_name}:#{@port_name} (virtual)"
        end

        # Where messages go: on JACK the port's live connections (or the port
        # itself while unconnected), else the destination or our virtual
        # source.
        def connections
          if @api == :jack
            live = @output.closed? ? [] : Jack.connections(@output.port_name)
            return live.empty? ? [port] : live
          end

          [@connected_to || port]
        end

        # Closes the port.  Safe to call more than once.
        def close
          @output.close
          DeviceOutput.track(self, false)
          nil
        end

        def closed?
          @output.closed?
        end

        private def send_raw(bytes)
          @api == :jack ? @output.write(bytes) : @output.send_bytes(bytes)
        end

        def to_s
          "#<#{self.class.name} #{@api} #{connections.first}#{' closed' if closed?}>"
        end
        alias inspect to_s
      end
    end
  end
end
