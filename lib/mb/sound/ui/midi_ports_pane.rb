module MB
  module Sound
    module UI
      module Panes
        # The MIDI device browser (midi-out-1; the maintainer, 2026-11-22: "a
        # MIDI device browser in the UI with corresponding syntax for having
        # a track play out to a MIDI device"): MIDI destinations, then
        # sources (MIDI::Ports.list: hardware bridged by JACK or PipeWire,
        # other programs' ports, ALSA or CoreMIDI ports), each with its
        # connections, the tracks playing to it, and a blip while mb-sound
        # sends to it.
        #
        # The list is read at most once a second (Ports.list: the JACK API on
        # the shared client, or RtMidi's lists; never the render lock, never
        # a subprocess), the tracks from the Arrangement (its own lock).
        #
        # Mode keys: Up/Down pick a port; Enter (and e) put `track :name,
        # midi_out("port")` on the console to name and run; a or Space play
        # a test note on the picked destination; x all notes off on every
        # channel of its port (`midi_out("port").panic(:all)`).
        class MidiPorts < Pane
          # Seconds between port list reads.
          REFRESH = 1.0

          # Seconds a send blip shows.
          BLIP = 0.3

          def initialize = super(:midi_ports, rate: 4, height: 8, width: 52, title: 'midi ports', min_height: 2,
                                              description: 'MIDI devices and programs: destinations and sources, their connections, the tracks playing to them (Enter: a track line; a: a test note)')

          mode_keys do
            group 'MIDI ports'
            on [:up, 'k'], :pick_port, -1, help: 'the port before, after', label: 'Up Down'
            on [:down, 'j'], :pick_port, 1, help: 'the port before, after', label: 'Up Down'
            on :enter, :track_line, help: 'a track playing to the picked destination onto the console (name it, Enter runs it)'
            on 'e', :edit_line, help: PaneKeys::EDIT_HELP
            on ['a', ' '], :test_note, help: 'a test note on the picked destination (which synth is it?)', label: 'a Space'
            on 'x', :port_panic, help: 'all notes off on every channel of the picked destination'
          end

          def draw_body(c, _s, state)
            ports = refresh(state)
            if ports.empty?
              c.puts [state[:error] || 'no MIDI ports (is JACK or the MIDI device up?)', :dim]
              return
            end
            tracks = state[:tracks] || {}
            pick = state[:mode] ? picked_index(state, ports) : nil
            first = pick ? [[pick - c.h + 1, 0].max, 0].max : 0
            ports[first, c.h].each_with_index do |p, i|
              y = i
              sel = pick == first + i
              arrow = p.direction == :out ? '→ ' : '← '
              x = c.line(y, [arrow, sel ? :key : :dim])
              x = sel ? c.run(x, y, p.name, :key, reverse: true) : c.text(x, y, p.name, p.own ? :dim : :name)
              blip = blip?(state, p)
              x = c.text(x + 1, y, '●', :warn) if blip
              names = tracks.select { |_, (api, n)| api == p.api && (n == p.name || p.connections.include?(n)) }.keys
              extra = []
              extra << names.map(&:inspect).join(' ') unless names.empty?
              extra << "↔ #{p.connections.length}" unless p.connections.empty?
              extra << 'hw' if p.physical
              c.text_fit(x + 1, y, extra.join('  '), [c.w - x - 1, 0].max, :dim) unless extra.empty?
            end
          end

          # Up/Down: the port before or after the picked one.
          def key_pick_port(state, d)
            ports = refresh(state)
            return 'no MIDI ports' if ports.empty?
            i = (picked_index(state, ports) + d).clamp(0, ports.length - 1)
            p = ports[i]
            state[:pick] = [p.api, p.name, p.direction]
            "#{p.direction == :out ? 'destination' : 'source'} #{p.name}#{p.direction == :out ? ' (Enter: a track line, a: a test note)' : ''}"
          end

          def key_scroll(state, *) = key_pick_port(state, 1)

          # Enter: `track :name, midi_out("port")` onto the console.
          def key_track_line(state)
            r = edit_line(state)
            return r if r.is_a?(String)
            PaneKeys::Paste[r.code, 'name the track, then Enter runs it']
          end

          # e: Enter's line (PaneKeys#key_edit_line).
          def edit_line(state)
            p = picked(state) or return 'no MIDI ports'
            return "#{p.name} is a source (keyboards and programs sending MIDI): arm a track and connect it (MIDI_DEVICE, midi)" unless p.direction == :out
            PaneKeys::Run["track #{MidiPorts.track_name(p).inspect}, midi_out(#{p.name.inspect})"]
          end

          # a, Space: a test note on the picked destination, now.
          def key_test_note(state)
            p = picked(state) or return 'no MIDI ports'
            return "#{p.name} is a source; pick a destination (→) for a test note" unless p.direction == :out
            MIDI::Destination.new(p.name).test
            "test note (C4) on #{p.name}"
          rescue ArgumentError, IOError, FastAudio::Error, FastMIDI::Error => e
            "no test note: #{e.message.lines.first.strip}"
          end

          # x: all notes off on every channel of the picked destination.
          def key_port_panic(state)
            p = picked(state) or return 'no MIDI ports'
            return "#{p.name} is a source; x sends all notes off to a destination (→)" unless p.direction == :out
            PaneKeys::Run["midi_out(#{p.name.inspect}).panic(:all)", "all notes off on #{p.name}"]
          end

          # A track name for port +p+: its first word with letters (not
          # midi, playback, capture, port, bridge), else :synth.
          def self.track_name(p)
            skip = %w[midi playback capture port bridge out in through system client]
            words = "#{p.port} #{p.client}".downcase.scan(/[a-z][a-z0-9_]*/)
            w = words.find { |x| x.length > 1 && !x.split('_').all? { |part| skip.include?(part) || part.match?(/\A\d*\z/) } }
            w ? w.to_sym : :synth
          end

          private

          # The port list, read at most every REFRESH seconds into +state+.
          def refresh(state)
            now = MB::U.clock_now
            if state[:ports].nil? || now - (state[:at] || 0) >= REFRESH
              state[:at] = now
              begin
                state[:ports] = MIDI::Ports.list.sort_by { |p| [p.direction == :out ? 0 : 1, p.own ? 1 : 0, p.name] }.freeze
                state[:error] = nil
              rescue FastMIDI::Error, FastAudio::Error => e
                state[:ports] = [].freeze
                state[:error] = "MIDI ports: #{e.message.lines.first.strip}"
              end
              state[:tracks] = MidiOutMethods.track_ports(Session.existing)
              state[:sent] = sent_counts
            end
            state[:ports]
          end

          # Messages sent so far by each shared output, by the port it
          # connects to.
          def sent_counts
            MIDI::Destination.outputs.to_h { |(_api, name), o|
              st = o.stats
              [name, (st[:messages] || 0) + (st[:timed_sent] || 0)]
            }
          end

          # True while mb-sound has sent to +p+ in the last BLIP seconds.
          def blip?(state, p)
            return false unless p.direction == :out
            now = MB::U.clock_now
            last = (state[:last_sent] ||= {})
            sent = (state[:sent] || {})[p.name]
            return false unless sent
            seen = last[p.name]
            if seen.nil? || seen[0] != sent
              last[p.name] = [sent, seen ? now : 0]
            end
            now - last[p.name][1] < BLIP
          end

          def picked(state)
            ports = refresh(state)
            ports.empty? ? nil : ports[picked_index(state, ports)]
          end

          def picked_index(state, ports)
            want = state[:pick]
            (want && ports.index { |p| [p.api, p.name, p.direction] == want }) || 0
          end
        end
      end
    end
  end
end
