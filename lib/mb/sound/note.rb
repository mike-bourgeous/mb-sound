module MB
  module Sound
    # Represents a musical note in the 12-tone equal temperament scale, using
    # MIDI note numbers.
    class Note < Tone
      # Major scale intervals (for calculating note name offsets).
      SCALE_INTERVAL = [
        200,
        200,
        100,
        200,
        200,
        200
      ]

      # Note tunings in octave 4, in cents relative to C4, for a C major scale.
      # There are 100 cents in a semitone, 12 equally spaced semitones in an
      # octave.
      SCALE_CENTS = SCALE_INTERVAL.reduce([0]) { |o, v| o << v + (o.last) }

      # Names of notes that correspond with the cents scale.
      NOTE_NAMES = [
        :C,
        :D,
        :E,
        :F,
        :G,
        :A,
        :B
      ]

      # Map of note names to cents.
      NOTE_CENTS = NOTE_NAMES.zip(SCALE_CENTS).to_h

      attr_reader :number, :name, :detune

      # Initializes a note of the given MIDI note number, the note name with
      # octave, or a Tone object.  Note names look like 'C0', 'As2', 'Gb3'.
      # Flats are denoted with b, sharps with s or '#'.
      def initialize(tone_name_number)
        case tone_name_number
        when Numeric
          # Note number
          set_number(tone_name_number)
          super(frequency: get_freq)

        when String, Symbol
          name = tone_name_number.to_s
          set_name(tone_name_number.to_s)
          super(frequency: get_freq)

        when Tone
          tone = tone_name_number
          freq = tone.frequency
          set_number(Oscillator.calc_number(freq))
          super(frequency: get_freq, wave_type: tone.wave_type, amplitude: tone.amplitude, duration: tone.duration, rate: tone.rate)

        else
          raise ArgumentError, "Cannot construct a Note from #{tone_name_number}"
        end
      end

      def detune=(detune)
        @detune = detune
        set_frequency(get_freq)
      end

      def number=(number)
        set_number(number)
        set_frequency(get_freq)
      end

      # Converts this Tone to a MIDI NoteOn message from the midi-message gem.
      def to_midi(velocity: 64, channel: -1)
        MIDIMessage::NoteOn.new(channel, number.round, velocity)
      end

      private

      # Calculates the frequency based on the note's MIDI note number.
      def get_freq
        Oscillator.calc_freq(@number, @detune)
      end

      # Sets note name, number, and detuning from a note name string.
      def set_name(name)
        # =~ sets $1, $2, etc.
        unless name =~ /\A([A-G])([s#b]?)(-?[0-9])([+-]\d+(\.\d+)?)?\z/
          raise ArgumentError, "Invalid note name format #{name}"
        end

        note = $1
        accidental = $2
        octave = $3.to_i
        detune = $4&.to_f || 0
        octave_cents = NOTE_CENTS[note.to_sym]
        case accidental
        when 's', '#'
          octave_cents += 100.0
        when 'b'
          octave_cents -= 100.0
        end

        set_number((octave + 1) * 12 + (octave_cents + detune) / 100.0)
      end

      # Sets integer note number, note name, and detuning from the given
      # fractional note number.
      def set_number(number)
        @number = number.round
        raise "Note number #{@number} is out of the range 0..127" unless (0..127).cover?(@number)

        @detune = (100 * (number - @number)).round(2)

        # Note C4 is 60, octaves start with C
        # TODO: There's probably a cleaner way to do this, maybe just a bigger lookup table
        octave = (@number / 12).floor - 1
        note_in_octave = @number % 12
        octave_cents = note_in_octave * 100
        closest_cents = SCALE_CENTS.min_by { |c| (c - (octave_cents + @detune)).abs }
        note_name = NOTE_NAMES[SCALE_CENTS.index(closest_cents)]
        offset = (octave_cents - NOTE_CENTS[note_name]).round(2)
        if offset < -50
          accidental = 'b'
        elsif offset > 50
          accidental = 's'
        end

        @name = "#{note_name}#{accidental}#{octave}"
        @number = @number.to_i
      end
    end
  end
end
