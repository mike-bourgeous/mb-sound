module MB
  module Sound
    module MIDI
      # Live MIDI input through RtMidi (the fast_midi C extension; see
      # MB::Sound::FastMIDI::Input): CoreMIDI on macOS, the ALSA sequencer
      # (also PipeWire) or JACK MIDI on Linux.  RtMidi's thread queues
      # messages and #read polls them (once per audio buffer, from
      # Manager#update), so no Ruby code runs on a MIDI thread, and no JACK
      # server is ever started.
      #
      # By default a virtual port is created for other programs (DAWs,
      # keyboards' software, qjackctl, qpwgraph, aconnect, Audio MIDI Setup)
      # to connect to, named after the script (see DeviceOutput.client_name).
      # With +:connect+ (or MIDI_DEVICE), the input connects to the first
      # MIDI source whose name contains it (or to that index; see .ports).
      #
      # Environment variables take precedence:
      #   MIDI_API=jack        API: core (macOS), alsa or jack (Linux); by
      #                        default JACK when a JACK server is running,
      #                        else ALSA
      #   MIDI_DEVICE=name     a source to connect to instead of a virtual port
      #
      # Example:
      #     input = MB::Sound::MIDI::Input.new(connect: 'Launchkey')
      #     input.read  # => [[[0.0, "\x90<d"], [0.012, "\x80<\x00"]]]
      class Input
        class << self
          # The MIDI APIs this build supports (:core, :alsa, :jack).
          def apis
            FastMIDI.compiled_apis
          end

          # The MIDI API to use for +api+, MIDI_API, or the platform default
          # (see the class comment).
          def api(api = nil)
            api = ENV['MIDI_API'] if ENV['MIDI_API'] && !ENV['MIDI_API'].empty?
            return api.to_s.delete_prefix(':').to_sym if api

            if apis.include?(:jack) && apis.include?(:alsa)
              DeviceOutput.jack_running? ? :jack : :alsa
            else
              apis.first
            end
          end

          # Lists the names of the MIDI sources that an input can connect to.
          def ports(api: nil)
            FastMIDI.input_ports(self.api(api), DeviceOutput.client_name)
          end

          # Opens an input for a script: connected to +connect+ (part of a
          # source's name) if given, else a virtual port, printing where to
          # connect MIDI and which sources exist (for bin/midi scripts).
          def open_live(connect = nil)
            input = new(connect: connect)
            if input.connected_to
              puts "Reading MIDI from #{input.connected_to} (#{input.api})"
            else
              sources = ports(api: input.api)
              puts "Connect a MIDI source to #{input.connections.first} (#{input.api})"
              puts "or pass part of its name: #{sources.empty? ? 'no sources found' : sources.join(', ')}"
            end
            input
          end
        end

        attr_reader :api, :port_name, :connected_to

        # Opens MIDI input (see the class comment).  +:connect+ is a source
        # index or part of a source's name (nil for a virtual port);
        # +:port_name+ names our port (default: the script's name for
        # CoreMIDI virtual sources, else 'midi_in'); +:queue_size+ messages
        # are kept between reads.
        def initialize(connect: nil, port_name: nil, api: nil, queue_size: 1024)
          @api = self.class.api(api)
          connect = ENV['MIDI_DEVICE'] if ENV['MIDI_DEVICE'] && !ENV['MIDI_DEVICE'].empty?
          client = DeviceOutput.client_name
          @port_name = port_name || (@api == :core && connect.nil? ? client : 'midi_in')

          index = nil
          if connect
            names = FastMIDI.input_ports(@api, client)
            index = Integer(connect) if connect.is_a?(Integer) || connect.to_s =~ /\A\d+\z/
            index ||= names.index { |n| n.downcase.include?(connect.to_s.downcase) }
            if index.nil? || index >= names.length
              list = names.each_with_index.map { |n, i| "  #{i}: #{n}" }.join("\n")
              raise ArgumentError, "No MIDI source matches #{connect.inspect}.  Sources:\n#{list}"
            end
            @connected_to = names[index]
          end

          @input = FastMIDI::Input.new(@api, client, index, @port_name, queue_size)
          DeviceOutput.track(self, true)
        end

        # Returns the messages received since the last read in the form
        # Manager#update expects: [[[seconds, bytes], ...]], with each
        # message's time in seconds after the first one in this read.  With
        # +blocking: true+, waits for at least one message.
        def read(blocking: false)
          messages = @input.read
          while blocking && messages.empty?
            sleep 0.001
            messages = @input.read
          end

          time = 0.0
          events = messages.each_with_index.map { |(delta, bytes), i|
            time += delta if i > 0
            [time, bytes]
          }
          [events]
        end

        # The sources this input is connected to (for Manager#connections).
        def connections
          [@connected_to || "#{DeviceOutput.client_name}:#{@port_name} (virtual)"]
        end

        # Closes the port.  Safe to call more than once.
        def close
          @input.close
          DeviceOutput.track(self, false)
          nil
        end

        def closed?
          @input.closed?
        end

        def to_s
          "#<#{self.class.name} #{@api} #{connections.first}#{' closed' if closed?}>"
        end
        alias inspect to_s
      end
    end
  end
end
