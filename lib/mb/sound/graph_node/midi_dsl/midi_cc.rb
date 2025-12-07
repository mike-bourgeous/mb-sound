module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A graph node that scales MIDI CC values to a given range.
        class MidiCc < MidiValue
          # Initializes a MIDI-control-change graph node.
          #
          # See MidiDsl#cc.
          def initialize(manager:, number:, range:, unit:, si:, sample_rate:)
            super(default: range.begin, manager: manager, range: range, unit: unit, si: si, sample_rate: sample_rate)

            @number = Integer(number)
            @node_type_name = "MIDI CC #{@number}"

            @manager.on_cc(number, range: range, default: range.begin, &method(:constant=))
          end
        end
      end
    end
  end
end
