module MB
  module Sound
    module UI
      class Keyboard
        # Where the virtual keyboard's notes go: a MIDI::VirtualInput read
        # by a LiveSource, added to the current Session's MIDI input
        # (Session::MidiInput#add_source; the default input unless +input:+
        # names one), so typed notes land on exact frames beside a hardware
        # keyboard's and reach armed tracks' monitors, `rec`, `capture`,
        # the console's `midi`, and takes.
        #
        # With nothing armed, #ensure_monitor plays the input through a
        # default patch (a player named MONITOR) so the keys always make a
        # sound; it rings out when a track is armed.  +patch:+ nil turns
        # that off, or a block takes a voice's Notes (`->(v) { v.hz.square
        # * v.amp_env }`).
        class Link
          # The default patch's player.
          MONITOR = :'keyboard/live'

          # The default patch: play's soft filtered saw (one patch for
          # notes without a sound of their own; see Playable::PATCH).
          PATCH = Playable::PATCH

          attr_reader :input, :session, :virtual

          # The block for the default patch (nil: none).
          attr_accessor :patch

          def initialize(input: nil, patch: PATCH, session: nil)
            @input = input
            @patch = patch
            @fixed_session = session
            @session = nil
            @virtual = nil
            @source = nil
            @monitor = false
            @lock = Mutex.new
          end

          # The Session notes go to (the current one unless given).
          def target_session
            @fixed_session || Session.current
          end

          # Adds the virtual input to the Session's MIDI input (again after
          # the current Session changed).  Returns the VirtualInput.
          def attach
            @lock.synchronize do
              s = target_session
              if s.equal?(@session) && @virtual
                # Follow the output's clock once it opens (see LiveSource)
                @source.output = s.output if @source.output.nil? && s.output_open?
                return @virtual
              end

              @session = s
              @monitor = false
              @virtual = MIDI::VirtualInput.new('keyboard')
              @source = MIDI::LiveSource.new(@virtual, output: s.output_open? ? s.output : nil)
              s.midi_in(@input).add_source(MIDI::Stream.new(@source))
              @virtual
            end
          end

          # Starts the default patch if nothing is armed (and it isn't
          # playing), or rings it out once a track is armed.  Returns the
          # monitor's state (true while it plays).
          def ensure_monitor
            s = target_session
            attach
            armed = s.arrangement.armed
            if !armed.empty?
              if @monitor
                @monitor = false
                s.remove(MONITOR, ring: true) rescue nil
              end
            elsif @patch && !@monitor && !s.players.key?(MONITOR)
              patch = @patch
              notes = MB::Sound::Notes.new(s.midi_in(@input).stream, sustain: true)
              graph = notes.synth(voices: 8) { |v| patch.call(v) }
              s.add(graph, name: MONITOR, on: :now, fade: 0, description: 'keyboard: default patch (nothing armed)')
              @monitor = true
            end
            @monitor
          end

          # Stops the default patch.
          def stop_monitor
            return unless @monitor && @session
            @monitor = false
            @session.remove(MONITOR, ring: true) rescue nil
          end

          # True while the default patch plays (as far as this link knows).
          def monitor? = @monitor

          def note_on(note, velocity, channel: 0, time: nil)
            v = attach
            if @monitor && !@session.arrangement.armed.empty?
              stop_monitor
            end
            time ? v.note_on(note, velocity, channel: channel, time: time) : v.note_on(note, velocity, channel: channel)
          end

          def note_off(note, velocity = MIDI::Event::DEFAULT_RELEASE / 127.0, channel: 0, time: nil)
            v = @virtual or return
            time ? v.note_off(note, velocity, channel: channel, time: time) : v.note_off(note, velocity, channel: channel)
          end

          def cc(index, value, channel: 0, time: nil)
            v = @virtual or return
            time ? v.cc(index, value, channel: channel, time: time) : v.cc(index, value, channel: channel)
          end
        end
      end
    end
  end
end
