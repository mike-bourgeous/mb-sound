module MB
  module Sound
    # Console and script methods for the generative layer (MB::Sound::Generative,
    # design/notes/generative.md): probability scales and generator clips.
    # Included in MB::Sound.  See also SequenceMethods#melody, which draws
    # from probability scales too.
    module GenerativeMethods
      # A chord layer: the pitch classes of +notes+ (Notes, note numbers,
      # or names) as Generative::Weights at +weight+ each.  Named chords
      # make the same layers: `chord(:min7, root: :d).weights` (see
      # SequenceMethods#chord and Generative::Chord).
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
      # keyframes at clip positions (lengths such as 12.bars or 3.beats; 0
      # for the start; other plain numbers raise) of Weights, Scales,
      # Chords, or Arrays of notes, blended between (+curve:+ :linear,
      # :step, or a Curve name), optionally looping (+loop:+ a length).
      #
      #     harmony(0 => scale(:dorian, :d), 12.bars => scale(:dorian, :d), 20.bars => scale(:major, :f))
      #     harmony(0 => [D3, F3, A3], 1.bar => [As2, D3, F3], loop: 2.bars, curve: :step)
      #     harmony(0 => chord(:min7, root: :d), 1.bar => chord(:dom7, root: :g), loop: 2.bars, curve: :step)
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

      # A melody with phrase memory (Generative::Motifs): one motif per
      # letter of +form+ (Symbols; nil for a silent phrase), each a rhythm
      # on +steps+ steps of +step+ (+density+ of them start notes, strong
      # steps more often) and a contour along the scale notes of +source+
      # (Weights, a Harmony, a Scale, a Chord, a Field, or Harmony#over),
      # realized where each note starts, so motifs come back through chord
      # and key changes.  One phrase per cycle: the clip loops every phrase
      # and plays the form's letters in turn.
      #
      # +answer:+ letters answering others (call and response: the call's
      # rhythm, its contour mirrored in the second half, landing home);
      # +vary:+ how much repeats within a pass change (0..1); +mutate:+ the
      # chance per step and generation that a motif changes there, every
      # +evolve:+ passes of the form (changes stay within one step of the
      # first motif, so the tune grows but keeps its face); +leap:+ the
      # largest contour move in scale steps.  +range:+ (C3..C5 by default)
      # bounds the notes, +around:+ (the middle by default) is where the
      # motifs sit, +width:+ an optional bell (semitones) favoring notes
      # near +around:+ for blurred wrong notes and the field's register.
      #
      #     h = scale(:dorian, :d).weights + chord(:min7, root: :d).weights * 1.5
      #     lead = motifs(h, 8, step: 1.n8, form: %i[a a b a], answer: { b: :a }, range: A3..A5, around: D4, seed: 3)
      #     bg :lead, ambient_koto_voice(lead)
      #     motifs(key.blur(0.1) + chords * 1.5, 16, step: 1.n16, form: [:a, :b, :a, nil], evolve: 1)
      def motifs(source, steps = 8, step: 1.n8, form: %i[a a b a], answer: { b: :a }, density: 0.5, vary: 0.2, mutate: 0.15,
                 evolve: 2, leap: 3, range: nil, around: nil, width: nil, velocity: 0.55..0.85, legato: 0.9, seed: nil, align: :timeline)
        raise ArgumentError, "motifs' steps is an Integer from 1 to 256 (got #{steps.inspect})" unless steps.is_a?(Integer) && steps.between?(1, 256)
        step = Generative.length_of(step, :step)
        unless form.is_a?(Array) && !form.empty? && form.length <= 64 && form.all? { |l| l.nil? || l.is_a?(Symbol) } && form.any?
          raise ArgumentError, "motifs' form is an Array of 1 to 64 letters (Symbols, nil for a silent phrase), like %i[a a b a] (got #{form.inspect})"
        end
        letters = form.compact.uniq
        raise ArgumentError, "motifs' answer: is a Hash of letter => the letter it answers, like { b: :a } (got #{answer.inspect})" unless answer.is_a?(Hash)
        answer = answer.select { |k, _| letters.include?(k) }
        answer.each do |k, v|
          raise ArgumentError, "motifs' answer: letters are Symbols (got #{k.inspect} => #{v.inspect})" unless k.is_a?(Symbol) && v.is_a?(Symbol)
          raise ArgumentError, "#{k.inspect} can't answer itself" if k == v
          raise ArgumentError, "#{k.inspect} answers #{v.inspect}, which answers #{answer[v].inspect}: answers answer motifs, not other answers" if answer.key?(v)
        end
        { density: density, vary: vary, mutate: mutate }.each do |name, x|
          raise ArgumentError, "motifs' #{name}: is from 0 to 1 (got #{x.inspect})" unless x.is_a?(Numeric) && x.real? && x.between?(0, 1)
        end
        raise ArgumentError, "motifs' evolve: is a whole number of passes from 1 (got #{evolve.inspect})" unless evolve.is_a?(Integer) && evolve >= 1
        raise ArgumentError, "motifs' leap: is 1, 2, or 3 scale steps (got #{leap.inspect})" unless leap.is_a?(Integer) && leap.between?(1, 3)
        raise ArgumentError, "motifs' legato: is from 0.05 to 1 (got #{legato.inspect})" unless legato.is_a?(Numeric) && legato.real? && legato.between?(0.05, 1)
        raise ArgumentError, "motifs' velocity: is from 0 to 1, or a Range (got #{velocity.inspect})" unless velocity.is_a?(Range) || (velocity.is_a?(Numeric) && velocity.between?(0, 1))

        field = Generative.motif_field(source, range: range, around: around, width: width)
        notes = Generative.notes_of(field)
        raise ArgumentError, "motifs' field has no notes" if notes.empty?
        center = around ? Scale.root_number(around) : (notes.first + notes.last) / 2r
        seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
        m = Generative::Motifs.new(field, steps: steps, step: step, form: form.dup.freeze, answer: answer.freeze, density: density, vary: vary,
          mutate: mutate, evolve: evolve, leap: leap, around: center, velocity: velocity, legato: legato.rationalize(1r / 1024), seed: seed)
        Sequence::Clip.generate(m.length, values: notes, seed: seed, name: "motifs(seed: #{seed})", align: align) { |cycle, dice| m.events(cycle, dice) }
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
