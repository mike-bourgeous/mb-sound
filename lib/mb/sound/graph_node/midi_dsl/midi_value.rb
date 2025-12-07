module MB
  module Sound
    module GraphNode
      class MidiDsl
        # Represents a value derived from MIDI inputs.  In all cases the default
        # output range is 0..1.  Generally only used through subclasses.
        class MidiValue < ::MB::Sound::GraphNode::Constant
          # +:manager+ - MIDI manager for subscription
          # +:range+ - The value display range
          # +:default+ - The initial value
          #
          # See MB::Sound::GraphNode::Constant
          def initialize(manager:, range:, default:, sample_rate:, si:, unit:)
            super(default, sample_rate: sample_rate, range: range, si: si, unit: unit)

            @manager = manager
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
