module MB
  module Sound
    module MIDI
      # Live MIDI input: JACK MIDI ports on the script's one JACK client (with
      # its audio ports; see MB::Sound::Jack and FastAudio::JackMIDIInput) when
      # a JACK server answers (jackd, or PipeWire's JACK), else RtMidi (the
      # fast_midi C extension; MB::Sound::FastMIDI::Input): CoreMIDI on
      # macOS, the ALSA sequencer on Linux.  A C thread queues messages and
      # #read polls them (once per audio buffer, from Manager#update), so no
      # Ruby code runs on a MIDI thread, and no JACK server is ever started.
      #
      # By default the input is a port for other programs (DAWs, keyboards'
      # software, qjackctl, qpwgraph, aconnect, Audio MIDI Setup) to connect
      # to: midi_in on JACK, else a virtual port named after the script (see
      # DeviceOutput.client_name).  With +:connect+ (or MIDI_DEVICE), it also
      # connects to the first MIDI source whose name contains it (or to that
      # index; see .ports), searching the other API's ports too (see
      # .find_port).
      #
      # Environment variables take precedence:
      #   MIDI_API=jack        API: core (macOS), alsa or jack (Linux); by
      #                        default JACK when a JACK server answers
      #                        (jackd, or PipeWire's JACK), else ALSA
      #   MIDI_DEVICE=name     a source to connect to instead of a virtual port
      #
      # Example:
      #     input = MB::Sound::MIDI::Input.new(connect: 'Launchkey')
      #     input.read  # => [[[0.0, "\x90<d"], [0.012, "\x80<\x00"]]]
      class Input
        class << self
          # The MIDI APIs available: RtMidi's (:core, :alsa) plus :jack (the
          # shared JACK client, loaded at run time) except on macOS, where
          # CoreMIDI covers everything.
          def apis
            rtmidi = FastMIDI.compiled_apis - [:jack]
            RUBY_PLATFORM =~ /darwin/ ? rtmidi : rtmidi + [:jack]
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

          # Names of the MIDI sources (+kind+ :input) or destinations
          # (:output) on +api+.  JACK lists open the shared client.
          def port_names(api, kind)
            if api == :jack
              Jack.open
              flags = kind == :input ? FastAudio::JACK_PORT_IS_OUTPUT : FastAudio::JACK_PORT_IS_INPUT
              FastAudio.jack_ports(nil, true, flags)
            else
              client = DeviceOutput.client_name
              kind == :input ? FastMIDI.input_ports(api, client) : FastMIDI.output_ports(api, client)
            end
          end

          # Finds the first MIDI port whose name contains +connect+ (or, in
          # the first API searched, has that index): sources for +kind+
          # :input, destinations for :output.  Without an explicit +api+ or
          # MIDI_API, ports of the other compiled APIs are searched after the
          # default one: ALSA sequencer ports (hardware that plain jackd
          # doesn't bridge) when JACK is the default, and JACK only when a
          # JACK server answers (DeviceOutput.jack_running?).
          #
          # Returns [api, index, name, {api => [names]}] (index and name nil
          # when nothing matched; api is then the default API).
          def find_port(connect, kind:, api: nil)
            lists = {}
            search_apis(api).each_with_index do |a, i|
              names = begin
                port_names(a, kind)
              rescue FastMIDI::Error, FastAudio::Error
                # e.g. no ALSA sequencer device; the other APIs may still work
                raise if i == 0 && search_apis(api).length == 1
                []
              end
              lists[a] = names

              index = nil
              index = Integer(connect) if i == 0 && (connect.is_a?(Integer) || connect.to_s =~ /\A\d+\z/)
              index ||= names.index { |n| n.downcase.include?(connect.to_s.downcase) }
              return [a, index, names[index], lists] if index && index < names.length
            end

            [lists.keys.first, nil, nil, lists]
          end

          # Formats the port lists from .find_port for error messages.
          def port_list(lists)
            lines = lists.flat_map { |a, names|
              names.each_with_index.map { |n, i| "  #{i}: #{n}#{" (#{a})" if lists.length > 1}" }
            }
            lines.empty? ? '  (none)' : lines.join("\n")
          end

          # Lists the names of the MIDI sources that an input can connect to.
          def ports(api: nil)
            port_names(self.api(api), :input)
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
              puts "Connect a MIDI source to #{input.port} (#{input.api})"
              puts "or pass part of its name: #{sources.empty? ? 'no sources found' : sources.join(', ')}"
            end
            input
          end

          private

          # The default API, then (without an explicit choice) the others.
          def search_apis(api)
            chosen = self.api(api)
            return [chosen] if api || (ENV['MIDI_API'] && !ENV['MIDI_API'].empty?)

            others = apis - [chosen]
            others.delete(:jack) unless DeviceOutput.jack_running?
            [chosen, *others]
          end
        end

        attr_reader :api, :port_name, :connected_to

        # Opens MIDI input (see the class comment).  +:connect+ is a source
        # index or part of a source's name (nil to only wait for
        # connections); +:port_name+ names our port (default: midi_in, or
        # midi_in_2 etc. on JACK if taken; the script's name for CoreMIDI
        # virtual sources); +:queue_size+ messages are kept between reads.
        def initialize(connect: nil, port_name: nil, api: nil, queue_size: 1024)
          @api = self.class.api(api)
          connect = ENV['MIDI_DEVICE'] if ENV['MIDI_DEVICE'] && !ENV['MIDI_DEVICE'].empty?
          client = DeviceOutput.client_name

          index = nil
          if connect
            found_api, index, @connected_to, lists = self.class.find_port(connect, kind: :input, api: api)
            if index
              @api = found_api
            else
              # Like the old JACK input: open an unconnected port that can be
              # wired later (e.g. with qpwgraph) instead of failing.
              warn "No MIDI source matches #{connect.inspect}; opening an unconnected port.  Sources:\n#{self.class.port_list(lists)}"
              connect = nil
            end
          end

          if @api == :jack
            @port_name = port_name || Jack.port_names('midi_in', 1, numbered: false).first
            @input = FastAudio::JackMIDIInput.new(client, @port_name, queue_size * 16)
            @rate = Jack.info[:sample_rate].to_f
            FastAudio.jack_connect(@connected_to, @input.port_name) if @connected_to
          else
            @port_name = port_name || (@api == :core && connect.nil? ? client : 'midi_in')
            @input = FastMIDI::Input.new(@api, client, index, @port_name, queue_size)
          end

          DeviceOutput.track(self, true)
        end

        # Returns the messages received since the last read in the form
        # Manager#update expects: [[[seconds, bytes], ...]], with each
        # message's time in seconds after the first one in this read.  With
        # +blocking: true+, waits for at least one message.
        def read(blocking: false)
          return [jack_events(@input.read(blocking))] if @api == :jack

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

        # Returns the messages received since the last read with their
        # timestamps as the API gives them (for MIDI::LiveSource; #read is
        # the old Manager's format): on JACK (#frame_times?), [[frame,
        # bytes], ...] with absolute JACK frame times (JACK's 32-bit frame
        # counter, which wraps; #frame_rate frames per second); with RtMidi,
        # [[delta, bytes], ...] with each message's time in seconds after the
        # previous message received (across reads; 0 for the first message
        # since opening).  Never waits.
        def read_raw
          @api == :jack ? @input.read(false) : @input.read
        end

        # True if #read_raw gives JACK frame times, false for RtMidi deltas.
        def frame_times?
          @api == :jack
        end

        # The rate of #read_raw's JACK frame times (the JACK server's sample
        # rate), or nil for RtMidi.
        def frame_rate
          @rate
        end

        # This input's port: the full JACK name (client:port), or a
        # description of the RtMidi port.
        def port
          @api == :jack ? (@input.port_name || "#{Jack.client_name}:#{@port_name}") : "#{DeviceOutput.client_name}:#{@port_name} (virtual)"
        end

        # The sources this input is connected to (for Manager#connections).
        # On JACK these are its live connections (including any made in
        # qpwgraph etc.), or the port itself while unconnected.
        def connections
          if @api == :jack
            live = @input.closed? ? [] : Jack.connections(@input.port_name)
            return live.empty? ? [port] : live
          end

          [@connected_to || port]
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

        private

        # JACK frame times to seconds after the first message in the read
        def jack_events(messages)
          return [] if messages.empty?

          first = messages[0][0]
          messages.map { |frame, bytes| [((frame - first) & 0xffff_ffff) / @rate, bytes] }
        end

        public

        def to_s
          "#<#{self.class.name} #{@api} #{connections.first}#{' closed' if closed?}>"
        end
        alias inspect to_s
      end
    end
  end
end
