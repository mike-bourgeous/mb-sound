module MB
  module Sound
    # The one printer for plain values as Ruby code (printers-1,
    # 2026-10-30): numbers, Decibels, Pitches and Notes, Lengths and
    # Durations, Intervals, Phases, Scales, Ranges, Symbols, Strings,
    # Arrays and Hashes, Params' ranged defaults, Data values, and values
    # that print themselves (Tempo, Clock, Curve, Length::Attack,
    # Generative values).  Recipes' writer, graph and set documents, takes,
    # forms, genre templates, clip `events(...)` rows, Param declarations,
    # and help and UI code panes all print through it, so a value is spelled
    # the same everywhere and reloads as the same value of the same class.
    #
    # Rationals print as `3/4r` and whole ones as `3r` (reloading as
    # Rationals, never Integers); negative ones `-3/4r`.  `3/4r` is a
    # quotient, so it needs parentheses as a receiver (`(3/4r).seconds`) or
    # beside `*`/`/` (see .precedence).
    #
    # Floats print exactly (Float#to_s); with +gains: true+ (the recipe
    # writer and Param declarations) a long Float that is exactly k/10 dB
    # prints as `k.db` (a Decibels, equal to the Float, which every gain
    # argument reads exactly).
    #
    # Nested values (Array and Hash entries, Range ends, ranged defaults,
    # Data fields) go through the block when one is given (the recipe
    # writer prints graph objects there), else through .to_ruby.
    #
    # Guard: spec/lib/mb/sound/ruby_value_spec.rb fails code outside this
    # file that formats Rationals as Ruby itself.
    module RubyValue
      # A value with no Ruby spelling here.
      class Unprintable < ArgumentError; end

      # Class names that print without their MB::Sound:: prefix (documents,
      # takes, and the console all resolve them inside MB::Sound).
      PREFIX = 'MB::Sound::'

      module_function

      # Ruby code for +v+ (see the module description); raises Unprintable
      # for values it can't spell.
      def to_ruby(v, gains: false, &nested)
        text(v, gains: gains, &nested) || raise(Unprintable, "can't print a #{v.class} as Ruby (#{v.inspect[0, 80]})")
      end

      # Ruby code for +v+, or nil when it has no spelling here (for writers
      # with fallbacks of their own).
      def text(v, gains: false, &nested)
        nested ||= ->(x) { to_ruby(x, gains: gains) }
        case v
        when Integer, Float, Rational, Complex, MB::Sound::Decibels then number(v, gains: gains)
        when nil, true, false, Symbol, String then v.inspect
        when Range then range(v, &nested)
        when Array then "[#{v.map { |x| nested.call(x) }.join(', ')}]"
        when Hash then hash(v, &nested)
        when MB::Sound::Length::Samples
          v.origin || !v.value.is_a?(Numeric) ? nil : unit(v.value, 'samples')
        when MB::Sound::Length::Seconds
          v.origin || !v.value.is_a?(Numeric) ? nil : seconds(v.value)
        when MB::Sound::Length::Attack, MB::Sound::Tempo, MB::Sound::Clock then v.to_ruby
        when MB::Sound::Interval then interval(v)
        when MB::Sound::Sequence::Duration then duration(v)
        when MB::Sound::Phase then phase(v)
        when MB::Sound::Pitch then pitch(v)
        when MB::Sound::Scale then scale(v)
        when MB::Sound::Curve then v.to_ruby
        when MB::Sound::Param::Ranged then "(#{nested.call(v.range)}).at(#{nested.call(v.default)})"
        when MB::Sound::Generative::Value then v.to_ruby { |x| nested.call(x) }
        when Module then class_name(v)
        when Data
          name = class_name(v.class)
          name && "#{name}.new(#{v.to_h.map { |k, x| "#{key(k)} #{nested.call(x)}" }.join(', ')})"
        end
      end

      # A number: Integers and Floats as Ruby prints them (infinities and
      # NaN as Float::INFINITY, -Float::INFINITY, Float::NAN), Rationals as
      # `3/4r` or `3r`, Decibels as `-6.db`, Complex as `Complex(a, b)`.
      # +gains+: long Floats that are exactly k/10 dB as `k.db`.
      def number(n, gains: false)
        case n
        when Integer then n.to_s
        when Float
          return 'Float::INFINITY' if n == Float::INFINITY
          return '-Float::INFINITY' if n == -Float::INFINITY
          return 'Float::NAN' if n.nan?
          if gains && n > 0 && n.to_s.length > 8 && (db = (20 * Math.log10(n) * 10).round / 10.0) && db.db == n
            db = db.to_i if db == db.to_i
            "#{db}.db"
          else
            n.to_s
          end
        when Rational then rational(n)
        when MB::Sound::Decibels
          # (a negative literal binds before the call: -6.db)
          d = number(n.decibels)
          precedence(n.decibels) == :quotient || d.include?('::') ? "(#{d}).db" : "#{d}.db"
        when Complex then "Complex(#{number(n.real)}, #{number(n.imaginary)})"
        else n.inspect
        end
      end

      # `3/4r`, `-3/4r`, `3r`.
      def rational(r)
        r.denominator == 1 ? "#{r.numerator}r" : "#{r.numerator}/#{r.denominator}r"
      end

      # How +v+'s text binds as an operand: :atom, :unary (a negative real
      # number: `-3`), or :quotient (a Rational that isn't whole: `3/4r`
      # binds like `/`).
      def precedence(v)
        if v.is_a?(Rational) && v.denominator != 1 then :quotient
        elsif v.is_a?(Numeric) && !v.is_a?(MB::Sound::Decibels) && v.real? && v.negative? then :unary
        else :atom
        end
      end

      # The text of number or value +v+ as a method receiver: parenthesized
      # unless it's an atom (`(3/4r)`, `(-2)`, `2`, `-6.db`).
      def receiver(v, gains: false)
        t = v.is_a?(String) ? v : number(v, gains: gains)
        return t if v.is_a?(String) ? atom_text?(t) : (precedence(v) == :atom && !t.include?('::'))
        "(#{t})"
      end

      # `2.seconds`, `(3/4r).seconds`, `(-0.5).cycles`.
      def unit(n, name)
        "#{receiver(n)}.#{name}"
      end

      # A Hash: `{ a: 1, "b c": 2, 3 => 4 }` (empty `{}`).
      def hash(h, &nested)
        nested ||= method(:to_ruby)
        return '{}' if h.empty?
        "{ #{kwargs(h, &nested)} }"
      end

      # Hash entries as keyword arguments (`a: 1, "b c": 2, 3 => 4`).
      def kwargs(h, &nested)
        nested ||= method(:to_ruby)
        h.map { |k, x| k.is_a?(Symbol) ? "#{key(k)} #{nested.call(x)}" : "#{nested.call(k)} => #{nested.call(x)}" }.join(', ')
      end

      # A Symbol as a Hash key: `name:`, or `"two words":`.
      def key(k)
        k.is_a?(Symbol) && k.to_s.match?(/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/) ? "#{k}:" : "#{k.to_s.inspect}:"
      end

      # `a..b`, `a...b`, `a..`, `..b` (the ends through +nested+).
      def range(r, &nested)
        nested ||= method(:to_ruby)
        b = r.begin.nil? ? '' : nested.call(r.begin)
        e = r.end.nil? ? '' : nested.call(r.end)
        "#{b}#{r.exclude_end? ? '...' : '..'}#{e}"
      end

      # Seconds: Floats that are whole milliseconds as `250.ms`, else
      # `0.3.seconds`, `(1/60r).seconds`.
      def seconds(s)
        ms = (s * 1000).round
        return unit(ms, 'ms') if s.is_a?(Float) && ms.ms.value == s && ms != 0
        unit(s, 'seconds')
      end

      # An Interval in the unit it was made with when that rebuilds it
      # exactly (`2.oct`, `50.cents`, `(-7).st`), else semitones; nil if
      # none does.
      def interval(v)
        unit = v.instance_variable_get(:@unit)
        st = v.semitones
        candidates =
          case unit
          when :octaves then [[st / 12r, 'oct'], [st / 12.0, 'oct']]
          when :cents then [[(st * 100).to_r, 'cents'], [st * 100.0, 'cents']]
          else []
          end
        candidates << [st, 'st']
        candidates.each do |n, u|
          n = n.to_i if n.is_a?(Rational) && n.denominator == 1
          n = n.to_i if n.is_a?(Float) && n == n.round && n.abs < 1e15 && !(st.is_a?(Float))
          iv = n.public_send(u)
          next unless iv.semitones == st && iv.semitones.class == st.class
          return unit(n, u)
        end
        nil
      end

      DURATION_DENOMINATORS = [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32, 64, 128].freeze

      DURATION_MODS = { 'dotted' => 'dotted', 'double dotted' => 'dd', 'triplet' => 'triplet' }.freeze

      # A Duration as the spelling it was made with when that rebuilds it
      # (`1.n8.dotted`, `2.bars`, `(3/2r).bars`), else `k.nN`, else
      # `Sequence::Duration.new(1/192r)`.
      def duration(v)
        r = v.whole_notes
        label = v.to_s
        if (m = label.match(/\A(?:(dotted|double dotted|triplet) )?(?:(\d+) × )?n(\d+)\z/)) && 1.respond_to?("n#{m[3]}")
          k = (m[2] || 1).to_i
          d = k.public_send("n#{m[3]}")
          d = d.public_send(DURATION_MODS[m[1]]) if m[1]
          return "#{k}.n#{m[3]}#{".#{DURATION_MODS[m[1]]}" if m[1]}" if d.whole_notes == r
        elsif (m = label.match(/\A(-?\d+(?:\.\d+)?(?:\/\d+)?) (bar|beat)s?\z/))
          n = if m[1].include?('/') then Rational(m[1])
              elsif m[1].include?('.') then m[1].to_f
              else m[1].to_i
              end
          unit = m[1] == '1' ? m[2] : "#{m[2]}s"
          return unit(n, unit) if n.public_send(unit).whole_notes == r
        end

        DURATION_DENOMINATORS.each do |n|
          k = r * n
          next unless k.denominator == 1
          return "#{k.to_i}.n#{n}"
        end
        "Sequence::Duration.new(#{number(r)})"
      end

      # A Phase in the unit it was made with: `90.degrees`, `1.5.radians`,
      # `0.25.cycles`.
      def phase(v)
        if (deg = v.instance_variable_get(:@degrees))
          deg.is_a?(Numeric) ? unit(deg, 'degrees') : nil
        elsif (rad = v.instance_variable_get(:@radians))
          rad.is_a?(Numeric) ? unit(rad, 'radians') : nil
        else
          v.cycles.is_a?(Numeric) ? unit(v.cycles, 'cycles') : nil
        end
      end

      # A Note's name (A3, Cs4) when it rebuilds the same note, else its
      # frequency (`440.hz`, `440.5.hz`), a tempo-synced pitch as its
      # duration (`1.bar.hz`); nil for pitches following other nodes.
      def pitch(p)
        if p.instance_of?(MB::Sound::Note)
          name = p.to_s
          if name.match?(/\A[A-G][sb]?\d+\z/)
            n = MB::Sound::Note.new(name) rescue nil
            return name if n && n.frequency == p.frequency
          elsif name.match?(/\A[A-G][sb]?-\d+\z/) && p.number == p.number.round
            # Octave -1 has no constant (Fs-1 would be Fs minus 1)
            n = MB::Sound::Note.new(p.number.round)
            return "Note.new(#{p.number.round})" if n.frequency == p.frequency
          end
        end
        unless p.constant?
          # A tempo-synced pitch (`1.bar.hz`) prints as its duration (it
          # printed its frequency at the current tempo before 2026-10-13,
          # losing the tempo sync; patches-1)
          src = p.freq
          if src.is_a?(MB::Sound::Sequence::TempoNode) && src.mode == :hz && !src.freewheel?
            return "#{duration(src.duration)}.hz"
          end
          return nil unless src.is_a?(MB::Sound::GraphNode::Constant)
        end
        f = p.frequency
        return nil unless f.is_a?(Numeric)
        f = f.to_i if f.is_a?(Float) && f == f.round && f.abs < 1e15 && f.to_i.hz.frequency.eql?(f)
        "#{receiver(f)}.hz"
      end

      # A Scale as the call that makes it: `scale(:minor, A4)`; nil for
      # scales that don't repeat at the octave.
      def scale(s)
        return nil unless s.period == 12
        list = s.name && MB::Sound::Scale::OFFSETS[MB::Sound::Scale::ALIASES.fetch(s.name, s.name)] == s.offsets ? s.name.inspect : to_ruby(s.offsets)
        root = s.root.is_a?(Integer) ? pitch(MB::Sound::Note.new(s.root)) : number(s.root)
        "scale(#{list}, #{root})"
      end

      # A class or module's name relative to MB::Sound, or nil if it has
      # none (anonymous).
      def class_name(k)
        n = k.name
        n && n.delete_prefix(PREFIX)
      end

      # Whether +text+ needs no parentheses as a receiver.
      def atom_text?(t)
        t.match?(/\A[A-Za-z_0-9.:]+(\(.*\))?\z/) && !t.include?('/') && !t.start_with?('-')
      end
    end
  end
end
