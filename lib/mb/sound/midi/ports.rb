module MB
  module Sound
    module MIDI
      # Lists and finds MIDI ports by name, for MIDI outputs (MIDI::Destination,
      # `midi_out`), the console's `midi_ports`, the device browser pane, and
      # anything else that connects to a device by part of its name.
      #
      # Under JACK (jackd or PipeWire's) the ports are the JACK MIDI ports of
      # every client (hardware bridged by the server and other programs);
      # otherwise RtMidi's lists (ALSA sequencer, CoreMIDI).  Nothing here
      # starts a process: JACK lists come from the JACK API on the shared
      # client, RtMidi lists from RtMidi.
      #
      # Directions are from mb-sound's side: :out ports are destinations we
      # can send to (a synth's input), :in ports are sources we can read
      # (a keyboard's output).
      #
      #     MIDI::Ports.list(:out)              # => [#<Port out jack "Midi-Bridge:KRONOS ...">, ...]
      #     MIDI::Ports.find('kronos', :out)    # one Port, or Ambiguous / NotFound
      module Ports
        # One MIDI port: +api+ (:jack, :alsa, :core), +name+ (the full name:
        # "client:port" on JACK and ALSA), +client+ and +port+ (its two
        # parts; +client+ nil when the name has no client part), +direction+
        # (:out or :in, see Ports), +connections+ (full names of the ports
        # connected to it; JACK only, else an empty Array), +physical+ (true
        # for hardware ports JACK marks physical), +own+ (true for ports of
        # this process's JACK client), and +index+ (its position in the
        # RtMidi list, for opening it; nil on JACK).
        Port = Data.define(:api, :name, :client, :port, :direction, :connections, :physical, :own, :index) do
          # The one-line row `midi_ports` prints.
          def to_s
            conn = connections.empty? ? '' : " -> #{connections.join(', ')}"
            flags = [(:hw if physical), (:ours if own)].compact
            "#{direction == :out ? 'out' : 'in '}  #{name}#{" (#{flags.join(', ')})" unless flags.empty?}#{conn}  [#{api}]"
          end
          alias_method :inspect, :to_s
        end

        # Raised by .find when several ports match.  #candidates lists them.
        class Ambiguous < ArgumentError
          attr_reader :candidates

          def initialize(message, candidates)
            super(message)
            @candidates = candidates
          end
        end

        # Raised by .find when no port matches.
        class NotFound < ArgumentError
          attr_reader :names

          def initialize(message, names)
            super(message)
            @names = names
          end
        end

        DIRECTIONS = [:out, :in].freeze

        class << self
          # The MIDI ports of +direction+ (:out, :in, or nil for both) on
          # +api+ (default: MIDI::Input.api, JACK when a server answers),
          # destinations first.  +:all+ for +api+ lists every compiled API.
          def list(direction = nil, api: nil)
            dirs = direction.nil? ? DIRECTIONS : [check_direction(direction)]
            apis = api == :all ? Input.apis : [Input.api(api)]
            apis.flat_map { |a|
              dirs.flat_map { |d|
                begin
                  a == :jack ? jack_ports(d) : rtmidi_ports(a, d)
                rescue FastMIDI::Error, FastAudio::Error
                  raise if apis.length == 1 && !api.nil?
                  []
                end
              }
            }
          end

          # The one port of +direction+ whose name contains +name+ (ignoring
          # case), searching the default API first and then the others (as
          # MIDI::Input.find_port does).  A port whose whole name, port part,
          # or client part equals +name+ wins over ports that only contain
          # it.  Ports of this process's own JACK client are left out unless
          # +own:+ is true.  Raises Ambiguous (with the candidates) when
          # several match, NotFound (with a did-you-mean) when none do.
          def find(name, direction, api: nil, own: false)
            direction = check_direction(direction)
            raise ArgumentError, 'Give part of a MIDI port name (a String)' if name.nil? || name.to_s.empty?

            text = name.to_s.downcase
            seen = []
            search_apis(api).each do |a|
              ports = begin
                a == :jack ? jack_ports(direction) : rtmidi_ports(a, direction)
              rescue FastMIDI::Error, FastAudio::Error
                []
              end
              ports = ports.reject(&:own) unless own
              seen.concat(ports)

              matches = ports.select { |p| p.name.downcase.include?(text) }
              next if matches.empty?

              exact = matches.select { |p| [p.name, p.port, p.client].compact.any? { |n| n.downcase == text } }
              matches = exact if exact.length == 1
              return matches.first if matches.length == 1

              raise Ambiguous.new(
                "#{matches.length} MIDI #{direction == :out ? 'destinations' : 'sources'} match #{name.to_s.inspect}; " \
                "say more of the name:\n#{matches.map { |p| "  #{p.name}" }.join("\n")}",
                matches
              )
            end

            names = seen.map(&:name)
            raise NotFound.new(
              "No MIDI #{direction == :out ? 'destination' : 'source'} matches #{name.to_s.inspect}#{did_you_mean(name, seen)}.  " \
              "#{direction == :out ? 'Destinations' : 'Sources'}:\n#{names.empty? ? '  (none)' : names.map { |n| "  #{n}" }.join("\n")}",
              names
            )
          end

          private

          def check_direction(direction)
            d = { output: :out, input: :in, destination: :out, source: :in }.fetch(direction, direction)
            return d if DIRECTIONS.include?(d)
            raise ArgumentError, "MIDI port directions are :out (destinations) or :in (sources) (got #{direction.inspect})"
          end

          def search_apis(api)
            first = Input.api(api)
            return [first] if api || (ENV['MIDI_API'] && !ENV['MIDI_API'].empty?)
            rest = Input.apis - [first]
            rest -= [:jack] unless DeviceOutput.jack_running?
            [first, *rest]
          end

          def jack_ports(direction)
            Jack.open
            own = "#{Jack.client_name}:"
            flags = direction == :out ? FastAudio::JACK_PORT_IS_INPUT : FastAudio::JACK_PORT_IS_OUTPUT
            physical = FastAudio.jack_ports(nil, true, flags | FastAudio::JACK_PORT_IS_PHYSICAL)
            FastAudio.jack_ports(nil, true, flags).map { |n|
              client, port = n.split(':', 2)
              Port.new(api: :jack, name: n, client: client, port: port, direction: direction,
                       connections: FastAudio.jack_connections(n), physical: physical.include?(n),
                       own: n.start_with?(own), index: nil)
            }
          end

          def rtmidi_ports(api, direction)
            names = Input.port_names(api, direction == :out ? :output : :input)
            names.each_with_index.map { |n, i|
              client, port = n.include?(':') ? n.split(':', 2) : [nil, n]
              Port.new(api: api, name: n, client: client, port: port, direction: direction,
                       connections: [], physical: false, own: false, index: i)
            }
          end

          def did_you_mean(name, ports)
            words = ports.flat_map { |p| [p.name, p.port, p.client].compact }.uniq
            # (DidYouMean loads with Ruby unless --disable-did_you_mean)
            return '' unless defined?(DidYouMean::SpellChecker)
            s = DidYouMean::SpellChecker.new(dictionary: words).correct(name.to_s).first
            s ? " (did you mean #{s.inspect}?)" : ''
          end
        end
      end
    end
  end
end
