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
          def initialize(dsl:, range:, default:, sample_rate:, si:, unit:)
            super(default, sample_rate: sample_rate, range: range, si: si, unit: unit)

            @dsl = dsl
            @manager = dsl.manager
            @cache_invalidated = false
          end

          # Intercepts audio generation to trigger reading MIDI input.  Returns
          # nil to stop the node graph if reading from a MIDI file and the file
          # has ended (see MB::Sound::MIDI::MIDIFile#done?).
          def sample(count)
            return nil if @dsl.nil?

            @dsl.invalidate_cache(self) unless @cache_invalidated
            @cache_invalidated = true

            # FIXME: this will totally screw up parameter smoothing because it gets called N times per frame for N MIDI nodes
            @manager.update
            super
          end
        end
      end
    end
  end
end
