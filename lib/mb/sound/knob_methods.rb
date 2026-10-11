module MB
  module Sound
    # Console methods for knobs (see GraphNode::Knob, Session::Knobs, and
    # design/notes/arrangement.md): named values that graphs read and
    # performers turn, with snapshots to recall and crossfade.  MB::Sound
    # extends itself with this module.
    #
    # Example (bin/sound.rb):
    #     knob :cut, 800, range: 100..8000, curve: :exp, unit: 'Hz'
    #     knob :space, 0.2
    #     bg :bass, 55.hz.ramp.lp4(knob(:cut), resonance: knob(:space) * 0.8).at(-12.db)
    #     turn :cut, 3000                          # now, with a 5 ms glide
    #     turn :cut, 400, over: 2.bars, curve: :smooth, on: :bar
    #     turn :cut, tween([400, 8000, 600], 8.bars)   # follow a node until turned again
    #     move :space, 0.6, in: 1.beat             # (move is turn)
    #     snap :dark; turn :cut, 6000; snap :bright
    #     recall :dark, over: 4.bars
    #     knob :morph, 0; xfade :dark, :bright, :morph; turn :morph, 1, over: 8.bars
    #     learn :cut                               # the next MIDI controller moved
    #     knob :space, cc: 74                      # or a controller number
    #     undo                                     # turns are undoable
    module KnobMethods
      # With a default value or options, defines a knob (or changes an
      # existing knob's options, keeping its value): +range:+ (0..1 by
      # default), +curve:+ (:linear or :exp; the scale for ramps,
      # controllers, and crossfades), +unit:+, +cc:+ (a MIDI controller on
      # live input, see #learn), +takeover:+ (:pickup or :jump), +smooth:+
      # (the glide of turns without +over:+, 5 ms by default; 0 for
      # jumps).  Returns the knob, a GraphNode to use anywhere a graph takes
      # a node: `110.hz.ramp.lp4(knob(:cut))`.  Knob names share a
      # namespace with tracks and mute groups.
      def knob(name, default = nil, **spec)
        session = Session.current
        k = session.knob(name, default, **spec)
        listen_knob_midi(session, k) if k && spec[:cc]
        k
      end

      # Lists the knobs: name => "800 Hz (100..8000 exp) cc74".
      def knobs
        Session.current.knob_info
      end

      # Turns knob +name+ (see Session::Knobs#turn): to a number (right
      # away with a short glide, or at a launch point: +on:+, +in:+,
      # +at:+), over +over:+ (bars, a Duration, or a Length) shaped by
      # +curve:+, or following a node or another knob's name until it is
      # turned again.  Returns the change's journal entry.  Also available
      # as #move.
      def turn(name, value = nil, at: nil, on: nil, in: nil, over: nil, curve: nil, follow: nil, smooth: nil)
        point = LaunchPoint.of(binding) or return nil
        name = knob_name(name)
        session_command(name, label: "turn #{name.inspect}", kind: :turn) { |session, time|
          session.turn(name, value, at: point, over: over, curve: curve, follow: follow, smooth: smooth, start_time: point.given? ? nil : time)
        }
      end
      alias move turn

      # Remembers every knob's value as snapshot +name+ (at the launch
      # point; now by default).  Returns the journal entry.
      def snap(name, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        session_command(name, label: "snap #{name.inspect}", kind: :snap) { |session, time|
          session.snap(name, at: point, start_time: point.given? ? nil : time)
        }
      end

      # The snapshots: name => { knob => value }.
      def snaps
        Session.current.snapshots
      end

      # Turns every knob in snapshot +name+ back (see #turn for +over:+ and
      # +curve:+).  Returns the journal entries.
      def recall(name, at: nil, on: nil, in: nil, over: nil, curve: nil)
        point = LaunchPoint.of(binding) or return nil
        knob_entries(session_command(name, label: "recall #{name.inspect}") { |session, time|
          session.recall(name, at: point, over: over, curve: curve, start_time: point.given? ? nil : time)
        })
      end

      # Moves every knob +amount+ of the way from snapshot +a+ to snapshot
      # +b+ (0..1), or makes them follow +amount+ if it is a node or a knob
      # name (a crossfader).  Returns the journal entries.  Also available
      # as #crossfade.
      def xfade(a, b, amount = 0.5, at: nil, on: nil, in: nil, over: nil, curve: nil)
        point = LaunchPoint.of(binding) or return nil
        knob_entries(session_command(a, label: "xfade #{a.inspect}, #{b.inspect}") { |session, time|
          session.xfade(a, b, amount, at: point, over: over, curve: curve, start_time: point.given? ? nil : time)
        })
      end
      alias crossfade xfade

      # Makes knob +name+ follow the next MIDI controller moved on live
      # input (#midi_stream; see GraphNode::Knob#listen for :pickup and
      # :jump takeover).  Returns the knob.
      def learn(name)
        session = Session.current
        k = session.knob!(knob_name(name))
        listen_knob_midi(session, k)
        session.learn(k.name)
      end

      private

      # A knob name given to a command: a Symbol, or a knob.
      def knob_name(name)
        return name.knob.name if name.is_a?(GraphNode::Knob::Reader)
        return name.name if name.is_a?(GraphNode::Knob)
        name
      end

      # Points knobs at live MIDI input (unless a stream was set).
      def listen_knob_midi(session, k)
        if session.knob_midi.nil?
          begin
            session.knob_midi = midi_stream
          rescue => e
            warn "Knob #{k.name.inspect}: no live MIDI input (#{e.class}: #{e.message})"
            return
          end
        end
        k.listen(session.knob_midi) unless k.listening
      end

      # Journal entries for the changes a command returned.
      def knob_entries(value)
        return value unless value.is_a?(Array) && value.all?(Session::Changes::Change)
        session = Session.current
        value.map { |c| session.journal[c.seq] }
      end
    end
  end
end
