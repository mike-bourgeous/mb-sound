module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A graph node that outputs MIDI pitch bend values.
        class MidiBend < MidiValue
          # Initializes a MIDI pitch bend graph node.
          #
          # See MidiDsl#bend.
          def initialize(dsl:, range:, unit:, si:, sample_rate:)
            # TODO: have 0 raw bend equal exactly 0.0 for symmetric range
            default = 0.5 * (range.begin + range.end)

            super(dsl: dsl, default: default, range: range, unit: unit, si: si, sample_rate: sample_rate)

            @node_type_name = "Pitch Bend"

            @manager.on_bend(range: range, default: default, &method(:constant=))

            # TODO: provide a convenient way to output a value in Hz based on a semitone range?
          end

          def sources
            super.merge({ pitch_bend: @dsl })
          end
        end
      end
    end
  end
end
