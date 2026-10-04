module MB
  module Sound
    module MIDI
      # Minimal live MIDI output through RtMidi (MB::Sound::FastMIDI::Output):
      # sends raw messages right away to a virtual source named after the
      # script, or with +:connect+ to the first destination whose name
      # contains it (or that index; see .ports).  MIDI_API chooses the API as
      # for MIDI::Input.  Scheduled output, clocks, and sequencing are part of
      # a later sequence/MIDI/synth overhaul.
      #
      # Example:
      #     out = MB::Sound::MIDI::Output.new(connect: 'Launchkey')
      #     out.write([0x90, 60, 100])
      #     out.write("\x80\x3c\x00".b)
      class Output
        # Lists the names of the MIDI destinations an output can connect to.
        def self.ports(api: nil)
          FastMIDI.output_ports(Input.api(api), DeviceOutput.client_name)
        end

        attr_reader :api, :port_name, :connected_to

        # Opens MIDI output (see the class comment).  +:port_name+ names our
        # port (default: the script's name for CoreMIDI virtual sources, else
        # 'midi_out').
        def initialize(connect: nil, port_name: nil, api: nil)
          @api = Input.api(api)
          client = DeviceOutput.client_name
          @port_name = port_name || (@api == :core && connect.nil? ? client : 'midi_out')

          index = nil
          if connect
            names = FastMIDI.output_ports(@api, client)
            index = Integer(connect) if connect.is_a?(Integer) || connect.to_s =~ /\A\d+\z/
            index ||= names.index { |n| n.downcase.include?(connect.to_s.downcase) }
            if index.nil? || index >= names.length
              list = names.each_with_index.map { |n, i| "  #{i}: #{n}" }.join("\n")
              raise ArgumentError, "No MIDI destination matches #{connect.inspect}.  Destinations:\n#{list}"
            end
            @connected_to = names[index]
          end

          @output = FastMIDI::Output.new(@api, client, index, @port_name)
          DeviceOutput.track(self, true)
        end

        # Sends one MIDI message: an Array of byte values or a binary String.
        def write(message)
          bytes = message.is_a?(String) ? message.b : message.to_a.pack('C*')
          @output.send_bytes(bytes)
          nil
        end
        alias << write

        # Where messages go (a destination, or our virtual source).
        def connections
          [@connected_to || "#{DeviceOutput.client_name}:#{@port_name} (virtual)"]
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
