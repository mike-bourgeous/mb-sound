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
      # Example:
      #     out = MB::Sound::MIDI::Output.new(connect: 'Launchkey')
      #     out.write([0x90, 60, 100])
      #     out.write("\x80\x3c\x00".b)
      class Output
        # Lists the names of the MIDI destinations an output can connect to.
        def self.ports(api: nil)
          Input.port_names(Input.api(api), :output)
        end

        attr_reader :api, :port_name, :connected_to

        # Opens MIDI output (see the class comment).  +:port_name+ names our
        # port (default: midi_out, or midi_out_2 etc. on JACK if taken; the
        # script's name for CoreMIDI virtual sources).  +:queue_bytes+ is the
        # JACK output queue's size.
        def initialize(connect: nil, port_name: nil, api: nil, queue_bytes: 65536)
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
            @output = FastMIDI::Output.new(@api, client, index, @port_name)
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
          @api == :jack ? @output.write(bytes) : @output.send_bytes(bytes)
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

        def to_s
          "#<#{self.class.name} #{@api} #{connections.first}#{' closed' if closed?}>"
        end
        alias inspect to_s
      end
    end
  end
end
