require_relative 'midi_input'
require_relative 'live_clip'

module MB
  module Sound
    class Session
      # MIDI input on a Session (see MidiInput and design/notes/arrangement.md,
      # Recording): one MidiInput per input name (nil for the default live
      # input), read once per span before changes land and graphs render, and
      # the Session's MIDI log, which takes save so replays play the same
      # MIDI on the same frames.
      module MidiIn
        # Undo subject of a wire input's changes (:wire, :unwire, and their
        # restores; subject the input's name, :"lead/wire"): the stream
        # wired into it.
        WireSubject = Data.define(:name)
        Undo.subject WireSubject, snapshot: :wire_undo_snapshot, restore: :restore_wire_change
        Undo.claim :wire_undo_subject, order: 50

        # The MidiInput named +name+ (nil for the default), created when
        # first needed (without an input: see MidiInput#input=, or the
        # console's MidiMethods#midi, which attaches live input).
        def midi_in(name = nil)
          @midi_lock.synchronize {
            @midi_inputs[name] || begin
              m = @midi_inputs[name] = MidiInput.new(self, name)
              m.replay([], base_epoch: @replay_epoch || 0) if @replay_mode
              # Wire inputs read after the others: their streams may read
              # the others' taps (`wire :lead, midi.arp(:up)`)
              plain, wires = @midi_inputs.values.partition { |i| !i.wire_input? }
              @midi_pump = (plain + wires).freeze
              m
            end
          }
        end

        # Wires +stream+ (a MIDI::Stream or anything MIDI::Stream.for takes:
        # a transform chain, a Notes, a clip's stream, a MIDI file; nil to
        # unwire) into the wire input named +name+ (see
        # Session::Name.wire) at timeline position +time+ (nil or a past
        # time for now), as a :wire change (an :unwire one for nil): the
        # stream's events play into the input from the exact frame where
        # the change lands, at any buffer size, and what reads the input
        # (a track's monitor, `rec`, `capture`, the MIDI log takes keep)
        # hears it as live input.  Undoable (WireSubject).  Returns the
        # Change.
        def wire_midi(name, stream, time, data: {})
          raise ArgumentError, "#{name.inspect} isn't a wire input name (Session::Name.wire(:lead))" unless Name.wired(name)
          hub = midi_in(name)
          stream = MIDI::Stream.for(stream) if stream
          change(stream ? :wire : :unwire, name, time, data: data) { |t| hub.wire_to(stream, pos: t) }
        end

        # The MidiInputs (a Hash from name to MidiInput).
        def midi_inputs
          @midi_lock.synchronize { @midi_inputs.dup }
        end

        # The notes held now on every MIDI input (frozen UI::HeldNotes; see
        # MidiInput#held_notes), for the terminal UI's keyboard pane.
        def held_notes
          inputs = @midi_lock.synchronize { @midi_inputs.values }
          return [].freeze if inputs.empty?
          return inputs[0].held_notes if inputs.length == 1
          inputs.flat_map(&:held_notes).freeze
        end

        # Every MIDI event the Session's inputs read, oldest first: [input
        # name, epoch, pos, bytes] (see Take).
        def midi_log(from = 0)
          @midi_lock.synchronize { @midi_log[from..] || [] }
        end

        # The number of events in #midi_log so far.
        def midi_log_length
          @midi_lock.synchronize { @midi_log.length }
        end

        # Puts this (fresh) Session in replay mode: every MidiInput, now or
        # later, plays recorded events (see Take::Replay) instead of
        # reading live input; +epoch+ is the epoch the replay starts in.
        def replay_midi!(epoch = 0)
          @replay_mode = true
          @replay_epoch = epoch
          midi_inputs.each_value { |m| m.replay([], base_epoch: epoch) unless m.replaying? }
        end

        # Ends replay mode (see #replay_midi!): inputs read live input again
        # once it is attached (e.g. by the console's MidiMethods#midi).
        def end_replay_midi!
          @replay_mode = false
          midi_inputs.each_value(&:end_replay)
        end

        # The names of knobs listening to +input+ that follow controller
        # +cc+ (for :cc journal entries).
        def knobs_on_cc(input, cc)
          knobs.values.select { |k| k.listening.equal?(input) && k.cc == cc }.map(&:name)
        end

        private

        def init_midi_in
          @midi_lock = Mutex.new
          @midi_inputs = {}
          @midi_pump = [].freeze # (#midi_inputs in the order #pump_midi reads them)
          @midi_log = []
          @replay_mode = false
        end

        # Reads every MidiInput for the span (called by #render_span).
        def pump_midi(frame, count, from, per_sample)
          return if @midi_inputs.empty? # (no Array a span without inputs)
          inputs = @midi_pump
          return if inputs.empty?
          rate = output.sample_rate.round
          inputs.each { |m|
            cuts = m.wire_input? && !@changes.empty? ? wire_cuts(m.name, frame, count, from, per_sample) : nil
            m.pump(frame, count, from, per_sample, epoch, rate, cuts)
          }
        end

        # The wire changes for wire input +name+ landing in this span, taken
        # from the change queue as [offset, lander] pairs for
        # MidiInput#pump, which lands each between the pieces of the span it
        # reads (so the stream changes on the change's frame, where
        # #commit_due would land it; nil if none).  Called with the render
        # lock held.
        def wire_cuts(name, frame, count, from, per_sample)
          to = Sequence::Transport.position_at(from, count, per_sample)
          return nil if @changes.first.time >= to
          cuts = nil
          i = 0
          track = Session::Name.wired(name)
          while (c = @changes[i]) && c.time < to && !timeline_change?(c)
            # (a hold of the wired track lands between the pieces too: its
            # stream stops on the hold's frame; Session::Holds)
            unless (c.subject.equal?(name) || hold_of?(c, track)) && !held?(c)
              i += 1
              next
            end
            @changes.delete_at(i)
            idx = MB::M.max(Sequence::Transport.frame_at(c.time, from, per_sample), 0)
            land = MB::M.max(c.time, from)
            (cuts ||= []) << [idx, wire_lander(c, land, frame + idx, from, frame)]
          end
          cuts
        end

        # True if change +c+ holds or releases track +track+ (or every
        # held track).
        def hold_of?(c, track)
          (Holds::KINDS.include?(c.kind) || (c.kind == :restore && c.entry.data[:hold])) && (c.subject.equal?(track) || c.subject.equal?(:hold))
        end

        # Lands wire change +c+ at +land_frame+ when called (see #wire_cuts;
        # a method, so each Proc keeps its own change).
        def wire_lander(c, land_pos, land_frame, from, frame)
          -> { commit_change(c, land_pos: land_pos, land_frame: land_frame, commits: stamp(from, frame: frame), immediate: false) }
        end

        # Runs the block with #player_frame at +frame+: a wire input reading
        # another input's taps in pieces (see MidiInput#pump).
        def reading_from(frame)
          old = @player_frame
          @player_frame = frame
          yield
        ensure
          @player_frame = old
        end

        # The undo subject of a wire input's change (see WireSubject), or
        # nil.
        def wire_undo_subject(c)
          Name.wired(c.subject) ? WireSubject.new(c.subject) : nil
        end

        # The stream wired into a wire input, for undo.  Called with the
        # render lock held.
        def wire_undo_snapshot(subject)
          @midi_lock.synchronize { @midi_inputs[subject.name] }&.wired
        end

        # Wires a wire input back to the stream it had before +original+,
        # at +time+.
        def restore_wire_change(subject, original, time)
          stream = original.before
          hub = midi_in(subject.name)
          change(:restore, subject.name, time, data: { wire: true }, undoes: original.seq) { |t| hub.wire_to(stream, pos: t) }
        end

        # Appends a MidiInput's stamped events to the MIDI log.
        def log_midi(input, events)
          rows = events.filter_map { |s| [input.name, s.epoch, s.pos, s.event.bytes.bytes.freeze].freeze if s.event.bytes }
          @midi_lock.synchronize { @midi_log.concat(rows) }
        end
      end
    end
  end
end
