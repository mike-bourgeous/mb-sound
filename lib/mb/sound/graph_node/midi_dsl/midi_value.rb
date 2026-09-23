module MB
  module Sound
    module GraphNode
      class MidiDsl
        # Represents a value derived from MIDI inputs.  In all cases the default
        # output range is 0..1.  Generally only used through subclasses.
        class MidiValue < ::MB::Sound::GraphNode::Constant
          prepend MidiEof

          # +:manager+ - MIDI manager for subscription
          # +:range+ - The value display range
          # +:default+ - The initial value
          #
          # See MB::Sound::GraphNode::Constant
          def initialize(dsl:, range:, default:, sample_rate:, si:, unit:, smoothing:)
            super(default, sample_rate: sample_rate, range: range, si: si, unit: unit, smoothing: smoothing)

            @dsl = dsl
            @manager = dsl.manager
            @cache_invalidated = false
          end
        end
      end
    end
  end
end
