module MB
  module Sound
    # Console and script methods for the generative layer (MB::Sound::Generative,
    # design/notes/generative.md): probability scales and generator clips.
    # Included in MB::Sound.  See also SequenceMethods#melody, which draws
    # from probability scales too.
    module GenerativeMethods
      # A chord layer: the pitch classes of +notes+ (Notes, note numbers,
      # or names) as Generative::Weights at +weight+ each.
      #
      #     scale(:dorian, :d).weights.blur(0.1) + tones(D3, F3, A3, C4) * 1.2
      #     tones(*scale(:minor, :a).chord(0))   # the A minor triad
      def tones(*notes, weight: 1.0)
        Generative::Weights.tones(*notes, weight: weight)
      end

      # A probability scale from twelve weights, C first (see
      # Generative::Weights):
      #
      #     weights(4, 0, 1, 0, 2, 1, 0, 3, 0, 1, 0, 1)
      def weights(*pc)
        Generative::Weights[*pc]
      end

      # Probability scales that change over time (Generative::Harmony):
      # keyframes at clip positions (Durations, or numbers of bars from 0)
      # of Weights, Scales, or Arrays of notes, blended between (+curve:+
      # :linear, :step, or a Curve name), optionally looping.
      #
      #     harmony(0 => scale(:dorian, :d), 12.bars => scale(:dorian, :d), 20.bars => scale(:major, :f))
      #     harmony(0 => [D3, F3, A3], 1.bar => [As2, D3, F3], loop: 2.bars, curve: :step)
      def harmony(keyframes = nil, curve: :linear, loop: nil, **positions)
        # harmony(0 => a, 12.bars => b) passes the keyframes as keywords
        # (non-Symbol keys); harmony({ ... }) as a Hash
        keyframes = keyframes ? keyframes.merge(positions) : positions
        bad = keyframes.keys.grep(Symbol)
        raise ArgumentError, "harmony's keys are positions (0, 12.bars), not names (got #{bad.map(&:inspect).join(', ')})" unless bad.empty?
        Generative::Harmony.new(keyframes, curve: curve, loop: loop).with_recipe(nil, :harmony, [keyframes], { curve: curve == :linear ? nil : curve, loop: loop }.compact)
      end

      # Counter-based dice for +seed+ and optional keys (Generative::Dice):
      # every draw is a pure function of the seed and its keys.
      #
      #     d = dice(3)
      #     d.rand(:kick, 5)        # the same Float every time
      def dice(seed = nil, *keys)
        Generative::Dice.new(seed.nil? ? MB::Sound.next_seed : seed, *keys)
      end

      # A generator clip (Sequence::Clip.generate): a loop of +length+ (a
      # Duration such as 2.bars, or Rational whole notes) whose events for
      # each cycle come from the block, called with the cycle number and
      # Dice for that cycle.  See Sequence::Clip.generate.
      #
      #     arp = generate(1.bar, values: scale(:minor, :a).notes(A3..A5)) { |cycle, dice|
      #       Array.new(8) { |i| [i * 1r/8, 1r/16, dice.pick(scale(:minor, :a).notes(A3..A5), :n, i), 0.7] }
      #     }
      def generate(length, values: nil, seed: nil, name: nil, align: :timeline, reach: nil, &block)
        Sequence::Clip.generate(length, values: values, seed: seed, name: name, align: align, reach: reach, &block)
      end

      # Sparse generated hits (Generative::Strikes): on each step of
      # +every+, a strike with probability +chance+ (a number, or a lambda
      # of the cycle), none within +gap+ steps after another candidate, its
      # note drawn from +field+ (a Field, Harmony#over, Weights, Harmony,
      # or Scale) and sharpened by +sharpen+.  A looping clip of +length+
      # per cycle; notes last +note+ (one step by default).
      #
      #     bowls = strikes(harmony.over(A2..A4, around: D3), every: 1.n4, chance: 0.2, gap: 3, seed: 2)
      #     bg :bowls, bowls.synth(voices: 4) { |v| v.hz.sine * v.env(0.005, 4, 0, 4) }
      def strikes(field, every: 1.n4, length: 1.bar, chance: 0.25, gap: 2, sharpen: 2, velocity: 0.5..0.9, note: nil, seed: nil, align: :timeline)
        every = Generative.length_of(every, :every)
        length = Generative.length_of(length, :length)
        note = note ? Generative.length_of(note, :note) : every
        raise ArgumentError, "strikes' chance is from 0 to 1, or a lambda of the cycle (got #{chance.inspect})" unless chance.respond_to?(:call) || (chance.is_a?(Numeric) && chance.between?(0, 1))
        raise ArgumentError, "strikes' gap is an Integer number of steps from 1 to 64 (got #{gap.inspect})" unless gap.is_a?(Integer) && gap.between?(1, 64)
        raise ArgumentError, "strikes' sharpen is a positive number (got #{sharpen.inspect})" unless sharpen.is_a?(Numeric) && sharpen > 0

        seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
        source = Generative.field(field)
        s = Generative::Strikes.new(source, every: every, length: length, chance: chance, gap: gap, sharpen: sharpen,
          velocity: velocity, note_length: note, seed: seed)
        Sequence::Clip.generate(length, values: Generative.notes_of(source), seed: seed, name: "strikes(seed: #{seed})", align: align,
          reach: MB::M.max(length * 2, length + note)) { |cycle, dice| s.events(cycle, dice) }
      end
    end
  end
end
