module MB
  module Sound
    # The session key (midi-consol-2; ux-r4 items 10 and 11): a root pitch
    # class and a mode (any scale name: :major, :dorian, :minor_pentatonic,
    # ...), set with `key :ab`, `mode :phrygian`, or `key :ab, :phrygian`
    # and read back with bare `key` ("Ab phrygian").  Scale transforms
    # (`degrees`, `snap`, `lock`), `scale(...)` without a root, and bare
    # `scale` default to it.  Lives on the Sequence::Transport as a key map
    # (see Transport#key_at), changed by journaled Session changes (see
    # KeyMethods).
    #
    # +root+ is a pitch class (0..11, C = 0), +mode+ a scale name (see
    # Scale.names), and +spelling+ the root's name as written ("Ab" or
    # "G#"; flats by default).
    class MusicalKey < Data.define(:root, :mode, :spelling)
      # Root names for pitch classes, flats and sharps.
      FLATS = %w[C Db D Eb E F Gb G Ab A Bb B].freeze
      SHARPS = %w[C C# D D# E F F# G G# A A# B].freeze

      def initialize(root:, mode: :major, spelling: nil)
        raise ArgumentError, "A key's root is a pitch class 0..11 (got #{root.inspect})" unless root.is_a?(Integer) && root.between?(0, 11)
        mode = MusicalKey.check_mode(mode)
        super(root: root, mode: mode, spelling: (spelling || FLATS[root]).freeze)
      end

      # The default session key.
      def self.default
        @default ||= new(root: 0, mode: :major)
      end

      # The seven diatonic modes from brightest to darkest: each step
      # lowers one degree (Lydian's #4, Ionian's 7, Mixolydian's 3,
      # Dorian's 6, Aeolian's 2, Phrygian's 5), so a knob walking this
      # order changes the scale one note at a time (KeyMethods#modes).
      BRIGHTNESS = [:lydian, :major, :mixolydian, :dorian, :minor, :phrygian, :locrian].freeze

      # +mode+ as a scale name Symbol, raising with suggestions if it isn't
      # one.  A param (MIDI::Param: a knob's #choose, #modes) stays as it
      # is: the mode is read from it at each position (see #scale).
      def self.check_mode(mode)
        return mode if mode.is_a?(MIDI::Param::Base)
        m = mode.to_s.downcase.to_sym
        return m if Scale::OFFSETS.key?(m) || Scale::ALIASES.key?(m)
        names = Scale.names
        hint = DidYouMean::SpellChecker.new(dictionary: names.map(&:to_s)).correct(m.to_s).first
        raise ArgumentError, "Unknown mode #{mode.inspect}#{hint ? " (did you mean #{hint.to_sym.inspect}?)" : ''}; modes are scale names: #{names.map(&:inspect).join(', ')}"
      end

      # True if +x+ names a mode (a scale name), not a root.
      def self.mode_name?(x)
        (x.is_a?(Symbol) || x.is_a?(String)) && !root_name?(x) && (Scale::OFFSETS.key?(x.to_s.downcase.to_sym) || Scale::ALIASES.key?(x.to_s.downcase.to_sym))
      end

      # True if +x+ looks like a root name (:ab, 'F#', :c).
      def self.root_name?(x)
        (x.is_a?(Symbol) || x.is_a?(String)) && x.to_s.strip.match?(/\A[A-Ga-g](#|s|b|♯|♭)?\z/)
      end

      # [pitch class, spelling] of +root+: a name (:ab, 'Ab', 'F#', :cs),
      # a Note or Pitch (its pitch class), a note number, or a pitch class
      # 0..11.
      def self.parse_root(root)
        case root
        when Symbol, String
          name = root.to_s.strip
          m = name.match(/\A([A-Ga-g])(#|s|b|♯|♭)?(-?\d+)?\z/)
          raise ArgumentError, "Unknown root #{root.inspect} (a note name like :ab, 'F#', or a Note like Ab2)" unless m
          pc = Scale.pitch_class(name)
          letter = m[1].upcase
          acc = case m[2] when '#', 's', '♯' then '#' when 'b', '♭' then 'b' else '' end
          [pc.round, "#{letter}#{acc}"]
        when Integer
          pc = root % 12
          [pc, FLATS[pc]]
        when Numeric
          pc = root.round % 12
          [pc, FLATS[pc]]
        when Pitch
          pc = Scale.pitch_class(root).round % 12
          [pc, FLATS[pc]]
        else
          raise ArgumentError, "A key's root is a note name (:ab, 'F#'), a Note (Ab2), or a pitch class 0..11 (got #{root.inspect})"
        end
      end

      # This key with another root (see .parse_root).
      def with_root(root)
        pc, spelling = MusicalKey.parse_root(root)
        with(root: pc, spelling: spelling)
      end

      # This key with another mode.
      def with_mode(mode)
        with(mode: MusicalKey.check_mode(mode))
      end

      # The key's Scale (degree 0 in the octave from C4 up).  A mode that
      # moves (a param) is read at timeline position +pos+ (the
      # transport's position, else 0).
      def scale(pos = nil, transport: nil)
        m = mode
        if m.is_a?(MIDI::Param::Base)
          pos ||= transport&.position || 0r
          m = MusicalKey.check_mode(m.value_at(pos, transport: transport))
        end
        SCALES[[m, root]] ||= Scale[m, root]
      end

      # True if the mode moves (a param; see #scale).
      def moving?
        mode.is_a?(MIDI::Param::Base)
      end

      # Scales of keys used so far (a Scale per [mode, root]; read on every
      # note of a scale transform following the session key).
      SCALES = {}

      # "Ab phrygian".
      def to_s
        "#{spelling} #{mode}"
      end

      def inspect
        to_s
      end

      # The console line that sets this key.
      def to_ruby
        "key #{spelling.sub('#', 's').downcase.to_sym.inspect}, #{mode.is_a?(Symbol) ? mode.inspect : mode.to_s}"
      end
    end
  end
end
