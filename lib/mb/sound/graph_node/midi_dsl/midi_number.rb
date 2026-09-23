module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A graph node that produces a MIDI note number, with optional pitch
        # bend, in the original logarithmic scale of MIDI semitones.
        class MidiNumber < MidiValue
          # Initializes a MIDI note number graph node.
          #
          # See MidiDsl#number.
          def initialize(dsl:, sample_rate:, bend_range:, range:, unit:, si:, smoothing:)
            super(default: MB::Sound::Oscillator.tune_note, dsl: dsl, range: range, unit: unit, si: si, sample_rate: sample_rate, smoothing: smoothing)

            @node_type_name = "Note Number"

            @manager.on_note(&method(:note_cb))

            if bend_range
              @manager.on_bend(range: bend_range, default: (bend_range.begin + bend_range.end) / 2.0, &method(:bend_cb))
            end

            @from_range = 0..127
            @to_range = range
            @to_range ||= 0..127

            @number = 69
            @bend = 0
          end

          # Called by the MIDI manager for note on/off events.  Sets the base
          # note number independent of pitch bend.
          def note_cb(number, _velocity, onoff, timestamp)
            return unless onoff

            @number = number
            update_value(timestamp)
          end

          # Called by the MIDI manager to set the pitch bend value in
          # semitones.
          def bend_cb(bend, timestamp)
            @bend = bend
            update_value(timestamp)
          end

          # Called by a GraphVoice when an inactive note needs to change
          # frequency for polyphonic portamento.
          def set_note(number, timestamp)
            @number = number
            update_value(timestamp)
          end

          # Called by #note_cb and #bend_cb to recalculate the output value
          # using both note number and bend amount.
          def update_value(timestamp)
            timed_change(MB::M.scale(@number + @bend, @from_range, @to_range), timestamp)
          end

          def sources
            super.merge({ note_number: @dsl, pitch_bend: @dsl })
          end
        end
      end
    end
  end
end
