module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A graph node that produces MIDI note number, with optional pitch
        # bend, in the original logarithmic scale of MIDI semitones.
        class MidiNumber < MidiValue
          # Initializes a MIDI-control-change graph node.
          #
          # See MidiDsl#cc.
          def initialize(manager:, sample_rate:, bend_range:, range: 0..127, unit:, si:)
            super(default: MB::Sound::Oscillator.tune_freq, manager: manager, range: range, unit: unit, si: si, sample_rate: sample_rate)

            @node_type_name = "Note Number"

            @manager.on_note(&method(:note_cb))

            if bend_range
              @manager.on_bend(range: bend_range, default: (bend_range.begin + bend_range.end) / 2.0, &method(:bend_cb))
            end

            @from_range = 0..127
            @to_range = range

            @number = 69
            @bend = 0
          end

          # Called by the MIDI manager for note on/off events.  Sets the base
          # note number independent of pitch bend.
          def note_cb(number, _velocity, onoff)
            return unless onoff

            @number = number
            update_value
          end

          # Called by the MIDI manager to set the pitch bend value in
          # semitones.
          def bend_cb(bend)
            @bend = bend
            update_value
          end

          # Called by #note_cb and #bend_cb to recalculate the output value
          # using both note number and bend amount.
          def update_value
            # FIXME: default constant smoothing interpolates over a full block;
            # should probably update it to use a low-pass filter or linear
            # follower.
            self.constant = MB::M.scale(@number + @bend, @from_range, @to_range)
          end
        end
      end
    end
  end
end
