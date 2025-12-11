require_relative '../../tone'

module MB
  module Sound
    module GraphNode
      class MidiDsl
        # Wraps MB::Sound::Tone with a #sample method that helps MidiDsl manage
        # its internal node cache.
        class MidiTone < ::MB::Sound::Tone
          def initialize(dsl:, frequency:)
            super(frequency: frequency)

            @dsl = dsl
            @node_type_name = 'MIDI Oscillator'

            # Default to playing forever
            or_for(nil)
          end

          def sample(count)
            @dsl&.invalidate_cache(self)
            @dsl = nil
            super
          end
        end
      end
    end
  end
end
