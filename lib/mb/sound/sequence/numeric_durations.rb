module MB
  module Sound
    module Sequence
      # Musical length methods added to Numeric, returning Durations:
      #
      #     2.bars      # bars of the current Sequence.transport's bar length
      #     3.beats     # quarter-note beats
      #     3.n16       # three sixteenth notes (n1 through n128; see Duration::DIVISIONS)
      #     3.sixteenths, 1.eighth, 2.quarters, 1.half, 1.whole
      #     1.n8.dotted # (or .d; also .triplet/.t and .double_dotted/.dd)
      #
      # Long names stop at sixteenths, since e.g. `3.thirty_seconds` would
      # read as a time; use n32 and n64 for those.
      module NumericDurations
        # Returns a Duration of this many bars, using the bar length of the
        # current Sequence.transport.
        def bars
          Duration.new(Duration.rational(self) * Sequence.transport.bar_length, label: "#{self} #{self == 1 ? 'bar' : 'bars'}")
        end
        alias bar bars

        # Returns a Duration of this many quarter-note beats.
        def beats
          Duration.new(Duration.rational(self) / 4, label: "#{self} #{self == 1 ? 'beat' : 'beats'}")
        end
        alias beat beats

        # Returns a Duration of this many 1/+k+ notes (e.g. `3.n(16)` for three
        # sixteenth notes).  Common divisions have their own methods, e.g.
        # #n16.
        def n(k)
          k = Integer(k)
          raise ArgumentError, "Note division must be positive (got #{k})" unless k > 0
          Duration.new(Duration.rational(self) / k, label: self == 1 ? "n#{k}" : "#{self} × n#{k}")
        end

        Duration::DIVISIONS.each do |k|
          define_method("n#{k}") { n(k) }
        end

        # Long names, singular and plural (e.g. 1.sixteenth, 3.sixteenths)
        {
          whole: :wholes,
          half: :halves,
          quarter: :quarters,
          eighth: :eighths,
          sixteenth: :sixteenths,
        }.each do |name, plural|
          k = Duration::NAMES.fetch(name)
          define_method(name) { n(k) }
          alias_method plural, name
        end
      end

      ::Numeric.include(NumericDurations)
    end
  end
end
