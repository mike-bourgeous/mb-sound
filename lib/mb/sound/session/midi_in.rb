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
        # The MidiInput named +name+ (nil for the default), created when
        # first needed (without an input: see MidiInput#input=, or the
        # console's MidiMethods#midi, which attaches live input).
        def midi_in(name = nil)
          @midi_lock.synchronize {
            @midi_inputs[name] ||= MidiInput.new(self, name).tap { |m|
              m.replay([], base_epoch: @replay_epoch || 0) if @replay_mode
            }
          }
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

        # True if the Session renders in a background thread (see #add).
        def realtime?
          @realtime
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
          @midi_log = []
          @replay_mode = false
        end

        # Reads every MidiInput for the span (called by #render_span).
        def pump_midi(frame, count, from, per_sample)
          return if @midi_inputs.empty? # (no Array a span without inputs)
          inputs = @midi_lock.synchronize { @midi_inputs.values }
          return if inputs.empty?
          rate = output.sample_rate.round
          inputs.each { |m| m.pump(frame, count, from, per_sample, epoch, rate) }
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
