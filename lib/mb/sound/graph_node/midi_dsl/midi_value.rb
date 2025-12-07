module MB
  module Sound
    module GraphNode
      class MidiDsl
        # Represents a value derived from MIDI inputs.  In all cases the default
        # output range is 0..1.
        class MidiValue < ::MB::Sound::GraphNode::Constant
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

          def initialize(manager:, mode:, range:, default:, sample_rate:, si:, unit:)
            super(default, sample_rate: sample_rate, range: range, si: si, unit: unit)

            @manager = manager
            @mode = mode
          end

          def sample(count)
            @manager.update # FIXME: this will totally screw up parameter smoothing
            super
          end
        end
      end
    end
  end
end
