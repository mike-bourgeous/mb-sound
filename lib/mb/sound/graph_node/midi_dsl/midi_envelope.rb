module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A MIDI-controlled envelope triggered by note on/off events and
        # sustain pedal (TODO).
        class MidiEnvelope < MB::Sound::ADSREnvelope
          def initialize(manager:, attack:, decay:, sustain:, release:, sample_rate:)
            super(attack_time: attack, decay_time: decay, sustain_level: sustain, release_time: release, sample_rate: sample_rate, filter_freq: 200)

            @manager = manager

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
        end
      end
    end
  end
end
