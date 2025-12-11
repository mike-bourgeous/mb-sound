module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A graph node that outputs a value based on attack velocity and
        # sustain pedal while a note is held or the sustain pedal is pressed.
        #
        # This class uses velocity to set the initial gate level and half-pedal
        # amount to control the decay rate.
        class MidiGate < MidiValue
          def initialize(dsl:, range:, unit:, si:, sample_rate:)
            super(dsl: dsl, range: range, default: range.begin, unit: unit, si: si, sample_rate: sample_rate)

            # TODO: start gate at correct offset within frame?  would need to get event timestamps out of mb-sound-jackffi
            @node_type_name = 'Note Sustain'

            @number = nil
            @on = false
            @sustain = 0.0
            @velocity = 0.0
            @val = 0.0

            @from_range = 0..1
            @to_range = range

            @manager.on_note(&method(:note_cb))
            @manager.on_cc(64, &method(:pedal_cb))
          end

          # Stores note attack velocity in @velocity from 0..1 and note on/off
          # state in @on.
          def note_cb(number, velocity, onoff)
            if onoff
              @on = true
              @number = number
              @velocity = velocity / 127.0
            elsif @number == number
              @on = false
              @number = nil
            end
          end

          # Stores the half-pedal amount in @sustain from 0..1.
          def pedal_cb(value)
            @sustain = value
          end

          # Calculates a new target output value based on note and pedal state,
          # then passes control to the superclass.
          def sample(count)
            if @on
              @val = @velocity
            elsif self.constant > 1e-4
              # TODO: use release velocity as well?
              # TODO: take sample count and sample rate into account for consistent decay
              # TODO: could add half-pedal functionality to envelopes by scaling time rate by (1 - sustain).
              @val *= @sustain ** (count / @sample_rate)
            else
              @val = 0
            end

            self.constant = MB::M.scale(@val, @from_range, @to_range)

            super
          end

          def sources
            super.merge({ note_velocity: @dsl, cc_64: @dsl })
          end
        end
      end
    end
  end
end
