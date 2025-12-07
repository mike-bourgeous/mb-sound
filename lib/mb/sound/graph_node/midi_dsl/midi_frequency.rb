module MB
  module Sound
    module GraphNode
      class MidiDsl
        # A graph node that scales MIDI note numbers and pitch bend values to
        # frequencies in Hz.  This is useful for controlling the frequency of
        # oscillators or filters.
        class MidiFrequency < MidiValue
          # Initializes a MIDI node frequency graph node.
          #
          # See MidiDsl#cc.
          def initialize(manager:, sample_rate:, bend_range:)
            range = MB::Sound::Note.new(0).frequency..MB::Sound::Note.new(127).frequency
            super(default: MB::Sound::Oscillator.tune_freq, manager: manager, mode: :cc, range: range, unit: 'Hz', si: true, sample_rate: sample_rate)

            @node_type_name = "Note Frequency"

            @manager.on_note(&method(:note_cb))
            @manager.on_bend(range: bend_range, default: (bend_range.begin + bend_range.end) / 2.0, &method(:bend_cb))

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
            self.constant = MB::Sound::Oscillator.calc_freq(@number + @bend)
          end
        end
      end
    end
  end
end
