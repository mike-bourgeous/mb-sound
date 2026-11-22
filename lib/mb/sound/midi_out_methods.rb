module MB
  module Sound
    # Console commands for playing hardware synths and other programs from
    # tracks (design/notes/midi.md, MIDI out): `midi_out` makes a MIDI
    # destination a track plays to, `midi_ports` lists the MIDI ports.
    module MidiOutMethods
      # A MIDI destination for a track (a MIDI::Destination): +name+ is part
      # of the port's name (case-insensitive; a hardware synth bridged by
      # JACK or PipeWire, another program's MIDI input, an ALSA or CoreMIDI
      # port), +channel:+ 1 to 16, +program:+ 1 to 128 and +bank:+ (an MSB,
      # or [MSB, LSB]) sent when the track starts, +offset:+ how much later
      # than mb-sound's own audio of the same moment the notes leave (a
      # Length, e.g. 4.ms; negative for earlier; `dest.offset = 6.ms` while
      # it plays).  +port:+ instead makes a port of our own, unconnected,
      # for another program to connect to.  +cc:+ binds Session knobs to
      # the synth's controllers (`cc: { cut: 74 }`: turning :cut sends CC
      # 74 while the track plays).
      #
      # Notes leave lined up with mb-sound's audio at the speakers: on JACK
      # exactly (the output queue's latency added to each message's frame),
      # elsewhere when the render makes them.  A name that matches several
      # ports lists them; one that matches none warns live (the track stays
      # silent) and lists what is there.
      #
      #     midi_ports
      #     track :kronos, midi_out('KRONOS', channel: 1, program: 12)
      #     bg :kronos, seq(C3, E3, G3, B3).n8.loop
      #     track :surge, midi_out('Surge XT', channel: 2)
      #     midi_out('SQ-80').test          # a test note: which synth is it?
      def midi_out(name = nil, channel: 1, program: nil, bank: nil, offset: 0, port: nil, cc: nil, log: false)
        MIDI::Destination.new(name, channel: channel, program: program, bank: bank, offset: offset, port: port, cc: cc, log: log)
      end

      # Lists the MIDI ports (MIDI::Ports::Port rows): +direction+ :out for
      # destinations (synths, other programs' inputs), :in for sources
      # (keyboards, other programs' outputs), nil for both.  Each row names
      # the port, its connections, and the tracks playing to it.
      #
      #     midi_ports        # out  Midi-Bridge:KRONOS ... -> sound:midi_out
      #     midi_ports :out
      def midi_ports(direction = nil)
        rows = MIDI::Ports.list(direction)
        MidiOutMethods.listing(rows, MidiOutMethods.track_ports(Session.existing))
      rescue FastMIDI::Error, FastAudio::Error => e
        MB::Sound.live_error(e)
      end
      alias midi_devices midi_ports

      # A listing that prints one port per line (see #midi_ports).
      class Listing < Array
        def initialize(rows, tracks)
          super(rows)
          @tracks = tracks
        end

        # Track names playing to +port+ (a Port).
        def tracks_for(port)
          @tracks.select { |_, (api, name)| api == port.api && (name == port.name || port.connections.include?(name)) }.keys
        end

        def to_s
          return '(no MIDI ports)' if empty?
          map { |p|
            t = tracks_for(p)
            "#{p}#{"  tracks: #{t.map(&:inspect).join(', ')}" unless t.empty?}"
          }.join("\n")
        end

        def pretty_print(q)
          q.text(to_s)
        end

        def inspect
          to_s
        end
      end

      class << self
        # See Listing.
        def listing(rows, tracks)
          Listing.new(rows, tracks)
        end

        # Track name => [api, port name] for every track of +session+ that
        # plays to a MIDI destination (the device port, or our own port).
        def track_ports(session)
          return {} unless session
          session.arrangement.tracks.filter_map { |name, tr|
            d = Arrangement::InstrumentPatch.voice_of(tr.patch)
            next unless d.is_a?(MIDI::Destination)
            if d.port
              [name, [d.port.api, d.port.name]]
            elsif d.output
              [name, [d.output.api, d.output.port]]
            end
          }.to_h
        end
      end
    end
  end
end
