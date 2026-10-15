module MB
  module Sound
    module Generative
      # Weights over note numbers, to draw notes from: a probability scale
      # (Weights) spread over a range of notes times a bell around a center
      # note (the octave-range layer of GitHub issue #64).  Made with
      # Weights#over or Harmony#over (which gives a Field for each moment);
      # draw with Dice#pick or #draw.
      #
      #     f = scale(:dorian, :d).weights.over(A3..A5, around: E5, width: 6)
      #     f.draw(0.3)              # => 74 (a note number, by weight)
      #     dice.pick(f, :note, i)   # the same with a counter-based draw
      #     f.tonal                  # the field's strongest notes, low to high
      #     f ** 2                   # sharpened: strong notes win more often
      class Field
        include Value

        # Bell weights below this count as outside the register (for
        # #tonal and #home).
        REGISTER = 0.05

        # The note numbers (Integers, low to high).
        attr_reader :notes

        # The weight of each note (pitch class weight times the bell).
        attr_reader :weights

        # The pitch class weight of each note inside the register (0
        # outside): which notes count as the scale, whatever the bell.
        attr_reader :harmonic

        # A Field of +weights+ (Weights) over +range+ (see Weights#over).
        def self.build(weights, range, around: nil, width: nil)
          notes, bell = Field.bell(range, around: around, width: width)
          from_bell(notes, bell, weights.pc)
        end

        # The notes of +range+ and the bell's weight for each (see
        # Weights#over), checking the arguments.
        def self.bell(range, around: nil, width: nil)
          raise ArgumentError, "A Field's range is a Range of notes (got #{range.inspect})" unless range.is_a?(Range) && range.begin && range.end
          lo = Scale.root_number(range.begin)
          hi = Scale.root_number(range.end)
          hi -= 1 if range.exclude_end?
          raise ArgumentError, "A Field's range needs whole notes from low to high (got #{range})" unless lo == lo.round && hi == hi.round && hi >= lo
          raise ArgumentError, "A Field spans at most 128 notes (got #{range})" if hi - lo >= 128
          raise ArgumentError, "A Field's bell width is a positive number of semitones (got #{width.inspect})" unless width.nil? || (width.is_a?(Numeric) && width > 0)

          lo = lo.round
          hi = hi.round
          center = around ? Scale.root_number(around).to_f : (lo + hi) / 2.0
          notes = (lo..hi).to_a.freeze
          [notes, notes.map { |n| width ? Math.exp(-0.5 * ((n - center) / width.to_f)**2) : 1.0 }.freeze]
        end

        # A Field of pitch class weights +pcs+ (12 Floats) over +notes+
        # with +bell+ (see .bell).
        def self.from_bell(notes, bell, pcs)
          lo = notes.first
          len = notes.length
          weights = Array.new(len)
          harmonic = Array.new(len)
          i = 0
          while i < len
            w = pcs[(lo + i) % 12]
            b = bell[i]
            weights[i] = w * b
            harmonic[i] = b >= REGISTER ? w : 0.0
            i += 1
          end
          new(notes, weights.freeze, harmonic.freeze)
        end

        def initialize(notes, weights, harmonic = weights)
          raise ArgumentError, 'A Field needs as many weights as notes' unless notes.length == weights.length && notes.length == harmonic.length
          @notes = notes.freeze
          @weights = weights.frozen? ? weights : weights.map(&:to_f).freeze
          @harmonic = harmonic.frozen? ? harmonic : harmonic.map(&:to_f).freeze
          # Notes of a range (every Field the library makes) index by
          # arithmetic; others through a Hash
          @lo = notes.first
          @index = notes.empty? || notes.last - notes.first == notes.length - 1 ? nil : notes.each_with_index.to_h.freeze
        end

        # Freezes after the recipe is set (see Value#with_recipe).
        def with_recipe(*)
          super
          freeze
        end

        # The weight of note +n+ (0 outside the field).
        def [](n)
          n = Scale.root_number(n) unless n.is_a?(Integer)
          i = @index ? @index[n] : (@lo && n - @lo)
          i && i >= 0 && i < @weights.length ? @weights[i] : 0.0
        end

        # A note number drawn by weight with the uniform +u+ (0...1), or nil
        # if every weight is 0.
        def draw(u)
          i = Dice.index(@weights, u)
          i ? @notes[i] : nil
        end

        # The field with every weight raised to +power+ (above 1 favors the
        # strongest notes).
        def **(other)
          raise ArgumentError, 'Fields raise to number powers' unless other.is_a?(Numeric)
          Field.new(@notes, @weights.map { |w| w**other.to_f }, @harmonic).with_recipe(self, :**, [other])
        end

        # The field itself at any time (see FieldTimeline#at).
        def at(_position = nil)
          self
        end

        # The notes whose pitch class weighs at least +threshold+ of the
        # strongest inside the register, low to high: the field's scale for
        # stepwise motion.
        def tonal(threshold = 0.3)
          m = @harmonic.max
          return [] unless m > 0
          @notes.select.with_index { |_, i| @harmonic[i] > 0 && @harmonic[i] >= m * threshold }
        end

        # The strongest note (by pitch class) nearest +near+ (a note to land
        # on), or nil for an empty field.
        def home(near)
          m = @harmonic.max
          return nil unless m > 0
          near = Scale.root_number(near) unless near.is_a?(Integer)
          @notes.select.with_index { |_, i| @harmonic[i] >= m * 0.999 }.min_by { |n| [(n - near).abs, n] }
        end

        # Draws among +target+ and its neighbors within +reach+ semitones by
        # weight, the target's weight counted +stick+ times, with the
        # uniform +u+: blurred wrong notes win only where they have weight.
        def near(target, u, reach: 1, stick: 3)
          options = ((target - reach)..(target + reach)).to_a
          w = options.map { |n| self[n] * (n == target ? stick : 1) }
          i = Dice.index(w, u)
          i ? options[i] : target
        end

        def ==(other)
          other.is_a?(Field) && other.notes == @notes && other.weights == @weights
        end
        alias eql? ==

        def hash
          [@notes, @weights].hash
        end

        def to_s
          m = @weights.max
          return "Field(#{@notes.first}..#{@notes.last}, empty)" unless m > 0
          bars = @notes.each_with_index.filter_map { |n, i|
            next if @weights[i] < m / 16
            "#{MB::Sound::Note.new(n).name}#{Weights::BARS[(@weights[i] / m * 8).round]}"
          }
          "Field(#{bars.join(' ')})"
        end

        def inspect
          "#<#{self}>"
        end

        def plain_ruby(_value_text)
          "nil # FIXME(graph-io): a Field without a recipe"
        end
      end
    end
  end
end
