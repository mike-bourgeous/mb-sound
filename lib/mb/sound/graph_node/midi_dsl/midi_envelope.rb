module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A MIDI-controlled envelope triggered by note on/off events and
        # sustain pedal (TODO).
        class MidiEnvelope < MB::Sound::ADSREnvelope
          prepend MidiEof

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
          def note_cb(number, velocity, onoff, timestamp)
            if onoff
              @number = number
              trigger(velocity / 127.0)

              # TODO: support multiple events per buffer
              # FIXME: timestamp will be in base sample rate; need to account for oversampling
              self.time = -timestamp if timestamp > 0
            elsif number == @number
              release
            end
          end

          def sample(count)
            MB::M.scale(super, 0..1, @range)
          end

          def sources
            super.merge({ trigger: @dsl })
          end

          # Overrides the superclass to clear the DSL, as duplicated envelopes
          # are typically used for plotting an overal envelope curve.
          def dup(sample_rate = @sample_rate)
            super.tap { |other|
              other.instance_variable_set(:@dsl, nil)
            }
          end

          # TODO to_s and to_s_graphviz that include the output range
          # TODO: allow setting velocity sensitivity
        end
      end
    end
  end
end
