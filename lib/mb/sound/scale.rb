module MB
  module Sound
    # A musical scale: a root and the notes of one period (an octave by
    # default) as offsets in semitones from the root, for moving notes by
    # scale degrees (MIDI transforms' +pitch:+ and +transpose+, the
    # arpeggiator, melody generators), snapping notes to the scale, and
    # diatonic chords.
    #
    # Degrees count scale notes from the root: degree 0 is the root, 1 the
    # next scale note up, -1 the scale note below the root, and degree
    # #size is the root one period up.  The chromatic scale (the default
    # wherever a scale is taken; CHROMATIC) has 12 notes, so its degrees are
    # semitones (user decision, 2026-10-09: +pitch:+ is always in degrees).
    #
    # Note numbers may be fractional (e.g. from detuned notes or scales in
    # cents); they are plain MIDI note numbers, so the session Tuning turns
    # them into frequencies (#[] returns Notes, whose frequencies follow
    # `tuning`).  Moving a note that isn't in the scale keeps its distance
    # from the scale note below it (#transpose).
    #
    # Examples:
    #     am = Scale.new(:minor, root: A3)     # or Scale[:minor, :a], scale(:minor, :a)
    #     am[2]                 # => C4 (a Note)
    #     am.transpose(A3, 4)   # => 64 (E4: four steps up A minor)
    #     am.snap(61)           # => 60 (C#4 to C4; ties go down)
    #     am.chord(0)           # => [57, 60, 64] (A minor triad)
    #     Scale.new([0, 2, 3, 7, 8], root: :e)            # custom offsets (semitones)
    #     Scale.new([0, 204.cents, 386.cents, 7.st, 9.st])  # Intervals, cents too
    #     Scale.steps([2, 2, 1, 2, 2, 2, 1])               # from steps (major)
    class Scale
      include Comparable

      # Offsets in semitones from the root for the named scales.  Modes of
      # the major scale have their Greek names too (see ALIASES).
      OFFSETS = {
        chromatic: (0..11).to_a,
        major: [0, 2, 4, 5, 7, 9, 11],
        dorian: [0, 2, 3, 5, 7, 9, 10],
        phrygian: [0, 1, 3, 5, 7, 8, 10],
        lydian: [0, 2, 4, 6, 7, 9, 11],
        mixolydian: [0, 2, 4, 5, 7, 9, 10],
        minor: [0, 2, 3, 5, 7, 8, 10],
        locrian: [0, 1, 3, 5, 6, 8, 10],
        harmonic_minor: [0, 2, 3, 5, 7, 8, 11],
        melodic_minor: [0, 2, 3, 5, 7, 9, 11],
        phrygian_dominant: [0, 1, 4, 5, 7, 8, 10],
        major_pentatonic: [0, 2, 4, 7, 9],
        minor_pentatonic: [0, 3, 5, 7, 10],
        blues: [0, 3, 5, 6, 7, 10],
        whole_tone: [0, 2, 4, 6, 8, 10],
        diminished: [0, 2, 3, 5, 6, 8, 9, 11], # whole-half octatonic
        half_whole: [0, 1, 3, 4, 6, 7, 9, 10], # half-whole octatonic (dominant diminished)
        hirajoshi: [0, 2, 3, 7, 8],
        in_sen: [0, 1, 5, 7, 10],
        augmented: [0, 3, 4, 7, 8, 11],
        major_triad: [0, 4, 7],
        minor_triad: [0, 3, 7],
      }.transform_values(&:freeze).freeze

      # Other names for scales in OFFSETS.
      ALIASES = {
        ionian: :major,
        aeolian: :minor,
        natural_minor: :minor,
        pentatonic: :major_pentatonic,
        major_pent: :major_pentatonic,
        minor_pent: :minor_pentatonic,
        octatonic: :diminished,
        whole_half: :diminished,
        whole: :whole_tone,
      }.freeze

      # The pitch class (semitones above C) of each note letter.
      LETTERS = { 'C' => 0, 'D' => 2, 'E' => 4, 'F' => 5, 'G' => 7, 'A' => 9, 'B' => 11 }.freeze

      # The names of every scale (OFFSETS and ALIASES).
      def self.names
        OFFSETS.keys + ALIASES.keys
      end

      # Returns a Scale from +value+: a Scale (as is, or moved to +root+ if
      # given), a name from OFFSETS/ALIASES, an Array of offsets, or nil
      # (the chromatic scale, or +root+'s chromatic scale).
      #
      #     Scale[:dorian, :d]
      #     Scale[nil]     # => Scale::CHROMATIC
      def self.[](value = nil, root = nil)
        case value
        when Scale then root.nil? ? value : value.with_root(root)
        when nil then root.nil? ? CHROMATIC : new(:chromatic, root: root)
        else new(value, root: root || 0)
        end
      end

      # A Scale from steps between neighboring notes (semitones or
      # Intervals) instead of offsets: `Scale.steps([2, 2, 1, 2, 2, 2, 1])`
      # is the major scale.  The steps should add up to the period; if they
      # add up to less, the last scale note is that far below the period.
      def self.steps(steps, root: 0, period: 12, name: nil)
        steps = steps.map { |s| Interval.semitones(s) }
        offsets = steps[0...-1].reduce([0]) { |list, s| list << list.last + s }
        new(offsets, root: root, period: period, name: name)
      end

      # The pitch class (0 to the period, usually 0..11) of +root+: a Note
      # (its number modulo the period), a note number, or a note name with
      # or without an octave (:a, 'F#', :Bb, 'C#3').
      def self.pitch_class(root, period = 12)
        root_number(root) % period
      end

      # The note number given by +root+: a Note's number, a Numeric as is,
      # or a name (:a, 'F#', :Bb, 'C#3'; without an octave, in the octave
      # from C4 up).
      def self.root_number(root)
        case root
        when Numeric then root
        when Pitch then root.respond_to?(:detuned_number) ? root.detuned_number : Note.new(root).number
        when Symbol, String
          name = root.to_s.strip
          m = name.match(/\A([A-Ga-g])(#|s|b|♯|♭)?(-?\d+)?\z/)
          raise ArgumentError, "Unknown root note #{root.inspect}" unless m
          pc = LETTERS.fetch(m[1].upcase)
          pc += 1 if ['#', 's', '♯'].include?(m[2])
          pc -= 1 if ['b', '♭'].include?(m[2])
          octave = m[3] ? m[3].to_i : 4
          (octave + 1) * 12 + pc
        else
          raise ArgumentError, "A scale root is a Note, a note number, or a note name (got #{root.inspect})"
        end
      end

      # The offsets of the scale notes from the root in semitones (sorted,
      # from 0 up to below the period; Integers or Rationals).
      attr_reader :offsets

      # The note number of degree 0 (see #initialize).
      attr_reader :root

      # The pitch class of the root (0 up to the period).
      attr_reader :root_class

      # The size of one period in semitones (12, an octave, by default).
      attr_reader :period

      # The scale's name (a Symbol), or nil for custom scales.
      attr_reader :name

      # Creates a scale from +intervals+: a name from OFFSETS or ALIASES
      # (see .names), or an Array of offsets from the root (semitones as
      # numbers, or Intervals such as `386.cents`), which must include 0.
      # Offsets are taken modulo +period+ (semitones or an Interval; 12 for
      # an octave), sorted, and made unique.
      #
      # +root+ is a Note (degree 0 is that note: A3 for `root: A3`), a note
      # number, or a note name (:a, 'F#', 'Bb2'; without an octave, degree
      # 0 is in the octave from C4 up, e.g. A4 for :a).  Only its pitch
      # class matters for #transpose, #snap, and #include?; #note and #[]
      # count degrees from the root note.
      def initialize(intervals = :chromatic, root: 0, period: 12, name: nil)
        @period = exact(Interval.semitones(period))
        raise ArgumentError, "A scale period must be positive (got #{period.inspect})" unless @period.is_a?(Numeric) && @period > 0

        if intervals.is_a?(Symbol) || intervals.is_a?(String)
          key = intervals.to_sym
          key = ALIASES.fetch(key, key)
          list = OFFSETS.fetch(key) { raise ArgumentError, "Unknown scale #{intervals.inspect} (#{Scale.names.join(', ')})" }
          name ||= intervals.to_sym
        elsif intervals.respond_to?(:to_a)
          list = intervals.to_a.map { |i| exact(Interval.semitones(i)) }
        else
          raise ArgumentError, "A scale is a name or an Array of offsets (got #{intervals.inspect})"
        end

        @offsets = list.map { |o| exact(o % @period) }.uniq.sort.freeze
        raise ArgumentError, 'A scale needs at least one note' if @offsets.empty?
        raise ArgumentError, "A scale's offsets must include 0, the root (got #{list.inspect})" unless @offsets.first == 0

        root = 0 if root.nil?
        # A number below the period is a pitch class (in the octave from C4
        # up, like note names without an octave); others are note numbers
        @root = exact(root.is_a?(Numeric) && root >= 0 && root < @period ? 60 + root : Scale.root_number(root))
        @root_class = exact(@root % @period)
        @name = name&.to_sym
        @chromatic = @period == 12 && @offsets == OFFSETS[:chromatic]
      end

      # The number of notes per period.
      def size
        @offsets.length
      end
      alias length size

      # True for the 12-note chromatic scale, whose degrees are semitones.
      def chromatic?
        @chromatic
      end

      # Returns this scale with another root (see #initialize).
      def with_root(root)
        Scale.new(@offsets, root: root, period: @period, name: @name)
      end

      # Returns the +n+th mode of this scale: the same notes starting from
      # degree +n+ (`Scale[:major].mode(1)` has the offsets of :dorian),
      # rooted on that note.
      def mode(n)
        n = Integer(n)
        start = note(n)
        list = Array.new(size) { |i| note(n + i) - start }
        Scale.new(list, root: start, period: @period)
      end

      # The note number of +degree+ (an Integer; negative degrees go below
      # the root), counted from the root note (see #initialize).
      def note(degree)
        octave, idx = Integer(degree).divmod(size)
        exact(@root + octave * @period + @offsets[idx])
      end

      # The Note of +degree+ (see #note), so its frequency follows the
      # session Tuning.  Also takes a Range of degrees (an Array of Notes).
      def [](degree)
        return degree.map { |d| self[d] } if degree.is_a?(Range)
        Note.new(note(degree))
      end

      # The frequency in Hz of +degree+ in the current Tuning.
      def hz(degree)
        MB::Sound.tuning.frequency_of(note(degree))
      end
      alias frequency hz

      # The Interval from the root to +degree+.
      def interval(degree)
        Interval.new(note(degree) - @root)
      end

      # Returns [degree, offset] for +note+ (a note number or Note): the
      # degree of the scale note at or below it, counted from the root note
      # (see #initialize), and the remaining distance in semitones (0 for
      # notes in the scale).
      def degree(note)
        n = number(note)
        rel = n - @root
        octave = (rel / @period).floor
        within = rel - octave * @period
        idx = @offsets.rindex { |o| o <= within + 1e-9 }
        offset = within - @offsets[idx]
        offset = 0 if offset.abs < 1e-9
        [octave * size + idx, exact(offset)]
      end

      # Returns +note+ (a note number or Note) moved by +degrees+ scale
      # degrees (an Integer; positive is up).  A note between scale notes
      # keeps its distance from the scale note below it.  For the chromatic
      # scale this is note + degrees, exactly.  Returns a note number (an
      # Integer when the result is whole).
      #
      #     Scale[:minor, :a].transpose(60, 2)   # => 64 (C4 two steps up A minor: E4)
      def transpose(note, degrees)
        n = number(note)
        raise ArgumentError, "Scale degrees are whole numbers (got #{degrees.inspect})" unless degrees.is_a?(Integer) || (degrees.is_a?(Numeric) && degrees == degrees.round)
        degrees = degrees.round
        return exact(n + degrees) if @chromatic

        deg, offset = degree(n)
        exact(note_from(deg + degrees) + offset)
      end

      # True if +note+ (a note number or Note) is in the scale.
      def include?(note)
        degree(note)[1] == 0
      end

      # Returns the scale note nearest to +note+ (a note number or Note):
      # +direction+ :nearest (ties go down), :down, or :up.
      def snap(note, direction = :nearest)
        n = number(note)
        deg, offset = degree(n)
        return exact(n) if offset == 0

        below = note_from(deg)
        above = note_from(deg + 1)
        case direction
        when :down then below
        when :up then above
        when :nearest then (n - below) <= (above - n) ? below : above
        else raise ArgumentError, "Snap direction must be :nearest, :down, or :up (got #{direction.inspect})"
        end
      end

      # The note numbers of a chord built on +degree+ from every +step+th
      # scale note (+size+ notes; thirds by default, so a triad):
      # `Scale[:major].chord(1)` is D minor in C major.
      def chord(degree, size = 3, step: 2)
        Array.new(size) { |i| note(degree + i * step) }
      end

      # The Notes of the scale within +range+ (a Range of Notes or note
      # numbers).
      def notes(range)
        lo = number(range.begin)
        hi = number(range.end)
        deg = degree(lo)
        d = deg[1] == 0 ? deg[0] : deg[0] + 1
        list = []
        while (n = note_from(d)) <= hi
          list << Note.new(n) unless range.exclude_end? && n == hi
          d += 1
        end
        list
      end

      def <=>(other)
        return nil unless other.is_a?(Scale)
        [@root, @period, @offsets] <=> [other.root, other.period, other.offsets]
      end

      def ==(other)
        other.is_a?(Scale) && @root == other.root && @period == other.period && @offsets == other.offsets
      end
      alias eql? ==

      def hash
        [@root, @period, @offsets].hash
      end

      def to_s
        root = Note.new(@root).to_s rescue @root.to_s
        "#{root} #{@name || @offsets.inspect}#{" period #{@period}" if @period != 12}"
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      private

      # The note of degree +deg+ counted from the root note (without
      # Integer checks; see #note).
      def note_from(deg)
        octave, idx = deg.divmod(size)
        @root + octave * @period + @offsets[idx]
      end

      def number(note)
        case note
        when Numeric then note
        when Pitch then note.respond_to?(:detuned_number) ? note.detuned_number : Note.new(note).number
        else
          raise ArgumentError, "Expected a note number or Note (got #{note.inspect})" unless note.respond_to?(:number)
          note.number
        end
      end

      # Whole Floats and Rationals become Integers, so note numbers keep
      # their MIDI bytes.
      def exact(value)
        if value.is_a?(Float) || value.is_a?(Rational)
          value.finite? && value == value.round ? value.round : value
        else
          value
        end
      end

      public

      # The 12-note chromatic scale, whose degrees are semitones (the
      # default scale of every transform taking a scale).
      CHROMATIC = new(:chromatic)
    end
  end
end
