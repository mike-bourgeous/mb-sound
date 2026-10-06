module MB
  module Sound
    # Converts MIDI note numbers to frequencies and back: twelve-tone equal
    # temperament around a reference note and frequency (A4 = 440 Hz by
    # default).  Other tunings (scales, just intonation) can be added later
    # as other ways of mapping note numbers to frequencies.
    #
    # Each Session has a tuning (Tuning.default unless given another), found
    # with MB::Sound.tuning and changed with e.g. `tuning b4: 480` (B4 at
    # exactly 480 Hz syncs with 60 fps video).  Nodes made with #freq read the
    # tuning on every buffer, so changes apply to notes already playing.
    #
    # Example (bin/sound.rb):
    #     tuning b4: 480
    #     tuning.frequency_of(71)   # => 480.0
    #     tuning.reset              # back to A4 = 440 Hz
    class Tuning
      DEFAULT_NOTE = 69 # A4
      DEFAULT_FREQUENCY = 440.0

      # The tuning shared by sessions that don't get their own.
      def self.default
        @default ||= new
      end

      # The tuning in effect: the current session's (inside a Session
      # render or scheduled block) or the default.  Same as MB::Sound.tuning
      # without arguments, without allocating its keyword Hash (for nodes
      # that check it every buffer).
      def self.current
        MB::Sound::Session.context&.[](:session)&.tuning || default
      end

      # The reference MIDI note number and its frequency in Hz.
      attr_reader :note, :frequency

      # Creates a tuning with +note+ (a MIDI note number) at +frequency+ Hz.
      def initialize(note: DEFAULT_NOTE, frequency: DEFAULT_FREQUENCY)
        set(note: note, frequency: frequency)
      end

      # Changes the reference, either as +note:+ and +frequency:+, or as one
      # note name and frequency (e.g. `set(b4: 480)`, `set(a4: 442)`).
      # Returns self.
      def set(note: nil, frequency: nil, **named)
        if named.any?
          raise ArgumentError, "Give one note name and frequency (e.g. b4: 480), got #{named.inspect}" if named.length != 1 || note || frequency

          name, frequency = named.first
          note = Note.new(name.to_s.capitalize).number
        end

        raise ArgumentError, "Tuning note must be a Numeric (got #{note.inspect})" unless note.is_a?(Numeric)
        raise ArgumentError, "Tuning frequency must be positive (got #{frequency.inspect})" unless frequency.is_a?(Numeric) && frequency > 0

        @note = note
        @frequency = frequency.to_f
        self
      end

      # Goes back to A4 = 440 Hz.
      def reset
        set(note: DEFAULT_NOTE, frequency: DEFAULT_FREQUENCY)
      end

      # Returns the frequency in Hz of MIDI note +number+ (fractional numbers
      # are fine) detuned by +cents+.
      def frequency_of(number, cents = 0)
        @frequency * 2 ** ((number + cents / 100.0 - @note) / 12.0)
      end

      # Returns the fractional MIDI note number of +frequency+ Hz (0 or
      # negative frequencies give -Infinity).
      def number_of(frequency)
        frequency = frequency.real if frequency.is_a?(Complex)
        return -Float::INFINITY if frequency <= 0

        12.0 * Math.log2(frequency / @frequency) + @note
      end

      # Returns a node converting the note numbers from +node+ to
      # frequencies in Hz with this tuning, as it is when each buffer is
      # computed (see GraphNode::SynthesisMethods#freq).
      def freq(node)
        tuning = self
        node.proc(type_name: 'Number to frequency') { |v|
          MB::FastSound.number_to_freq(v, tuning.note, tuning.frequency)
        }
      end

      def to_s
        "12-TET, #{Note.new(@note).name} = #{MB::M.sigfigs(@frequency, 6)} Hz"
      end
      alias inspect to_s
    end

    # MB::Sound.tuning (see Tuning).
    module TuningMethods
      # Returns the current tuning (the current Session's, or
      # Tuning.default).  With a note name and frequency (e.g. `tuning b4:
      # 480`) or +note:+ and +frequency:+, changes it first.
      #
      # Inside a scheduled block (see ScheduleMethods), the change takes
      # effect at the block's time, at the start of the buffer that contains
      # it.
      #
      # Example (bin/sound.rb):
      #     tuning b4: 480
      #     play B4.tone.at(0.5) # exactly 480 Hz
      #     at_bar(9) { tuning a4: 432 }
      def tuning(**reference)
        context = MB::Sound::Session.context
        current = Tuning.current

        if reference.any? && context&.[](:batch)
          Tuning.new.set(**reference) # raises for invalid references now
          session, time = context[:session], context[:time]
          context[:batch] << -> { session.at_time(time) { current.set(**reference) } }
        elsif reference.any?
          current.set(**reference)
        end

        current
      end
    end
  end
end
