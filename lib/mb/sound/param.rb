require 'did_you_mean'
require_relative 'session/names' # (Session::Name: rack knob names' leaves)

module MB
  module Sound
    # One declared parameter (param-1, 2026-10-24; the maintainer's library
    # design: "one frozen Param record, built by every declaration form and
    # read by every consumer").  Knob specs (GraphNode::Knob::Spec), MIDI
    # controller specs (MIDI::ControlSpec), script options
    # (ScriptRunner::Param), graph-document `param` and `knob` lines, rack
    # knobs, and ArgTypes signatures all build one, so their names, ranges,
    # curves, and checks agree.  See design/notes/params.md.
    #
    # Types and units come from the values (ArgTypes.classify): a default of
    # 2400.hz is a frequency, 2.4.seconds a time, -12.db a level, 1.n16 a
    # musical length.  +type:+ is optional (it types plain numbers:
    # `param :cutoff, 2400.0, type: :frequency` is in Hz); +unit:+ is only
    # for plain numbers (`unit: "%"`).
    #
    # - A Range is the allowed span; its endpoints must classify alike, and
    #   the default must lie inside it.  An Integer range with an Integer
    #   (or no) default is stepped (#stepped?).  An Array is a list of
    #   choices (Symbols: an enum).
    # - The curve (how a 0..1 position maps onto the range, for knobs and
    #   controllers) defaults by type: :exp for frequencies and times
    #   (seconds, samples, musical lengths, tempos), dB-linear for
    #   Decibels (:exp over the gains they stand for, which is linear in
    #   dB), :switch for true/false, :linear otherwise.  A range touching
    #   0 can't be :exp, so it falls back to :linear unless +curve:+ says
    #   :exp (an error).  CURVES lists the names and aliases.
    # - Names imply ranges (NAMES): without a +range:+, a param named like a
    #   common control (cutoff, resonance, mix, attack, ...) takes the
    #   table's range and curve when its default has the table's type
    #   (`param :cutoff, 2400.hz` is 20.hz..20000.hz, exponential).  An
    #   explicit range always wins.  #implied is true for such params, and
    #   printed forms leave the range out (the name brings it back).
    # - Ranged defaults: `(lo..hi).at(default)` (Range#at, the canonical and
    #   printed spelling) or `default.in(lo..hi)` give a default and its
    #   range as one value (a Param::Ranged) wherever a declaration takes a
    #   default.
    #
    # +clamp: false+ lets values leave the range ("sometimes going out of
    # bounds is interesting"): defaults and checked values pass as they
    # are, and the range still scales knobs, TUI controls, and MIDI.
    #
    # Checks run where a value arrives (declaration, document load, #check
    # from `turn`), never per sample.  Out of range goes through
    # MB::Sound.live_error: an error in scripts and specs, a warning live
    # (where #check clamps).  Messages show the value, the range, the
    # description, and a spelling that would work.
    #
    # The ArgTypes fields: +types+ ({ type => meaning in words }; derived
    # from the default when not given), +keyword+, and +primary+ (see
    # ArgTypes::Signature, which takes these records as its params).
    #
    #     Param.declare(:cutoff, 2400.hz, range: 150.hz..8000.hz, description: 'Lowpass center')
    #     Param.declare(:cutoff, (150.hz..8000.hz).at(2400.hz))      # the same
    #     Param.declare(:voices, 4)                                  # 1..32, stepped (NAMES)
    #     Param.declare(:mode, :tape, range: %i[tape bbd digital])   # an enum
    class Param < Data.define(:name, :default, :range, :type, :curve, :unit, :description, :cc, :implied, :types, :keyword, :primary, :clamp)
      # Canonical curve names, and the aliases each accepts (Knob's old
      # :lin/:exponential/:log, ControlSpec's :exponential, and :db for
      # dB-linear, which is :exp over gains).
      CURVES = {
        linear: :linear, lin: :linear,
        exp: :exp, exponential: :exp, log: :exp, db: :exp,
        switch: :switch, enum: :switch,
      }.freeze

      # Types from values beyond ArgTypes': true/false, Strings, and
      # values nothing types (nil defaults, Procs).
      EXTRA_TYPES = {
        boolean: 'true or false',
        string: 'a String',
        any: 'any value',
      }.freeze

      # Types whose default curve is :exp (frequencies and times).
      EXP_TYPES = %i[frequency seconds samples duration tempo decibels].freeze

      # The names in the names table (Param.names), aliases included.
      NAME_KEYS = %i[
        cutoff frequency freq resonance reso quality q drive mix detune voices attack decay sustain release
        gain threshold pan width rate depth feedback
      ].freeze

      # Types a plain number can count in (`type: :frequency` with 2400.0).
      UNIT_TYPES = %i[frequency seconds samples duration decibels interval phase tempo ratio].freeze

      # Display units for plain numbers of a typed param (`type:
      # :frequency` with a Float default); typed values print themselves.
      TYPE_UNITS = { frequency: 'Hz', seconds: 's', samples: 'samples' }.freeze

      # An out-of-range or mistyped value (ArgTypes::ArgumentTypeError: its
      # suggestions print as "Did you mean?" lines).
      class Error < ArgTypes::ArgumentTypeError; end

      # A default with its range: what `(lo..hi).at(default)` and
      # `default.in(lo..hi)` make.  Declarations unpack it; it checks the
      # range and the default's type when made, so a mistake raises at the
      # line that wrote it (whether the default lies inside is the
      # declaration's to check: `clamp: false` lets it leave the range).
      class Ranged < Data.define(:range, :default)
        def initialize(range:, default:)
          range, default = Param.unify_units(range, default)
          Param.check_range!(nil, range, default, inside: false)
          super(range: range, default: default)
        end

        # The canonical spelling: (lo..hi).at(default).
        def to_ruby
          "(#{Param.literal(range)}).at(#{Param.literal(default)})"
        end

        def inspect = "#<Param::Ranged #{to_ruby}>"
        def to_s = to_ruby

        # Value equality (Pitches compare by identity as graph nodes, so
        # Data's own == would not do; see Param.value_key).
        def ==(other)
          other.is_a?(Ranged) && Param.value_key(range) == Param.value_key(other.range) && Param.value_key(default) == Param.value_key(other.default)
        end
        alias eql? ==

        def hash = [Ranged, Param.value_key(range), Param.value_key(default)].hash
      end

      # Range#at: a ranged default (`(150.hz..8000.hz).at(2400.hz)`).
      module RangeAt
        # A Param::Ranged: this range with +default+ inside it.
        def at(default)
          Param::Ranged.new(range: self, default: default)
        end
      end

      # #in on numbers and unit values: `2400.hz.in(150.hz..8000.hz)`, the
      # same Param::Ranged as Range#at.
      module ValueIn
        # A Param::Ranged: this value as the default of +range+.
        def in(range)
          Param::Ranged.new(range: range, default: self)
        end
      end

      class << self
        # Builds a Param from the line form shared by every declaration:
        # +name+, a +default+ (or a Param::Ranged), and the keywords of
        # #initialize.
        def declare(name, default = nil, **options)
          new(name: name, default: default, **options)
        end

        # The names table (see the class comment): name => { range:,
        # curve:, description: }, aliases included.  Built on first use
        # (its ranges are unit values).
        def names
          @names ||= build_names
        end

        # The names-table entry for +name+ (a Symbol; a rack knob's
        # :"dub/space" looks up :space), or nil.
        def name_entry(name)
          return nil unless name.is_a?(Symbol) || name.is_a?(String)
          key = NAME_KEYS.include?(name.to_sym) ? name.to_sym : Session::Name[name.to_sym].leaf
          # (checked first, so declarations made while mb-sound loads
          # don't build the table before its unit classes exist)
          return nil unless NAME_KEYS.include?(key)
          names[key]
        end

        # The type of value +v+: an ArgTypes type, :boolean, :string, or
        # nil (nil, or anything else).
        def type_of(v)
          case v
          when nil then nil
          when true, false then :boolean
          when Integer, Float then :number # (also before Notes and Clips load: ControlSpecs made at load)
          when String then :string
          else
            t = ArgTypes.classify(v)
            t == :node ? :node : t
          end
        end

        # +v+ as a plain number in its type's base unit: Hz for pitches and
        # notes, seconds, samples, whole notes, semitones, cycles, BPM, the
        # linear gain of a Decibels; plain numbers as they are (Integers
        # stay Integers, for stepped params).
        def magnitude(v)
          case v
          when Integer then v
          when MB::Sound::Decibels then v.to_f
          when Numeric then v.to_f
          when MB::Sound::Pitch then v.frequency.to_f
          when MB::Sound::Length::Seconds then v.to_seconds
          when MB::Sound::Length::Samples then v.to_samples
          when MB::Sound::Sequence::Duration then v.to_f
          when MB::Sound::Interval then v.semitones.to_f
          when MB::Sound::Phase then v.to_f
          when MB::Sound::Tempo then v.to_f
          else
            raise Error.new("#{ArgTypes.describe_value(v)} isn't a number or a unit value")
          end
        end

        # A key comparing +v+ by value: unit values that are graph nodes
        # (Pitches, Notes) compare by identity themselves, so Params and
        # Knob specs compare these keys.
        def value_key(v)
          case v
          when Range then [Range, value_key(v.begin), value_key(v.end), v.exclude_end?]
          when Array then v.map { |x| value_key(x) }
          when Hash then v.to_h { |k, x| [k, value_key(x)] }
          when MB::Sound::Note then [MB::Sound::Note, v.number]
          when MB::Sound::Pitch then [MB::Sound::Pitch, v.frequency]
          else v
          end
        end

        # Ruby text for +v+ (MB::Sound::RubyValue with gains: unit values
        # print themselves: 2400.hz, -12.db), else its inspect.
        def literal(v)
          RubyValue.text(v, gains: true) || v.inspect
        end

        # Checks +range+ (a Range, an Array of choices, or nil) and
        # +default+ for param +name+ (nil for a bare Ranged): endpoints of
        # one type, going up, and the default of the range's type (raising
        # Param::Error: mistakes in the code).  A default outside the
        # range (when +inside+) goes through MB::Sound.live_error and is
        # limited to it, unless +clamp+ is false.  Returns the default.
        def check_range!(name, range, default, description: nil, inside: true, clamp: true)
          what = name ? "#{name}: " : ''
          case range
          when nil
            nil
          when Range
            lo = range.begin
            hi = range.end
            raise Error.new("#{what}a range needs at least one end (got #{range.inspect})") if lo.nil? && hi.nil?
            types = [lo, hi].compact.map { |e| type_of(e) }
            if types.uniq.length > 1
              raise Error.new("#{what}#{literal(range)} mixes #{ArgTypes.describe(types[0])} and #{ArgTypes.describe(types[1])}; write both ends alike")
            end
            type = types[0]
            unless type && ![:node, :name, :string, :boolean, :curve, :notes].include?(type)
              raise Error.new("#{what}a range needs numbers or unit values at its ends (got #{range.inspect})")
            end
            if lo && hi
              a = magnitude(lo)
              b = magnitude(hi)
              raise Error.new("#{what}#{literal(range)} must go up") unless b > a || (b == a && !range.exclude_end?)
            end
            return check_default!(name, range, type, default, description, inside && clamp) unless default.nil?
          when Array
            raise Error.new("#{what}a list of choices can't be empty") if range.empty?
            if !default.nil? && !range.include?(default)
              raise Error.new(
                "#{what}#{default.inspect} isn't one of #{range.map(&:inspect).join(', ')}#{" (#{description})" if description}",
                suggest_choice(default, range)
              )
            end
          else
            raise Error.new("#{what}range: is a Range or an Array of choices (got #{range.inspect})")
          end
          default
        end

        # +number+ (a base-unit number) as a value of +sample+'s type
        # (2400.0 with a Pitch sample is 2400.hz); plain numbers as they
        # are.
        def retype(sample, number)
          case sample
          when MB::Sound::Pitch then number.hz
          when MB::Sound::Length::Seconds then MB::Sound::Length::Seconds.new(number.to_f)
          when MB::Sound::Length::Samples then MB::Sound::Length::Samples.new(number)
          when MB::Sound::Decibels then MB::Sound::Decibels.new((20 * Math.log10(number.to_f)).round(9))
          when MB::Sound::Sequence::Duration then MB::Sound::Sequence::Duration.new(number.to_r)
          when MB::Sound::Interval then number.to_f.semitones
          when MB::Sound::Phase then number.to_f.cycles
          when MB::Sound::Tempo then number.to_f.bpm
          else number
          end
        end

        # Units once (omnibus15; maintainer, 2026-10-28: "I'd like to
        # specify the unit only once as long as it's not ambiguous or
        # contradictory"): when the ends of +range+ and +default+ hold
        # values of exactly one unit type besides plain numbers, the plain
        # numbers take it (`(100..8000).at(150.hz)`, `(100.hz..8000).at(150)`
        # and `150.hz.in(100..8000)` are all 100.hz..8000.hz at 150.hz; the
        # canonical form prints every value typed).  Plain numbers beside
        # Decibels are linear gains (the db rule), so a plain 0 or below
        # raises; two unit types are left for #check_range! to name.
        # Returns [range, default].
        def unify_units(range, default, name = nil)
          return [range, default] unless range.is_a?(Range)
          vals = [range.begin, range.end, default].compact
          # (Rationals are plain beside other units: (1/16r..1).at(1.n8))
          rational = vals.any? { |v| !plain_number?(v) && !v.is_a?(Rational) }
          plain = ->(v) { plain_number?(v) || (rational && v.is_a?(Rational)) }
          typed = vals.reject(&plain)
          return [range, default] if typed.empty? || typed.length == vals.length
          kinds = typed.uniq { |v| type_of(v) }
          if kinds.length > 1
            raise Error.new("#{name ? "#{name}: " : ''}#{literal(range)} with #{literal(default)} mixes " \
                            "#{kinds.map { |v| "#{describe_type(type_of(v)).sub(/ \(.*\)\z/, '')} (#{literal(v)})" }.join(' and ')}; give one unit (plain numbers take it)")
          end
          sample = typed.first
          return [range, default] if plain_number?(retype(sample, 1.0))

          conv = ->(v) {
            next v unless plain.(v)
            if sample.is_a?(MB::Sound::Decibels) && v <= 0
              raise Error.new("#{name ? "#{name}: " : ''}plain numbers beside #{literal(sample)} are linear gains, so #{v.inspect} has no level; " \
                              "write it in dB too (#{v.zero? ? '-60' : v}.db)")
            end
            retype(sample, v)
          }
          [Range.new(conv.(range.begin), conv.(range.end), range.exclude_end?), conv.(default)]
        end

        # True for Integers and Floats (not unit values, which may be
        # Numeric too: Decibels).
        def plain_number?(v)
          v.is_a?(Integer) || v.instance_of?(Float)
        end

        # Words for a +type+ (ArgTypes' or EXTRA_TYPES).
        def describe_type(type)
          EXTRA_TYPES[type] || ArgTypes.describe(type)
        end

        private

        def check_default!(name, range, type, default, description, inside_check)
          what = name ? "#{name}: " : ''
          dtype = type_of(default)
          if dtype != type
            hint = dtype == :number ? [ArgTypes.example_for(type, default)].compact : []
            raise Error.new(
              "#{what}the default #{ArgTypes.describe_value(default)} isn't #{describe_type(type)} like its range #{literal(range)}#{" (#{description})" if description}",
              hint
            )
          end
          return default unless inside_check
          v = magnitude(default)
          lo = range.begin && magnitude(range.begin)
          hi = range.end && magnitude(range.end)
          inside = (lo.nil? || v >= lo) && (hi.nil? || (range.exclude_end? ? v < hi : v <= hi))
          return default if inside
          limited = retype(default, v.clamp(lo || -Float::INFINITY, hi || Float::INFINITY))
          MB::Sound.live_error(Error.new(
            "#{what}the default #{literal(default)} is outside #{literal(range)}#{" (#{description})" if description}; " \
            "limited to #{literal(limited)} (clamp: false lets it leave the range)"
          ))
          limited
        end

        def suggest_choice(value, choices)
          return [] unless value.is_a?(Symbol) || value.is_a?(String)
          DidYouMean::SpellChecker.new(dictionary: choices.map(&:to_s)).correct(value.to_s).first(3).map { |s| s.to_sym.inspect }
        end

        def build_names
          rows = {
            cutoff: [20.hz..20000.hz, 'Filter cutoff'],
            frequency: [20.hz..20000.hz, 'Frequency'],
            resonance: [0.0..1.0, 'Filter resonance (lp4 scale)'],
            quality: [0.1..20.0, 'Filter quality (Q)', :exp],
            drive: [-24.db..36.db, 'Drive gain'],
            mix: [0.0..1.0, 'Dry/wet mix, 0 dry to 1 wet'],
            detune: [0.cents..150.cents, 'Detune spread'],
            voices: [1..32, 'Voices'],
            attack: [0.1.ms..10.seconds, 'Attack time', :exp],
            decay: [0.1.ms..30.seconds, 'Decay time', :exp],
            sustain: [0.0..1.0, 'Sustain level'],
            release: [0.1.ms..30.seconds, 'Release time', :exp],
            gain: [-60.db..12.db, 'Gain'],
            threshold: [-60.db..0.db, 'Threshold'],
            pan: [-1.0..1.0, 'Pan, -1 left to 1 right'],
            width: [0.0..2.0, 'Stereo width, 0 mono, 1 as is'],
            rate: [0.01.hz..50.hz, 'Modulation rate'],
            depth: [0.0..1.0, 'Modulation depth'],
            feedback: [-1.0..1.0, 'Feedback gain'],
          }
          table = rows.to_h { |n, (range, desc, curve)| [n, { range: range, curve: curve, description: desc }.compact.freeze] }
          { reso: :resonance, freq: :frequency, q: :quality }.each { |a, n| table[a] = table[n] }
          raise 'Param::NAME_KEYS is out of date' unless table.keys.sort == NAME_KEYS.sort
          table.freeze
        end
      end

      # Validates and fills in a declaration (see the class comment).
      # +default+ may be a Param::Ranged (then +range:+ must be nil).
      def initialize(name:, default: nil, range: nil, type: nil, curve: nil, unit: nil, description: nil, cc: nil, implied: nil, types: nil, keyword: nil, primary: false, clamp: true)
        unless name.is_a?(Symbol)
          raise Error.new("Param names are Symbols (got #{name.inspect})")
        end
        if default.is_a?(Ranged)
          raise Error.new("#{name}: give the range once, in (lo..hi).at(default) or in range:") unless range.nil?
          range = default.range
          default = default.default
        end
        if range.is_a?(Set)
          range = range.to_a
        end
        range, default = Param.unify_units(range, default, name)

        unless type.nil? || ArgTypes.type_names.include?(type) || EXTRA_TYPES.key?(type)
          raise Error.new("#{name}: unknown type #{type.inspect}", DidYouMean::SpellChecker.new(dictionary: (ArgTypes.type_names + EXTRA_TYPES.keys).map(&:to_s)).correct(type.to_s).first(2).map { |t| ":#{t}" })
        end
        vtype = Param.type_of(default) || (range.is_a?(Range) && Param.type_of(range.begin || range.end)) || (range.is_a?(Array) && Param.type_of(range.first)) || nil
        vtype = :number if vtype.nil? && type.nil? && range.is_a?(Range)
        vtype ||= type if default.nil? && type && !UNIT_TYPES.include?(type) # (a nil default of a declared type)
        if type && vtype && vtype != type && !(vtype == :number && UNIT_TYPES.include?(type))
          raise Error.new("#{name}: type: #{type.inspect} doesn't match the default #{ArgTypes.describe_value(default)}")
        end
        # (plain numbers keep type :number unless type: says what they
        # count; then the names table can apply in that unit)
        unit_type = type || vtype

        implied = false
        if range.nil? && (entry = Param.name_entry(name))
          etype = Param.type_of(entry[:range].begin)
          if vtype == etype
            range = entry[:range]
            curve ||= entry[:curve]
            implied = true
          elsif vtype == :number && type == etype && etype != :number
            # Plain numbers in the type's unit (type: :frequency): the
            # table's range in that unit
            range = Param.magnitude(entry[:range].begin)..Param.magnitude(entry[:range].end)
            curve ||= entry[:curve]
            implied = true
          end
        end

        raise Error.new("#{name}: clamp: is true or false (got #{clamp.inspect})") unless clamp == true || clamp == false
        default = Param.check_range!(name, range, default, description: description, clamp: clamp)

        c = curve.nil? ? nil : CURVES[curve]
        if !curve.nil? && c.nil?
          raise Error.new("#{name}: unknown curve #{curve.inspect} (#{CURVES.keys.map(&:inspect).join(', ')})",
                          DidYouMean::SpellChecker.new(dictionary: CURVES.keys.map(&:to_s)).correct(curve.to_s).first(2).map { |x| ":#{x}" })
        end
        if c.nil?
          c = if unit_type == :boolean then :switch
              elsif EXP_TYPES.include?(unit_type) then :exp
              else :linear
              end
          c = :linear if c == :exp && !exp_range?(range)
        elsif c == :exp && range.is_a?(Range) && !exp_range?(range)
          raise Error.new("#{name}: an exponential (or dB-linear) range can't include or cross 0 (got #{Param.literal(range)})")
        end

        unless unit.nil? || unit.is_a?(String)
          raise Error.new("#{name}: unit: is a String like \"%\" (got #{unit.inspect})")
        end
        if unit && ![:number, nil].include?(vtype)
          raise Error.new("#{name}: #{ArgTypes.describe_value(default.nil? ? range.begin : default)} carries its own unit; unit: is for plain numbers")
        end
        unit ||= TYPE_UNITS[type] if vtype == :number
        unless cc.nil? || (cc.is_a?(Integer) && cc.between?(0, 127))
          raise Error.new("#{name}: cc: must be 0..127 (got #{cc.inspect})")
        end
        unless description.nil? || description.is_a?(String)
          raise Error.new("#{name}: description: is a String (got #{description.inspect})")
        end

        types ||= begin
          t = unit_type || :any
          { t => description || Param.describe_type(t) }
        end
        bad = types.keys - ArgTypes.type_names - EXTRA_TYPES.keys
        raise Error.new("Unknown types #{bad.inspect} for #{name}") unless bad.empty?

        super(
          name: name, default: default, range: range.frozen? ? range : range.dup.freeze, type: unit_type || :any, curve: c,
          unit: unit && String.new(unit).freeze, description: description && String.new(description).freeze, cc: cc, implied: implied,
          types: Ractor.make_shareable(types.transform_values { |m| m.is_a?(String) ? String.new(m) : m }), keyword: keyword || name, primary: primary,
          clamp: clamp
        )
      end

      # True if this parameter takes values of ArgTypes type +type+ (see
      # ArgTypes::Signature).
      def takes?(type)
        types.key?(type)
      end

      # True for an Integer range with an Integer (or no) default: a
      # stepped control (a TUI knob that clicks).
      def stepped?
        range.is_a?(Range) && [range.begin, range.end].compact.all?(Integer) && (default.nil? || default.is_a?(Integer))
      end

      # True for a list of choices.
      def choices?
        range.is_a?(Array)
      end

      # True for a list of Symbol choices.
      def enum?
        choices? && range.all?(Symbol)
      end

      # True for a range with both ends.
      def bounded?
        range.is_a?(Range) && !range.begin.nil? && !range.end.nil?
      end

      # True for numbers and unit values (what knobs and controllers hold).
      def numeric?
        !choices? && !%i[boolean string name any node curve notes].include?(type)
      end

      # The range as plain numbers in the type's base unit (see
      # Param.magnitude), as Floats: what a knob's range is.  nil without
      # a bounded range.
      def magnitude_range
        return nil unless bounded?
        Param.magnitude(range.begin).to_f..Param.magnitude(range.end).to_f
      end

      # +number+ (a plain number in the type's base unit) as this param's
      # typed value: 2400.0 => 2400.hz for a frequency param declared with
      # a Pitch.  Plain-number params give the number back.
      def typed(number)
        Param.retype(default.nil? ? (range.is_a?(Range) ? (range.begin || range.end) : nil) : default, number)
      end

      # Checks +value+ (a typed value or a plain number in the base unit)
      # where it arrives (a turn, a load, a build): returns the value, or,
      # out of range, goes through MB::Sound.live_error (raising in scripts
      # and specs) and returns the value limited to the range (live).
      # +what+ names the action in messages ("turn :cut").  Graph nodes
      # pass unchecked.
      def check(value, what: nil)
        return value if value.nil? || Param.type_of(value) == :node
        if choices?
          return value if range.include?(value)
          MB::Sound.live_error(Error.new(
            "#{what || name}: #{value.inspect} isn't one of #{range.map(&:inspect).join(', ')}#{" (#{description})" if description}",
            Param.send(:suggest_choice, value, range)
          ))
          return default
        end
        return value unless range.is_a?(Range)

        v = begin
          plain = value.is_a?(Numeric) && !value.is_a?(MB::Sound::Decibels) ? value : nil
          plain || (Param.type_of(value) == Param.type_of(range.begin || range.end) ? Param.magnitude(value) : nil)
        rescue Error
          nil
        end
        if v.nil?
          MB::Sound.live_error(Error.new("#{what || name}: #{ArgTypes.describe_value(value)} isn't #{Param.describe_type(type)} like #{Param.literal(range)}#{" (#{description})" if description}"))
          return default
        end
        lo = range.begin && Param.magnitude(range.begin)
        hi = range.end && Param.magnitude(range.end)
        return value if !clamp || ((lo.nil? || v >= lo) && (hi.nil? || v <= hi))

        limited = v.clamp(lo || -Float::INFINITY, hi || Float::INFINITY)
        MB::Sound.live_error(Error.new(
          "#{what || name}: #{Param.literal(value)} is outside #{Param.literal(range)}#{" (#{description})" if description}; limited to #{Param.literal(value.is_a?(Numeric) && !value.is_a?(MB::Sound::Decibels) ? limited : typed(limited))}"
        ))
        value.is_a?(Numeric) && !value.is_a?(MB::Sound::Decibels) ? limited : typed(limited)
      end

      # The 0..1 position of +value+ (a typed value or a plain number in
      # the base unit) along the param's range and curve: what a knob, a
      # MIDI controller, a TUI slider, and (later) morph, randomize, and
      # macros move in, so a cutoff moves evenly in pitch and a gain
      # evenly in dB ("plain and normalized parameters", maintainer's DYK
      # mark "try", 2026-10-25).  :exp ranges are logarithmic (Decibels:
      # even in dB), :linear and stepped ones linear, choices by index
      # (0 for the first, 1 for the last), :switch and booleans 0 or 1.
      # Values outside the range give positions outside 0..1.  Raises
      # ArgumentError for params without a bounded range or choices.
      def position(value)
        if choices?
          i = range.index(value)
          raise ArgumentError, "#{name}: #{value.inspect} isn't one of #{range.map(&:inspect).join(', ')}" unless i
          return range.length > 1 ? i.to_f / (range.length - 1) : 0.0
        end
        return value ? 1.0 : 0.0 if type == :boolean
        lo, hi = position_ends
        v = value.is_a?(Numeric) && !value.is_a?(MB::Sound::Decibels) ? value.to_f : Param.magnitude(value).to_f
        Scale.position(v, lo, hi, curve)
      end

      # The value at +position+ (see #position; 0 is the range's start, 1
      # its end): typed as declared (2400.hz, -12.db), rounded to whole
      # steps for stepped params, the nearest choice for lists, true at
      # 0.5 and above for booleans.  Positions outside 0..1 give values
      # outside the range (#check limits them).
      def value(position)
        pos = position.to_f
        if choices?
          return range[(pos * (range.length - 1)).round.clamp(0, range.length - 1)]
        end
        return pos >= 0.5 if type == :boolean
        lo, hi = position_ends
        v = Scale.value(pos, lo, hi, curve)
        return v.round if stepped?
        typed(v)
      end

      # A GraphNode::Knob::Spec for this param (+options+: takeover:,
      # smooth:, or a different default:).
      def knob_spec(**options)
        GraphNode::Knob::Spec.new(name: name, param: self, **options)
      end

      # A MIDI::ControlSpec on controller +number+ (this param's +cc+ by
      # default), with the default's raw position.
      def control_spec(number: cc, **options)
        MIDI::ControlSpec.from_param(self, number: number, **options)
      end

      # The canonical declaration line: `param :cutoff,
      # (150.hz..8000.hz).at(2400.hz), description: "..."` (the range left
      # out when the names table implies it), with +head+ ('param', or
      # 'knob') and +value+ (the default unless given; a base-unit number
      # prints typed as declared), values printed by +literal+
      # (Param.literal unless given).
      def to_ruby(head = 'param', value: default, literal: nil)
        "#{head} #{declaration_args(value: value, literal: literal).join(', ')}"
      end

      # The arguments of the declaration line (see #to_ruby) as texts: the
      # name, the value (ranged unless implied), and the options that
      # differ from their defaults, with +options+ (texts, e.g. a knob's
      # takeover:) after cc:, +cc+ (this param's unless given), and the
      # description unless +description+ is false.  Knob::Spec#call_args
      # prints knobs with it.
      def declaration_args(value: default, literal: nil, cc: self.cc, description: true, options: [])
        lit = literal || Param.method(:literal)
        v = Param.type_of(value) == :number ? typed(value) : value
        v = v.round if stepped? && v.is_a?(Float) && v == v.round
        # (a plain-number value prints as a plain number: literals print
        # Floats that are exact tenths of a dB as -6.db, which a plain
        # range's check refuses on load; omnibus17)
        val = type == :number && v.is_a?(Float) && v.finite? ? RubyValue.number(v) : lit.(v)
        text = if range && !implied && !v.nil?
                 choices? ? "#{val}, range: #{lit.(range)}" : "(#{lit.(range)}).at(#{val})"
               elsif range && !implied
                 "nil, range: #{lit.(range)}"
               else
                 val
               end
        [name.inspect, text, *extras(lit, cc: cc, description: description, options: options)]
      end

      # The graph-document header line (format 5, the canonical spelling:
      # `param :cutoff, (150.0..8000.0).at(2400.0), description: "..."`)
      # at +value+ (the document's current value, a base-unit number or a
      # typed value; the default unless given).
      def document_line(value = default, writer: nil)
        to_ruby('param', value: value, literal: writer&.method(:literal))
      end

      # One help line: "cutoff  2400.hz  20.hz..20000.hz exp  Filter
      # cutoff" (name, default, range and curve, description).
      def help_line
        span = case range
               when Range then "#{Param.literal(range)}#{" #{curve}" unless curve == :linear}#{' stepped' if stepped?}"
               when Array then "one of #{range.map(&:inspect).join(', ')}"
               end
        span = "#{span} (#{unit})" if span && unit
        desc = description || (implied && Param.name_entry(name)[:description])
        [name.to_s.ljust(12), Param.literal(default).ljust(10), span, desc].compact.join('  ').rstrip
      end

      # The curve this param's type would have without +curve:+.
      def default_curve
        c = if type == :boolean then :switch
            elsif EXP_TYPES.include?(type) then :exp
            else :linear
            end
        c == :exp && !exp_range?(range) ? :linear : c
      end

      def to_s = help_line
      def inspect = "#<MB::Sound::Param #{to_ruby}>"

      # Value equality (see Param.value_key).
      def ==(other)
        other.is_a?(Param) && value_key == other.value_key
      end
      alias eql? ==

      def hash = [Param, value_key].hash

      protected

      def value_key
        to_h.transform_values { |v| Param.value_key(v) }
      end

      private

      def extras(lit, cc:, description:, options:)
        parts = []
        parts << "curve: #{curve.inspect}" if curve != default_curve && !(implied && Param.name_entry(name)&.dig(:curve) == curve)
        parts << "unit: #{lit.(unit)}" if unit && unit != TYPE_UNITS[type]
        parts << "cc: #{cc}" if cc
        parts.concat(options)
        parts << 'clamp: false' unless clamp
        parts << "description: #{lit.(self.description)}" if description && self.description
        parts
      end

      # The range's ends as base-unit Floats (for #position and #value).
      def position_ends
        r = magnitude_range
        raise ArgumentError, "#{name}: positions need a range with two ends (got #{range.inspect})" unless r && r.end > r.begin
        [r.begin, r.end]
      end

      def exp_range?(r)
        return false unless r.is_a?(Range) && r.begin && r.end
        a = Param.magnitude(r.begin).to_f
        b = Param.magnitude(r.end).to_f
        a * b > 0
      rescue Error
        false
      end
    end

    # ArgTypes signatures take the same record.
    ArgTypes::Param = Param

    require_relative 'param/scale'

    ::Range.include(Param::RangeAt)
    ::Numeric.include(Param::ValueIn)

    # #in on the unit values that aren't Numeric (called from mb/sound.rb
    # once they are loaded).
    def Param.install_value_in!
      [Pitch, Length::Seconds, Length::Samples, Interval, Phase, Sequence::Duration, Tempo].each { |c| c.include(Param::ValueIn) }
    end
  end
end
