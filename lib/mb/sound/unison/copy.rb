module MB
  module Sound
    module Unison
      # Which unison copy a Pitch belongs to (Pitch#unison_copy): its
      # +index+ (copies are numbered from the lowest detune), the unison's
      # +count+, and a random generator seeded from the unison's seed and
      # the index, for per-copy settings.
      #
      # Pitch methods that take per-copy settings (Pitch#transpose, and the
      # Notes pitch methods NotePitch#glide, #vibrato, #bend_range) resolve
      # them with #pick when called on a copy, so one unison block can give
      # each copy its own value:
      #
      # - `spread(a..b)` (MB::Sound#spread): from +a+ for the first copy to
      #   +b+ for the last, evenly by index (the copies' pitch order).
      # - A Range: a random value in the range for each copy, repeatable
      #   from the unison's seed (draws in call order).
      # - `channels(a, b, c)` (or a ChannelValues): one value per copy,
      #   cycling if there are fewer values than copies.
      #
      # Ranges and spreads of Intervals become semitones, and of Lengths
      # (e.g. `40.ms..400.ms`) seconds.
      #
      #     v.hz.unison(9) { |p| p.glide(spread(30.ms..300.ms)).saw }   # low copies arrive first
      #     v.hz.unison(9) { |p| p.glide(0.05..0.5).saw }              # random glide times
      #     v.hz.unison(5) { |p, i| p.glide((i + 1) * 40.ms).saw }      # or use the index
      class Copy
        # The copy's index (0 for the lowest detune).
        attr_reader :index

        # The number of copies in the unison.
        attr_reader :count

        def initialize(index, count, seed)
          @index = index
          @count = count
          @rng = Random.new(Integer(seed) * 65_537 + index)
        end

        # The copy's position from 0 (first) to 1 (last) by index; 0 for a
        # single copy.
        def position
          @count > 1 ? @index.to_f / (@count - 1) : 0.0
        end

        # A random Float in +range+ (numbers, Intervals as semitones, or
        # Lengths as seconds) from this copy's generator.
        def rand(range = 0.0..1.0)
          a, b = Copy.endpoints(range)
          a + (b - a) * @rng.rand
        end

        # Resolves a per-copy +value+ (see the class description); other
        # values are returned unchanged.
        def pick(value)
          case value
          when Range
            rand(value)
          when GraphNode::ChannelSpread
            a, b = Copy.endpoints(value.range)
            @count > 1 ? a + (b - a) * position : a
          when GraphNode::ChannelValues
            v = value.values
            v[@index % v.length]
          else
            value
          end
        end

        # True if +value+ is a per-copy setting that #pick resolves.
        def self.per_copy?(value)
          value.is_a?(Range) || value.is_a?(GraphNode::ChannelSpread) || value.is_a?(GraphNode::ChannelValues)
        end

        # The values given in a per-copy setting (the ends of a Range or
        # spread, or the values of a ChannelValues).
        def self.values_of(value)
          case value
          when Range then [value.begin, value.end]
          when GraphNode::ChannelSpread then [value.range.begin, value.range.end]
          when GraphNode::ChannelValues then value.values
          else [value]
          end
        end

        # The ends of +range+ as Floats (Intervals as semitones, Lengths as
        # seconds).
        def self.endpoints(range)
          [range.begin, range.end].map { |v|
            case v
            when Interval then v.to_semitones.to_f
            when Length then Length.seconds(v).to_f
            when Numeric then v.to_f
            else raise ArgumentError, "Per-copy ranges take numbers, Intervals, or Lengths (got #{range.inspect})"
            end
          }
        end

        def to_s
          "unison copy #{@index + 1} of #{@count}"
        end
      end
    end
  end
end
