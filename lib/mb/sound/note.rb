module MB
  module Sound
    # A musical note: a MIDI note number with a name (C4 is 60, A4 is 69)
    # and detuning in cents.  Its frequency comes from the session's Tuning
    # (see MB::Sound.tuning) when it's used, and oscillators made from it
    # follow tuning changes while they play (see Pitch for the oscillator
    # methods: `C4.triangle.at(0.5)`, `play C4`).
    #
    # Notes are values: the note constants (MB::Sound::C4, etc.) make a new
    # Note each time, and sequences store their note numbers.
    class Note < Pitch
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

      attr_reader :number, :name, :accidental, :detune, :octave

      # Name and accidental using Unicode U+266d and U+266f instead of letters.
      attr_reader :fancy_name, :fancy_accidental

      # The name of the key without any accidental (A, B, C, D, E, F, or G).
      attr_reader :base_name

      # The index of the note within its octave including accidentals, C being
      # 0, B being 11.
      attr_reader :note_in_octave

      # The index of the key name within the octave ignoring accidentals, C
      # being 0, B being 5.
      attr_reader :key_in_octave

      # Initializes a note of the given MIDI note number, the note name with
      # octave, or the nearest note to a Pitch or Tone's frequency (with
      # detuning) in the current tuning.  Note names look like 'C0', 'As2',
      # 'Gb3'.  Flats are denoted with 'b' or U+266D, sharps with 's', '#', or
      # U+266F.
      def initialize(tone_name_number, sample_rate: 48000)
        case tone_name_number
        when Numeric, /\A\d+(\.\d+)?\z/
          # Note number
          set_number(tone_name_number.to_f)

        when String, Symbol
          set_name(tone_name_number.to_s)

        when Pitch, Tone
          set_number(MB::Sound.tuning.number_of(tone_name_number.frequency))
          sample_rate = tone_name_number.sample_rate

        else
          raise ArgumentError, "Cannot construct a Note from #{tone_name_number}"
        end

        super(nil, sample_rate: sample_rate)
      end

      # Changes the detuning in cents (for oscillators made from now on).
      def detune=(detune)
        @detune = detune
      end

      # Changes the note number (for oscillators made from now on).
      def number=(number)
        set_number(number)
      end

      # The note's frequency in Hz in the current tuning (see
      # MB::Sound.tuning).
      def frequency
        MB::Sound.tuning.frequency_of(@number, @detune)
      end

      # The unit of the note number Constant inside #freq (shown in graph
      # views), which tells it from frequencies in Hz.
      NUMBER_UNIT = ' note'

      # A node producing the note's frequency in Hz in the current tuning,
      # following tuning changes (see Tuning#freq).
      def freq
        MB::Sound.tuning.freq(detuned_number.constant(sample_rate: @sample_rate, unit: NUMBER_UNIT, si: false))
      end
      alias oscillator_frequency freq

      # A Note is never a constant frequency: it follows the tuning.
      def constant?
        false
      end

      # Returns the Note +semitones+ higher (lower if negative); +semitones+
      # may be an Interval (`7.st`, `1.oct`).
      def transpose(semitones)
        semitones = Interval.semitones(semitones)
        Note.new(detuned_number + semitones, sample_rate: @sample_rate)
      end

      def to_s
        @detune == 0 ? @name : format('%s%+g', @name, @detune)
      end

      # Returns the effective fractional note number including detuning.
      def detuned_number
        @number + @detune * 0.01
      end

      # Converts this Tone to a MIDI NoteOn message from the midi-message gem.
      def to_midi(velocity: 64, channel: -1)
        MIDIMessage::NoteOn.new(channel, number.round, velocity)
      end

      # Returns true if this Note represents a white key on a piano keyboard.
      def white_key?
        @white_key
      end

      # Returns true if this Note represents a black key on a piano keyboard.
      def black_key?
        @black_key
      end

      # Allow iteration of notes in Ranges.
      # TODO: find a way to iterate over scales instead of chromatically?
      def succ
        Note.new(@number + 1)
      end

      private

      # Sets note name, number, and detuning from a note name string.
      def set_name(name)
        # =~ sets $1, $2, etc.
        unless name =~ /\A([A-G])([s#b\u266d\u266e\u266f]?)(-?[0-9])([+-]\d+(\.\d+)?)?\z/
          raise ArgumentError, "Invalid note name format #{name}"
        end

        note = $1
        accidental = $2
        octave = $3.to_i
        detune = $4&.to_f || 0
        octave_cents = NOTE_CENTS[note.to_sym]
        case accidental
        when 's', '#', "\u266f"
          octave_cents += 100.0
        when 'b', "\u266d"
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
        key_index = SCALE_CENTS.index(closest_cents)
        note_name = NOTE_NAMES[key_index]
        offset = (octave_cents - NOTE_CENTS[note_name]).round(2)
        if offset < -50
          accidental = 'b'
          fancy_accidental = "\u266d"
        elsif offset > 50
          accidental = 's'
          fancy_accidental = "\u266f"
        end

        @name = "#{note_name}#{accidental}#{octave}"
        @fancy_name = "#{note_name}#{fancy_accidental}#{octave}"
        @base_name = note_name
        @accidental = accidental
        @fancy_accidental = fancy_accidental
        @white_key = accidental.nil? || accidental.empty?
        @black_key = !@white_key
        @number = @number.to_i
        @octave = octave
        @note_in_octave = note_in_octave
        @key_in_octave = key_index
      end
    end
  end
end
