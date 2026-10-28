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
      #
      # Other keywords are options the block reads as keywords, decided
      # once per cycle at the cycle's decision point, +lead:+ (one beat by
      # default) before it starts: knobs steer the generator live, and
      # takes and renders replay the same decisions (G3; Generative::Steer).
      #
      #     knob :busy, 0.3
      #     hats = generate(1.bar, busy: knob(:busy), values: [F2s]) { |cycle, dice, busy:|
      #       16.times.filter_map { |i| [i * 1r/16, 1r/32, F2s, 0.6] if dice.rand(:hat, i) < busy }
      #     }
      #     turn :busy, 0.9, over: 8     # the hats fill in over 8 bars, a cycle at a time
      def generate(length, values: nil, seed: nil, name: nil, align: :timeline, reach: nil, lead: nil, **params, &block)
        raise ArgumentError, 'generate needs a block: { |cycle, dice| rows }' unless block
        Generative.check_block_keywords(block, params, %i[values seed name align reach lead], 'generate')
        Sequence::Clip.generate(length, values: values, seed: seed, name: name, align: align, reach: reach, lead: lead, params: params, &block)
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
      #
      # Steering (G3): +density:+, +vary:+, and +mutate:+ may be knobs or
      # other params, and +range:+ a choice of ranges
      # (`knob(:reg).choose(A2..A4, A3..A5)`), read once per phrase at its
      # decision point, +lead:+ (one beat) before it (Generative::Steer).
      # A steered density thins or fills the motifs around 0.5 (the same
      # notes come back at the same density; raising it only adds notes);
      # a steered mutate is how far the motifs have wandered from their
      # first form.
      #
      #     knob :busy, 0.5
      #     knob :wander, 0.1
      #     lead = motifs(h, 8, density: knob(:busy), mutate: knob(:wander), evolve: 1)
      #     turn :busy, 0.9, over: 8
      def motifs(source, steps = 8, step: 1.n8, form: %i[a a b a], answer: { b: :a }, density: 0.5, vary: 0.2, mutate: 0.15,
                 evolve: 2, leap: 3, range: nil, around: nil, width: nil, velocity: 0.55..0.85, legato: 0.9, seed: nil, align: :timeline, lead: nil)
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
          raise ArgumentError, "#{k.inspect} answers #{v.inspect}, which answers #{answer[v].inspect}: answers answer motifs (an answer to an answer is not supported)" if answer.key?(v)
        end
        { density: density, vary: vary, mutate: mutate }.each do |name, x|
          next if MIDI::Param.param?(x)
          raise ArgumentError, "motifs' #{name}: is from 0 to 1, or a knob or other param (got #{x.inspect})" unless x.is_a?(Numeric) && x.real? && x.between?(0, 1)
        end
        ranges = Generative.steered_ranges(range, 'motifs')
        raise ArgumentError, "motifs' evolve: is a whole number of passes from 1 (got #{evolve.inspect})" unless evolve.is_a?(Integer) && evolve >= 1
        raise ArgumentError, "motifs' leap: is 1, 2, or 3 scale steps (got #{leap.inspect})" unless leap.is_a?(Integer) && leap.between?(1, 3)
        raise ArgumentError, "motifs' legato: is from 0.05 to 1 (got #{legato.inspect})" unless legato.is_a?(Numeric) && legato.real? && legato.between?(0.05, 1)
        raise ArgumentError, "motifs' velocity: is from 0 to 1, or a Range (got #{velocity.inspect})" unless velocity.is_a?(Range) || (velocity.is_a?(Numeric) && velocity.between?(0, 1))

        fields = ->(r) {
          f = Generative.motif_field(source, range: r, around: ranges ? nil : around, width: width)
          n = Generative.notes_of(f)
          raise ArgumentError, "motifs' field has no notes#{r ? " in #{r}" : ''}" if n.empty?
          [f, ranges || around.nil? ? (n.first + n.last) / 2r : Scale.root_number(around), n]
        }
        field, center, notes = fields.(ranges ? ranges.first : range)
        notes = ranges.flat_map { |r| fields.(r)[2] }.uniq.sort if ranges
        seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
        m = Generative::Motifs.new(field, steps: steps, step: step, form: form.dup.freeze, answer: answer.freeze, density: density, vary: vary,
          mutate: mutate, evolve: evolve, leap: leap, around: center, velocity: velocity, legato: legato.rationalize(1r / 1024), seed: seed,
          fields: ranges && ->(r) { fields.(r).first(2) })
        params = { density: density, vary: vary, mutate: mutate, range: (range if ranges) }.select { |_, v| MIDI::Param.param?(v) }
        unless params.empty?
          return Sequence::Clip.generate(m.length, values: notes, seed: seed, name: "motifs(seed: #{seed})", align: align, lead: lead, params: params) { |cycle, dice, **v|
            m.events(cycle, dice, **v)
          }
        end
        Sequence::Clip.generate(m.length, values: notes, seed: seed, name: "motifs(seed: #{seed})", align: align) { |cycle, dice| m.events(cycle, dice) }
      end

      # An evolving rhythm (Generative::Beats; G3): a generator clip of
      # rows of per-step hit probabilities, played by any drum kit
      # (`tr909(groove)`, `tr808`, kit-builder kits; Clip#values lists the
      # rows' notes) or, for rows with +notes:+, any synth.  In the block,
      # each row is a method named after a drum (`kick`, `snare`, `clap`,
      # `hat`, `open_hat`, `ride`, `cowbell`, `rim`, `low_tom`, ...; typos
      # raise with did-you-mean) taking a pattern (an Array of
      # probabilities, or `euclid(hits, steps)`) and options: +keep:+ steps
      # that never drift (anchors), +drift:+ how far the other steps'
      # probabilities wander (smoothly, over +over:+ hold blocks),
      # +mutate:+ how much a Euclidean row's hit count and rotation change,
      # +level:+, +energy: false+ (ignore the energy), +length:+ (steps).
      # `row :name, pattern, note: C2` or `notes: field` names other rows
      # (melodic rows walk the field's scale notes).  `fill every: 8,
      # snare: 0.7, low_tom: 0.3` raises those rows in the last beat of
      # every 8th cycle (`last:` a length).
      #
      # +energy+ (0..1; a number, a lambda of the cycle, or a knob) thins
      # below 0.5 and fills above it; draws are fixed per +hold+ block, so
      # raising the energy only adds hits and `hold: 2` plays each random
      # bar twice.  +groove+ is the velocity per step (an Array, cycled, or
      # a lambda of the step's 0...1 position), +swing+ (0.5 straight to
      # 0.75) delays odd steps, +humanize+ varies velocities.  A knob for
      # +energy+ or +swing+ is read once per cycle at its decision point,
      # +lead:+ (one beat) before it (Generative::Steer).
      #
      #     knob :energy, 0.4
      #     groove = beats(16, hold: 2, swing: 0.54, energy: knob(:energy), seed: 5) do
      #       kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12]
      #       clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12], level: 0.9
      #       hat euclid(10, 16), mutate: 0.5, drift: 0.15, level: 0.75
      #       snare [0, 0, 0, 0.1] * 4, drift: 0.2, level: 0.55
      #       fill every: 8, snare: 0.7, low_tom: 0.3
      #     end
      #     bg :drums, tr909(groove)
      #     turn :energy, 0.9, over: 8     # a build, a cycle at a time
      def beats(steps = 16, step: 1.n16, hold: 1, over: 8, energy: 0.5, swing: 0.5, groove: Generative::Beats::GROOVE, humanize: 0.08,
                seed: nil, align: :timeline, lead: nil, &block)
        raise ArgumentError, 'beats needs a block of rows: beats(16) { kick [1, 0, 0, 0] * 4 }' unless block
        raise ArgumentError, "beats' steps is an Integer from 1 to 256 (got #{steps.inspect})" unless steps.is_a?(Integer) && steps.between?(1, 256)
        step = Generative.length_of(step, :step)
        raise ArgumentError, "beats' hold: is a whole number of cycles from 1 (got #{hold.inspect})" unless hold.is_a?(Integer) && hold >= 1
        raise ArgumentError, "beats' over: is a whole number of hold blocks from 1 (got #{over.inspect})" unless over.is_a?(Integer) && over >= 1
        unless energy.respond_to?(:call) || MIDI::Param.param?(energy) || (energy.is_a?(Numeric) && energy.between?(0, 1))
          raise ArgumentError, "beats' energy: is from 0 to 1, a knob or other param, or a lambda of the cycle (got #{energy.inspect})"
        end
        unless swing.respond_to?(:call) || MIDI::Param.param?(swing) || (swing.is_a?(Numeric) && swing.between?(0.5, 0.75))
          raise ArgumentError, "beats' swing: is from 0.5 (straight) to 0.75, or a knob or other param (got #{swing.inspect})"
        end
        raise ArgumentError, "beats' groove: is an Array of velocities or a lambda of the step's position (got #{groove.inspect})" unless groove.respond_to?(:call) || (groove.is_a?(Array) && !groove.empty?)
        raise ArgumentError, "beats' humanize: is from 0 to 1 (got #{humanize.inspect})" unless humanize.is_a?(Numeric) && humanize.between?(0, 1)

        builder = Generative::Beats::Builder.new(steps, step * steps)
        builder.instance_exec(&block)
        rows, fill = builder.__result
        raise ArgumentError, 'beats needs at least one row' if rows.empty? && fill.nil?
        if fill
          fill.rows.each_key do |name|
            next if rows.any? { |r| r.name == name }
            # A drum only in fills
            builder.row(name, [0], energy: false)
            rows = builder.__result[0]
          end
        end
        seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
        b = Generative::Beats.new(rows, steps: steps, step: step, hold: hold, over: over, energy: energy, swing: swing, groove: groove,
          humanize: humanize, fill: fill, seed: seed)
        reach = MB::M.max(b.length * 2, step * (steps + rows.map(&:length).max.ceil))
        params = { energy: energy, swing: swing }.select { |_, v| !v.respond_to?(:call) && MIDI::Param.param?(v) }
        unless params.empty?
          return Sequence::Clip.generate(b.length, values: b.values, seed: seed, name: "beats(seed: #{seed})", align: align, reach: reach,
            lead: lead, params: params) { |cycle, dice, **v| b.events(cycle, dice, **v) }
        end
        Sequence::Clip.generate(b.length, values: b.values, seed: seed, name: "beats(seed: #{seed})", align: align, reach: reach) { |cycle, dice|
          b.events(cycle, dice)
        }
      end

      # An evolving rhythm for a melodic line (#beats with one row of
      # +notes+): +pattern+ is the per-step hit probability (an Array; for
      # Euclidean lines write `beats { row :line, euclid(5, 16), notes: h }`),
      # the notes a walk of the scale notes of
      # +source+ (Weights, a Harmony, a Scale, a Field, or Harmony#over)
      # where each hit starts; the other options as #beats.
      #
      #     bass = rhythm(h.over(D2..D3), [1, 0, 0.3, 0.6] * 4, energy: knob(:energy), hold: 2, length: 2)
      #     bg :bass, bass.synth { |v| v.hz.saw.lp4(600) * v.env(0.005, 0.2, 0.3, 0.1) }
      def rhythm(source, pattern = [1, 0, 0.4, 0] * 4, steps: nil, length: 1, drift: 0.15, keep: [0], level: 0.9, **options)
        steps ||= pattern.length
        beats(steps, **options) { row :line, pattern, notes: source, keep: keep, drift: drift, level: level, length: length }
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
      #
      # A moving +chance+ (`knob(:rain)`, `cc(1)`, a tempo LFO) is read once
      # per cycle at its decision point, +lead:+ (one beat, or the cycle if
      # shorter) before the cycle (G3; Generative::Steer).
      def strikes(field, every: 1.n4, length: 1.bar, chance: 0.25, gap: 2, sharpen: 2, velocity: 0.5..0.9, note: nil, seed: nil, align: :timeline, lead: nil)
        every = Generative.length_of(every, :every)
        length = Generative.length_of(length, :length)
        note = note ? Generative.length_of(note, :note) : every
        moving = !chance.respond_to?(:call) && MIDI::Param.param?(chance)
        raise ArgumentError, "strikes' chance is from 0 to 1, a knob or other param, or a lambda of the cycle (got #{chance.inspect})" unless moving || chance.respond_to?(:call) || (chance.is_a?(Numeric) && chance.between?(0, 1))
        raise ArgumentError, "strikes' gap is an Integer number of steps from 1 to 64 (got #{gap.inspect})" unless gap.is_a?(Integer) && gap.between?(1, 64)
        raise ArgumentError, "strikes' sharpen is a positive number (got #{sharpen.inspect})" unless sharpen.is_a?(Numeric) && sharpen > 0

        seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
        source = Generative.field(field)
        s = Generative::Strikes.new(source, every: every, length: length, chance: chance, gap: gap, sharpen: sharpen,
          velocity: velocity, note_length: note, seed: seed)
        if moving
          return Sequence::Clip.generate(length, values: Generative.notes_of(source), seed: seed, name: "strikes(seed: #{seed})", align: align,
            reach: MB::M.max(length * 2, length + note), lead: lead, params: { chance: chance }) { |cycle, dice, **v| s.events(cycle, dice, **v) }
        end
        Sequence::Clip.generate(length, values: Generative.notes_of(source), seed: seed, name: "strikes(seed: #{seed})", align: align,
          reach: MB::M.max(length * 2, length + note)) { |cycle, dice| s.events(cycle, dice) }
      end
    end
  end
end
