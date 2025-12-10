module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A MIDI-controlled envelope triggered by note on/off events and
        # sustain pedal (TODO).
        class MidiEnvelope < MB::Sound::ADSREnvelope
          def initialize(dsl:, attack:, decay:, sustain:, release:, sample_rate:, range:)
            super(attack_time: attack, decay_time: decay, sustain_level: sustain, release_time: release, sample_rate: sample_rate, filter_freq: 200)

            @dsl = dsl
            @manager = @dsl.manager
            @cache_invalidated = false

            @range = range

            @node_type_name = 'MIDI Envelope'

            # TODO: sustain pedal

            @manager.on_note(&method(:note_cb))
          end

          # Triggers and releases the envelope based on note press/release,
          # only releasing for the note number that triggered the envelope.
          def note_cb(number, velocity, onoff)
            if onoff
              @number = number
              trigger(velocity / 127.0)
            elsif number == @number
              release
            end
          end

          def sample(count)
            @dsl.invalidate_cache(self) unless @cache_invalidated
            @cache_invalidated = true
            MB::M.scale(super, 0..1, @range)
          end

          def sources
            super.merge({ trigger: @dsl })
          end
        end
      end
    end
  end
end
