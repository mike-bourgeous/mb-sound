module MB
  module Sound
    module GraphNode
      # Represents a value derived from MIDI inputs.  In all cases the default
      # output range is 0..1.
      class MidiValue < Constant
        # TODO: Have separate classes for each message type?
        MODES = {
          # TODO: hz, number, and velocity instead of note, note_number,...?
          note: 'Note frequency',
          note_number: 'Note number',
          velocity: 'Note velocity',
          cc: 'Control change',
          bend: 'Pitch bend',
          gate: 'Note or pedal sustained', # TODO: start gate at correct offset within frame?
        }

        def initialize(channel:, mode:, manager:, range: 0..1, ref:, sample_rate:)
          @mode = mode
          case mode
          when :cc
            # TODO: logarithmic scales?
            super(range.begin, sample_rate: sample_rate, range: range, si: false)
            manager.on_cc(ref, range: range, self)

          when :note
            # FIXME: this should also work with GraphVoice
            # FIXME: convert note number to frequency
            # TODO: combine bend here?
            super(range.begin, sample_rate: sample_rate, range: range, unit: 'Hz')
            manager.on_note(ref, range: range, self)

          when :note_number
            # FIXME: this should also work with GraphVoice
            # TODO: combine bend here?
            super(range.begin, sample_rate: sample_rate, range: range, unit: 'st')
            manager.on_note(ref, range: range, self)

          when :bend
            super(range.begin, sample_rate: sample_rate, range: range, unit: 'st')
            manager.on_bend(range: range, self)
          end
        end

        # MIDI callback for receiving parameter value changes.
        def call(idx, val, onoff)
          self.value = val
        end
      end
    end
  end
end
