module MB
  module Sound
    module Generative
      # Counter-based dice: every draw is a pure function of a seed and a
      # path of keys (Integers, Symbols, Strings, Rationals, nil), with no
      # generator state, so draws don't depend on the order they're asked
      # for.  A generator's cycle 517 comes out the same computed cold (a
      # seek, a take replayed from the middle, a render that starts at hour
      # three) or after cycles 0..516.  See design/notes/generative.md.
      #
      # The hashing is splitmix64's finalizer over the seed, then over
      # (state ^ key) for each key in turn (FastGenerative, in C; an exact
      # Ruby mirror runs with Dice.mode = :ruby or MB_SOUND_DICE=ruby).
      # Symbols and Strings hash with FNV-1a, since Symbol#hash changes per
      # process.
      #
      # A Dice object is a seed with a key path: `dice[:kick]` is another
      # Dice one key further along (the same as Dice.new(seed, :kick)), and
      # its methods draw with more keys:
      #
      #     d = Dice.new(3)
      #     d.rand(:hit, 5)                  # a Float in 0...1
      #     d[:hit].rand(5) == d.rand(:hit, 5)
      #     d.chance(0.3, :ghost, 2)         # true 30% of the time
      #     d.int(1..6, :roll)               # an Integer in the range
      #     d.pick([C4, E4, G4], :note)      # one of them, evenly
      #     d.pick({ C4 => 3, E4 => 1 }, :n) # by weight
      #     d.pick(field, :note, i)          # a note of a Field, by weight
      #     d.smooth(t / 8.0, :drift)        # value noise: wanders slowly with t
      class Dice
        M64 = (1 << 64) - 1

        FNV_OFFSET = 0xcbf29ce484222325
        FNV_PRIME = 0x100000001b3

        MODES = [:c, :ruby].freeze

        @mode = ENV['MB_SOUND_DICE'] == 'ruby' ? :ruby : :c

        class << self
          # :c (FastGenerative, the default) or :ruby (the exact mirror).
          attr_reader :mode

          def mode=(mode)
            raise ArgumentError, "Dice.mode is one of #{MODES.map(&:inspect).join(', ')} (got #{mode.inspect})" unless MODES.include?(mode)
            @mode = mode
          end

          # The state for +seed+ (an Integer): mix(seed's low 64 bits).
          def start(seed)
            @mode == :c ? FastGenerative.start(seed) : start_ruby(seed)
          end

          # The 64-bit key of +k+.
          def key(k)
            @mode == :c ? FastGenerative.key(k) : key_ruby(k)
          end

          # The state after folding +keys+ into +state+.
          def fold(state, *keys)
            @mode == :c ? FastGenerative.fold(state, *keys) : fold_ruby(state, *keys)
          end

          # A Float in 0...1 from +state+ and +keys+.
          def unit(state, *keys)
            @mode == :c ? FastGenerative.rand(state, *keys) : unit_ruby(state, *keys)
          end

          # unit(state, i) for i in 0...count, as an Array.
          def units(state, count)
            @mode == :c ? FastGenerative.rands(state, count) : units_ruby(state, count)
          end

          # The index where +u+ (0...1) times the sum of +weights+ (an
          # Array of Floats) falls, or nil when nothing can be picked
          # (no positive weight, or rounding at the very end).
          def index(weights, u)
            i = @mode == :c ? FastGenerative.pick(weights, u) : pick_ruby(weights, u)
            i < 0 ? nil : i
          end

          # The Ruby mirror of FastGenerative (see there for the rules).
          def mix(z)
            z = (z + 0x9E3779B97F4A7C15) & M64
            z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
            z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
            z ^ (z >> 31)
          end

          def start_ruby(seed)
            raise TypeError, "A dice seed is an Integer (got #{seed.inspect})" unless seed.is_a?(Integer)
            mix(seed & M64)
          end

          def key_ruby(k)
            case k
            when Integer then k & M64
            when Symbol, String then fnv(k.to_s)
            when Rational then mix(key_ruby(k.numerator)) ^ key_ruby(k.denominator)
            when nil then 0
            else raise ArgumentError, "Dice keys are Integers, Symbols, Strings, Rationals, or nil (got #{k.inspect})"
            end
          end

          def fnv(str)
            str.each_byte.reduce(FNV_OFFSET) { |h, b| ((h ^ b) * FNV_PRIME) & M64 }
          end

          def fold_ruby(state, *keys)
            raise TypeError, "A dice state is an Integer (got #{state.inspect})" unless state.is_a?(Integer)
            keys.reduce(state & M64) { |h, k| mix(h ^ key_ruby(k)) }
          end

          def unit_ruby(state, *keys)
            (fold_ruby(state, *keys) >> 11) * (1.0 / (1 << 53))
          end

          def units_ruby(state, count)
            raise ArgumentError, "Dice count can't be negative (got #{count})" if count < 0
            Array.new(count) { |i| unit_ruby(state, i) }
          end

          # Array#sum's compensated sum, then the first index whose running
          # sum passes u * total (-1 for none).
          def pick_ruby(weights, u)
            total = weights.sum(0.0)
            return -1 unless total > 0 && total.finite?
            x = u.to_f * total
            weights.each_with_index { |w, i| return i if (x -= w.to_f) < 0 }
            -1
          end
        end

        # The seed (an Integer).
        attr_reader :seed

        # The keys after the seed (an Array).
        attr_reader :path

        # The folded state (an Integer 0...2**64).
        attr_reader :state

        def initialize(seed, *keys)
          @seed = Integer(seed)
          @path = keys.freeze
          @state = Dice.fold(Dice.start(@seed), *keys)
          freeze
        end

        # The Dice +keys+ further along this one's path.
        def [](*keys)
          Dice.allocate.tap { |d| d.send(:branch, self, keys) }
        end

        # A Float in 0...1.
        def rand(*keys)
          Dice.unit(@state, *keys)
        end

        # rand(i) for i in 0...count (an Array, from one call into C).
        def rands(count)
          Dice.units(@state, count)
        end

        # True with probability +p+ (0..1).
        def chance(p, *keys)
          rand(*keys) < p
        end
        alias chance? chance

        # An Integer in +range+ (an Integer Range), evenly.
        def int(range, *keys)
          lo = range.begin
          n = range.end - lo + (range.exclude_end? ? 0 : 1)
          raise ArgumentError, "Dice#int needs a non-empty Integer range (got #{range})" unless lo.is_a?(Integer) && n > 0
          lo + (rand(*keys) * n).floor
        end

        # One of +choices+: an Array (evenly), a Hash of choice => weight,
        # or anything with #draw(u) (a Field or Weights: a note by weight).
        def pick(choices, *keys)
          u = rand(*keys)
          case choices
          when Array
            raise ArgumentError, 'Nothing to pick from an empty Array' if choices.empty?
            choices[(u * choices.length).floor]
          when Hash
            i = Dice.index(choices.values.map(&:to_f), u) || last_positive(choices.values)
            raise ArgumentError, 'Nothing to pick: every weight is zero' if i.nil?
            choices.keys[i]
          else
            choices.draw(u)
          end
        end

        # Smooth value noise in 0..1 at +t+ (any real number): random
        # values at whole numbers joined by a smoothstep, so it wanders
        # slowly as +t+ moves (drifting probabilities, slow mutations).
        def smooth(t, *keys)
          i = t.floor
          f = (t - i).to_f
          a = rand(*keys, i)
          b = rand(*keys, i + 1)
          f = f * f * (3 - 2 * f)
          a + (b - a) * f
        end

        # +list+ in an order drawn from these dice (Fisher-Yates, one draw
        # per element).
        def shuffle(list, *keys)
          d = self[*keys, :shuffle]
          out = list.to_a.dup
          (out.length - 1).downto(1) do |i|
            j = (d.rand(i) * (i + 1)).floor
            out[i], out[j] = out[j], out[i]
          end
          out
        end

        def ==(other)
          other.is_a?(Dice) && other.state == @state
        end
        alias eql? ==

        def hash
          @state.hash
        end

        def to_s
          "Dice(#{[@seed, *@path.map(&:inspect)].join(', ')})"
        end

        def inspect
          "#<#{self}>"
        end

        private

        def branch(parent, keys)
          @seed = parent.seed
          @path = (parent.path + keys).freeze
          @state = Dice.fold(parent.state, *keys)
          freeze
        end

        def last_positive(weights)
          weights.rindex { |w| w.to_f > 0 }
        end
      end
    end
  end
end
