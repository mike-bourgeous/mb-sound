require_relative '../../tone'

module MB
  module Sound
    module GraphNode
      class MidiDsl
        prepend MidiEof

        # Wraps MB::Sound::Tone with a #sample method that helps MidiDsl manage
        # its internal node cache.
        class MidiTone < ::MB::Sound::Tone
          def initialize(dsl:, frequency:)
            super(frequency: frequency)

            @dsl = dsl
            @manager = dsl.manager
            @cache_invalidated = false
            @node_type_name = 'MIDI Oscillator'

            # Default to playing forever
            or_for(nil)
          end
        end
      end
    end
  end
end
