module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A graph node that outputs the MIDI velocity of the most recently
        # pressed note.
        class MidiVelocity < MidiValue
          # Initializes a MIDI velocity graph node.
          #
          # See MidiDsl#velocity.
          def initialize(dsl:, sample_rate:, number:, range:, unit:, si:)
            super(default: 0, dsl: dsl, range: range, unit: unit, si: si, sample_rate: sample_rate)

            @node_type_name = "Note Velocity"

            @from_range = 0..127
            @to_range = range
            @number = number

            @manager.on_note(&method(:note_cb))
          end

          # Called by the MIDI manager for note on/off events, from which we
          # take the attack velocity.
          def note_cb(number, velocity, onoff)
            return unless onoff && (@number.nil? || number == @number)

            # TODO: should this output zero or something based on release
            # velocity when the note is released?
            # TODO: allow selecting release velocity?

            self.constant = MB::M.scale(velocity, @from_range, @to_range)
          end

          def sources
            super.merge({ note_velocity: @dsl })
          end
        end
      end
    end
  end
end
