module MB
  module Sound
    module Generative
      # A probability scale: one weight per pitch class (C = 0, C# = 1, ...
      # B = 11), from GitHub issue #64's "scales as arrays of
      # probabilities".  Weights are relative (a draw normalizes them).
      # They are values, not signal nodes, so operators combine them:
      #
      #     s = scale(:dorian, :d).weights            # D dorian at 1, the rest 0
      #     h = s.blur(0.1) + tones(D3, F3, A3, C4) * 1.2   # layers add; blur leaks to neighbors
      #     h = s.blend(scale(:major, :f).weights, 0.5)     # halfway between keys
      #     f = h.over(A3..A5, around: E5)            # a Field of notes to draw from
      #     dice.pick(f, :note)                       # a Note, by weight
      #     puts h                                    # C▁ C#  D█ D#▁ E▃ ... (a bar chart)
      #
      # Operators: `+` adds layers (Weights, or a number to every class),
      # `*` scales by a number or masks by another Weights (class by
      # class: "in this scale and near this chord"), `**` sharpens (powers
      # above 1 favor the strongest classes), `-` subtracts (floored at 0).
      class Weights
        include Value

        # Pitch class names, for #to_s.
        NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

        # Eighth blocks for the bar chart.
        BARS = ' ▁▂▃▄▅▆▇█'.freeze

        # The weights by pitch class (12 Floats).
        attr_reader :pc

        # Weights from +list+ (12 numbers, C first).
        def self.[](*list)
          list = list.flatten
          new(list).with_recipe(nil, :weights, list)
        end

        # Every pitch class at +weight+.
        def self.chromatic(weight = 1.0)
          new(Array.new(12, weight)).with_recipe(nil, :weights, Array.new(12, weight.to_f))
        end

        # The pitch classes of +notes+ (Notes, note numbers, or names like
        # :a or 'C#') at +weight+ each: a chord layer.
        def self.tones(*notes, weight: 1.0)
          pc = Array.new(12, 0.0)
          notes = notes.flatten
          notes.each { |n| pc[Weights.pitch_class(n)] = weight.to_f }
          new(pc).with_recipe(nil, :tones, notes, weight == 1.0 ? {} : { weight: weight })
        end

        # The weights of +scale+'s notes (a Scale): 1 each, or +degrees+
        # (one weight per scale degree from the root, cycled), others 0.
        def self.of_scale(scale, degrees = nil)
          degrees = Array(degrees).flatten
          pc = Array.new(12, 0.0)
          scale.size.times do |d|
            n = scale.note(d)
            raise ArgumentError, "Scale weights need whole-semitone scales (#{scale} has #{n})" unless n == n.round
            w = degrees.empty? ? 1.0 : degrees[d % degrees.length].to_f
            pc[n.round % 12] += w
          end
          new(pc).with_recipe(scale, :weights, degrees)
        end

        # Raises unless +x+ is Weights or a finite number at least 0.
        def self.check_number(x, op)
          return if x.is_a?(Weights)
          raise ArgumentError, "Weights #{op} takes Weights or a number (got #{x.inspect})" unless x.is_a?(Numeric) && x.real?
          raise ArgumentError, "Weights must be finite and not negative (Weights #{op} #{x})" unless x.finite? && x >= 0
        end

        # The pitch class (0..11) of a Note, note number, or name.
        def self.pitch_class(n)
          v = n.is_a?(Integer) ? n : Scale.root_number(n)
          raise ArgumentError, "Pitch classes need whole note numbers (got #{n.inspect})" unless v == v.round
          v.round % 12
        end

        # Weights from 12 Floats known to be finite and not negative (the
        # results of operations on Weights), skipping the checks.
        def self.raw(pc)
          w = allocate
          w.instance_variable_set(:@pc, pc.freeze)
          w
        end

        def initialize(pc)
          raise ArgumentError, "Weights need 12 pitch classes (got #{pc.length})" unless pc.length == 12
          @pc = pc.map { |w|
            w = Float(w)
            raise ArgumentError, "Weights must be finite and not negative (got #{w})" unless w.finite? && w >= 0
            w
          }.freeze
        end

        # Freezes after the recipe is set (see Value#with_recipe).
        def with_recipe(*)
          super
          freeze
        end

        # The weight of a pitch class (0..11), Note, or note name.
        def [](n)
          @pc[n.is_a?(Integer) && n.between?(0, 11) ? n : Weights.pitch_class(n)]
        end

        def to_a
          @pc.dup
        end

        # Layers added class by class (another Weights), or +other+ added
        # to every class (a number).  With a Harmony, a Harmony: this plus
        # the harmony at each moment (as `harmony + weights`; likewise
        # #- and #*).
        def +(other)
          return Harmony.of_weights(self, :+, other) if other.is_a?(Harmony)
          Weights.check_number(other, :+)
          w = other.is_a?(Weights) ? @pc.each_with_index.map { |x, i| x + other.pc[i] } : @pc.map { |x| x + other.to_f }
          Weights.raw(w).with_recipe(self, :+, [other])
        end

        # Subtracts class by class (or a number from every class), floored at 0.
        def -(other)
          return Harmony.of_weights(self, :-, other) if other.is_a?(Harmony)
          w = other.is_a?(Weights) ? @pc.each_with_index.map { |x, i| x - other.pc[i] } : @pc.map { |x| x - other.to_f }
          Weights.raw(w.map { |x| x < 0 ? 0.0 : x }).with_recipe(self, :-, [other])
        end

        # Scales by a number, or masks class by class by another Weights.
        def *(other)
          return Harmony.of_weights(self, :*, other) if other.is_a?(Harmony)
          Weights.check_number(other, :*)
          w = other.is_a?(Weights) ? @pc.each_with_index.map { |x, i| x * other.pc[i] } : @pc.map { |x| x * other.to_f }
          Weights.raw(w).with_recipe(self, :*, [other])
        end

        # Divides by a number.
        def /(other)
          raise ArgumentError, 'Weights divide by numbers' unless other.is_a?(Numeric)
          Weights.new(@pc.map { |x| x / other.to_f }).with_recipe(self, :/, [other])
        end

        # Raises every weight to +power+: above 1 sharpens (the strongest
        # classes win more often), below 1 flattens toward even.
        def **(other)
          raise ArgumentError, 'Weights raise to number powers' unless other.is_a?(Numeric)
          Weights.new(@pc.map { |x| x**other.to_f }).with_recipe(self, :**, [other])
        end

        # 2 * weights and 0.5 + weights work like weights * 2.
        def coerce(other)
          raise TypeError, "#{other.class} can't be combined with Weights" unless other.is_a?(Numeric)
          [self, other]
        end

        # Leaks +amount+ (0..1) of each weight to the classes a semitone
        # either side (half each side; +reach:+ semitones spreads it
        # further, falling off linearly), so notes outside the layer
        # sometimes win: the issue's blurred scale layers.  The total stays
        # the same.
        def blur(amount, reach: 1)
          raise ArgumentError, "Blur amount is from 0 to 1 (got #{amount.inspect})" unless amount.is_a?(Numeric) && amount.between?(0, 1)
          raise ArgumentError, "Blur reach is an Integer from 1 to 6 (got #{reach.inspect})" unless reach.is_a?(Integer) && reach.between?(1, 6)

          total = (reach * (reach + 1) / 2).to_f
          shares = (1..reach).map { |d| amount * (reach + 1 - d) / total / 2 }
          out = @pc.dup
          i = 0
          while i < 12
            w = @pc[i]
            if w != 0
              d = 1
              while d <= reach
                share = w * shares[d - 1]
                out[(i + d) % 12] += share
                out[(i - d) % 12] += share
                d += 1
              end
              out[i] -= w * amount
            end
            i += 1
          end
          Weights.raw(out.map { |x| x < 0 ? 0.0 : x }).with_recipe(self, :blur, [amount], reach == 1 ? {} : { reach: reach })
        end

        # Every class at least +eps+ times the strongest (anything can
        # happen, rarely).
        def floor(eps)
          m = @pc.max * eps.to_f
          Weights.raw(@pc.map { |w| w < m ? m : w }).with_recipe(self, :floor, [eps])
        end

        # The weights scaled to sum to 1 (unchanged if they're all 0).
        def normalize
          s = sum
          Weights.raw(s > 0 ? @pc.map { |w| w / s } : @pc).with_recipe(self, :normalize)
        end

        # The sum of the weights.
        def sum
          @pc.sum(0.0)
        end

        # The weights +t+ (0..1, clamped) of the way to +other+ (Weights,
        # or a Scale), each side normalized first, so halfway between two
        # keys favors their common tones (pivot notes) while both keys' own
        # notes still play: key and chord transitions.
        def blend(other, t)
          o = Generative.weights(other)
          tt = t.to_f.clamp(0.0, 1.0)
          a = normalized_pc
          b = o.normalized_pc
          Weights.raw(a.each_with_index.map { |x, i| x + (b[i] - x) * tt }).with_recipe(self, :blend, [other, t])
        end

        # The weights spread over the notes in +range+ (Notes, note numbers,
        # or names), times a bell around +around+ (a note; the middle of
        # the range by default) +width+ semitones wide (the bell's standard
        # deviation; nil for a flat range): an octave-range layer.  Returns
        # a Field to draw notes from.
        def over(range, around: nil, width: nil)
          Field.build(self, range, around: around, width: width).with_recipe(self, :over, [range], { around: around, width: width }.compact)
        end

        # The Weights at +position+ (see Harmony#at): itself, at any time.
        def at(_position = nil)
          self
        end

        # A note drawn from the classes by weight, as a pitch class 0..11
        # (or nil if every weight is 0).
        def draw(u)
          Dice.index(@pc, u)
        end

        def ==(other)
          other.is_a?(Weights) && other.pc == @pc
        end
        alias eql? ==

        def hash
          @pc.hash
        end

        # A one-line bar chart, e.g. "C▁ C#  D█ D#▁ ...".
        def to_s
          m = @pc.max
          @pc.each_with_index.map { |w, i| "#{NAMES[i]}#{m > 0 ? BARS[(w / m * 8).round] : ' '}" }.join(' ')
        end

        def inspect
          "#<Weights #{self}>"
        end

        # `weights(...)` with the twelve numbers (Values without a recipe).
        def plain_ruby(value_text)
          "weights(#{@pc.map { |w| value_text.call(w) }.join(', ')})"
        end

        protected

        def normalized_pc
          s = sum
          s > 0 ? @pc.map { |w| w / s } : @pc
        end
      end
    end
  end
end
