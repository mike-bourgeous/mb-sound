module MB
  module Sound
    module Generative
      # Melodies with phrase memory (MB::Sound#motifs): a few motifs, one per
      # letter of a phrase +form+ (a a b a), each a rhythm on a grid of
      # +steps+ and a contour in steps along the field's scale notes, so a
      # motif comes back recognizably and survives chord and key changes
      # (it is realized against the field where each note starts).  Letters
      # may answer others (+answer:+ { b: :a }: call and response); repeats
      # within a pass vary a little (+vary+); every +evolve+ passes of the
      # form the motifs mutate (+mutate+), so the tune grows slowly instead
      # of wandering.
      #
      # One phrase per cycle (a cycle is +steps+ * +step+ long), cycle n
      # playing letter form[n % form.length] in pass n / form.length, in
      # generation pass / evolve.  Everything is a pure function of the
      # seed and the cycle: any cycle is computed alone, at a bounded cost.
      #
      # Mutation, bounded (so cold jumps are cheap and the motif keeps its
      # identity): in each generation each slot of a motif (a grid step)
      # mutates with probability +mutate+, and a slot's state is set by its
      # latest mutation within the last MEMORY generations, relative to the
      # motif's first form (generation 0): back to the original, a neighbor
      # (one scale step up or down), a toggle (a note dropped, or a rest
      # filled with a passing note), or a new accent.  So a motif is never
      # more than one change per slot away from where it began, and
      # generation g costs one look back of at most MEMORY draws per slot
      # (two calls into C), whatever g is.
      #
      # Answers (b answering a): the call's rhythm, its first half's contour
      # kept and the rest mirrored, landing on the field's strongest note
      # nearest where the line would end (a chord tone or a weighted root),
      # held to the phrase's end; a call's last note moves off the
      # strongest notes (an open ending) where the field has some.
      # A phrase's first note is the strongest note nearest its target, and
      # blurred wrong notes (weight outside the field's scale notes) may
      # replace notes in the middle of a phrase, never its first or last.
      class Motifs
        # Generations a mutation is remembered (see the class comment).
        MEMORY = 32

        # Contour moves in scale steps between a motif's notes, by weight.
        MOVES = { 0 => 1.0, 1 => 3.0, -1 => 3.0, 2 => 1.0, -2 => 1.0, 3 => 0.4, -3 => 0.4 }.freeze

        # How far (scale steps) a motif's contour may wander from its first
        # note (moves past it turn back).
        SPAN = 6

        # Mutation kinds by weight.
        KINDS = { restore: 3.0, neighbor: 3.0, toggle: 1.5, accent: 1.0 }.freeze

        # A motif: per slot (grid step) whether a note starts there, its
        # contour (scale steps from the anchor, averaging about 0 in the
        # first form), and velocity; +anchor+ is the motif's offset (scale
        # steps) from the register's center (+around:+).
        Motif = Struct.new(:on, :contour, :velocity, :anchor)

        # The cycle length in whole notes (one phrase).
        attr_reader :length

        # The motif density a steered density thins and fills around (see
        # #steer_density).
        CORE_DENSITY = 0.5

        # +field+ is a Field or FieldTimeline; +around+ the note number the
        # motifs center on; +step+ a Rational; the rest as MB::Sound#motifs.
        # +fields+ (for a steered +range:+) gives [field, around] for a
        # range.  A steered +density+ (G3) builds motifs at CORE_DENSITY.
        def initialize(field, steps:, step:, form:, answer:, density:, vary:, mutate:, evolve:, leap:, around:, velocity:, legato:, seed:, fields: nil)
          @field = field
          @fields = fields
          @by_range = {}
          @steps = steps
          @step = step
          @length = step * steps
          @form = form
          @answer = answer
          @calls = answer.values.uniq.freeze
          @density = density.is_a?(Numeric) ? density.to_f : CORE_DENSITY
          @vary = vary.is_a?(Numeric) ? vary.to_f : 0.0
          @mutate = mutate.is_a?(Numeric) ? mutate.to_f : 0.0
          @evolve = evolve
          @moves = MOVES.select { |d, _| d.abs <= leap }
          @move_steps = @moves.keys.freeze
          @move_weights = @moves.values.freeze
          @around = around
          @velocity = velocity
          @legato = legato
          @seed = seed
          @kinds = KINDS.keys.freeze
          @kind_weights = KINDS.values.freeze
          @mutex = Mutex.new
          @bases = {}
          @motifs = {}
          @blocks = {}
          @tonal = {}.compare_by_identity
        end

        # The letter of +cycle+ (nil for a silent phrase), its pass of the
        # form, and the motif generation.
        def position(cycle)
          pass, pos = cycle.divmod(@form.length)
          [@form[pos], pass, pass.div(@evolve), pos]
        end

        # The events of +cycle+ with the cycle's +dice+ (Dice.new(seed,
        # cycle)).  Steered options (G3; MB::Sound#motifs) come decided for
        # the cycle: +density+ thins or fills the motifs' rhythms around
        # CORE_DENSITY (the same draws every cycle, so a density brings the
        # same notes back and raising it only adds notes), +vary+ and
        # +mutate+ replace the numbers, +range+ picks the register.
        def events(cycle, dice, density: nil, vary: @vary, mutate: @mutate, range: nil)
          letter, _pass, gen, pos = position(cycle)
          return [] unless letter

          field, around = range ? field_for(range) : [@field, @around]
          source = @answer[letter]
          m = motif(source || letter, gen, mutate.to_f.clamp(0.0, 1.0))
          m = steer_density(source || letter, m, density.to_f.clamp(0.0, 1.0)) if density
          notes = notes_of(m)
          notes = answer_of(notes) if source
          repeat = @form[0...pos].include?(letter)
          vary = vary.to_f.clamp(0.0, 1.0)
          notes = vary(notes, dice, vary) if repeat && vary > 0 && source.nil?
          realize(cycle, notes, m.anchor, answer: source ? true : false, call: @calls.include?(letter), dice: dice, field: field, around: around)
        end

        # Motif +m+ of +letter+ thinned or filled to +density+ (G3): below
        # CORE_DENSITY each note after the first stays with probability
        # density / CORE_DENSITY, above it each rest fills with a passing
        # note with probability (density - CORE_DENSITY) / (1 -
        # CORE_DENSITY), its contour on a run between its neighbors'.  The draws are
        # per letter and step, so the same density gives the same rhythm.
        def steer_density(letter, m, density)
          return m if density == CORE_DENSITY
          d = Dice.new(@seed, :density, letter)
          u = d.rands(@steps)
          on = m.on.dup
          contour = m.contour.dup
          if density < CORE_DENSITY
            keep = density / CORE_DENSITY
            (1...@steps).each { |s| (on[s] = false; contour[s] = nil) if on[s] && u[s] >= keep }
          else
            fill = (density - CORE_DENSITY) / (1 - CORE_DENSITY)
            filled = (1...@steps).select { |s| !on[s] && u[s] < fill }
            return m if filled.empty?
            filled.each { |s| on[s] = true }
            filled.each do |s|
              prev = (s - 1).downto(0).find { |k| m.on[k] && m.contour[k] }
              nxt = (s + 1...@steps).find { |k| m.on[k] && m.contour[k] }
              a = m.contour[prev]
              z = nxt ? m.contour[nxt] : a
              # A run between the neighbors (a turn when they are equal)
              contour[s] = a == z ? a + (d.rand(:dir, s) < 0.5 ? -1 : 1) : (a + (z - a) * Rational(s - prev, (nxt || @steps) - prev)).round
            end
          end
          Motif.new(on.freeze, contour.freeze, m.velocity, m.anchor).freeze
        end

        # Motif +letter+ in generation +gen+ (see the class comment), with
        # mutation chance +mutate+ (the motifs' own by default).
        def motif(letter, gen, mutate = @mutate)
          return base(letter) if gen < 1

          key = mutate == @mutate ? [letter, gen] : [letter, gen, mutate]
          hit = @mutex.synchronize { @motifs[key] }
          return hit if hit

          b = base(letter)
          on = b.on.dup
          contour = b.contour.dup
          vel = b.velocity.dup
          passing = []
          s = 1
          while s < @steps
            g = latest_mutation(letter, s, gen, mutate)
            if g
              d = Dice.new(@seed, :mutation, letter, s, g)
              case @kinds[Dice.index(@kind_weights, d.rand(:kind))]
              when :neighbor
                contour[s] += d.rand(:dir) < 0.5 ? -1 : 1 if on[s]
              when :toggle
                if on[s]
                  on[s] = false
                  contour[s] = nil
                else
                  on[s] = true
                  passing << [s, d.rand(:dir)]
                end
              when :accent
                vel[s] *= d.rand(:dir) < 0.5 ? 0.8 : 1.15
              end
            end
            s += 1
          end
          passing.each do |ps, u|
            prev = (ps - 1).downto(0).find { |k| on[k] && contour[k] }
            nxt = (ps + 1...@steps).find { |k| on[k] && contour[k] && passing.none? { |q, _| q == k } }
            a = contour[prev]
            z = nxt ? contour[nxt] : a
            contour[ps] = a == z ? a + (u < 0.5 ? -1 : 1) : ((a + z) / 2r).round
          end

          m = Motif.new(on.freeze, contour.freeze, vel.freeze, b.anchor).freeze
          @mutex.synchronize {
            @motifs.shift while @motifs.length >= 64
            @motifs[key] ||= m
          }
        end

        # The first form of motif +letter+ (generation 0).
        def base(letter)
          hit = @mutex.synchronize { @bases[letter] }
          return hit if hit

          d = Dice.new(@seed, :motif, letter)
          on = Array.new(@steps) { |s| s == 0 || d.rand(:on, s) < (@density * (s.even? ? 1.2 : 0.8)).clamp(0.0, 1.0) }
          contour = Array.new(@steps)
          c = 0
          seen = false
          @steps.times do |s|
            next unless on[s]
            if seen
              mv = @move_steps[Dice.index(@move_weights, d.rand(:move, s))]
              mv = -mv if (c + mv).abs > SPAN
              c += mv
            end
            seen = true
            contour[s] = c
          end
          # Centered: the motif's notes average out at its anchor
          used = contour.compact
          shift = (used.sum / used.length.to_r).round
          contour.map! { |x| x && x - shift }
          vel = Array.new(@steps) { |s| vel_at(d.rand(:vel, s)) }
          m = Motif.new(on.freeze, contour.freeze, vel.freeze, d.int(-1..1, :anchor)).freeze
          @mutex.synchronize { @bases[letter] ||= m }
        end

        private

        def vel_at(u)
          @velocity.is_a?(Range) ? @velocity.begin + (@velocity.end - @velocity.begin) * u : @velocity.to_f
        end

        # The latest generation in (gen - MEMORY, gen] (from 1) in which
        # slot +s+ of +letter+ mutated, or nil.  Draws come in blocks of 64
        # generations (one call into C each).
        def latest_mutation(letter, s, gen, mutate)
          lo = MB::M.max(gen - MEMORY + 1, 1)
          g = gen
          while g >= lo
            blk = g >> 6
            u = block(letter, s, blk)
            first = blk << 6
            i = g - first
            while i >= 0 && first + i >= lo
              return first + i if u[i] < mutate
              i -= 1
            end
            g = first - 1
          end
          nil
        end

        def block(letter, s, blk)
          key = [letter, s, blk]
          hit = @mutex.synchronize { @blocks[key] }
          return hit if hit
          u = Dice.new(@seed, :mutate, letter, s, blk).rands(64).freeze
          @mutex.synchronize {
            @blocks.shift while @blocks.length >= 1024
            @blocks[key] ||= u
          }
        end

        # [slot, contour, velocity, slots long] for each note of +m+.
        def notes_of(m)
          starts = (0...@steps).select { |s| m.on[s] }
          starts.each_with_index.map { |s, i|
            [s, m.contour[s], m.velocity[s], (starts[i + 1] || @steps) - s]
          }
        end

        # The answer to +notes+: the same rhythm, the first half's contour
        # kept and the rest mirrored around the last kept note, the last
        # note held to the phrase's end (landing home in #realize).
        def answer_of(notes)
          keep = (notes.length + 1) / 2
          pivot = notes[keep - 1][1]
          notes.each_with_index.map { |(s, c, v, len), i|
            c = 2 * pivot - c if i >= keep
            len = @steps - s if i == notes.length - 1
            [s, c, v * 0.95, len]
          }
        end

        # A repeat within a pass: middle notes now and then dropped or moved
        # a step (by +vary+, from the cycle's dice).
        def vary(notes, dice, amount)
          last = notes.length - 1
          notes.each_with_index.filter_map { |n, i|
            next n if i == 0 || i == last
            u = dice.rand(:vary, n[0])
            next n if u >= amount
            next nil if u < amount / 3
            [n[0], n[1] + (u < amount * 2 / 3 ? 1 : -1), n[2], n[3]]
          }.then { |list|
            # dropped notes: the note before holds through the gap
            list.each_with_index.map { |(s, c, v, _len), i| [s, c, v, (list[i + 1]&.first || @steps) - s] }
          }
        end

        # [field, around] for a steered +range+ (cached).
        def field_for(range)
          @mutex.synchronize { @by_range[range] } || begin
            pair = @fields.call(range).freeze
            @mutex.synchronize {
              @by_range.shift while @by_range.length >= 16
              @by_range[range] ||= pair
            }
          end
        end

        def realize(cycle, notes, anchor, answer:, call:, dice:, field: @field, around: @around)
          start = cycle * @length
          f0 = Generative.field_at(field, start)
          t0 = tonal(f0)
          return [] if t0.empty?
          center = t0[(nearest(t0, around) + anchor).clamp(0, t0.length - 1)]
          last = notes.length - 1

          notes.each_with_index.filter_map { |(s, c, v, len), i|
            f = Generative.field_at(field, start + @step * s)
            t = tonal(f)
            next nil if t.empty?
            target = t[(nearest(t, center) + c).clamp(0, t.length - 1)]
            note = if i == 0 || (answer && i == last)
                     f.home(target) || target
                   elsif i == last
                     call ? open(f, t, target) : target
                   else
                     blur(f, t, target, dice.rand(:blur, s))
                   end
            [@step * s, @step * len * @legato, note, v.clamp(0.0, 1.0)]
          }
        end

        # The index of the note of sorted +list+ nearest +n+ (the lower on a tie).
        def nearest(list, n)
          i = list.bsearch_index { |x| x >= n } || list.length - 1
          i > 0 && (n - list[i - 1]) <= (list[i] - n) ? i - 1 : i
        end

        # A call's last note: off the strongest notes, a scale step up (or
        # down at the top), when the field has stronger and weaker notes.
        def open(f, t, target)
          return target unless f.home(target) == target
          i = t.index(target)
          other = i && (t[i + 1] || (i > 0 ? t[i - 1] : nil))
          other && f[other] < f[target] * 0.999 ? other : target
        end

        # +target+, or a semitone neighbor outside the field's scale notes
        # drawn by weight (the target counted 3 times): blurred wrong notes
        # pass only where the field gives them weight.
        def blur(f, t, target, u)
          lo = target - 1
          hi = target + 1
          wl = t.include?(lo) ? 0.0 : f[lo]
          wh = t.include?(hi) ? 0.0 : f[hi]
          return target if wl == 0 && wh == 0
          case Dice.index([wl, f[target] * 3, wh], u)
          when 0 then lo
          when 2 then hi
          else target
          end
        end

        # The field's scale notes (Field#tonal), cached per Field.
        def tonal(f)
          @mutex.synchronize {
            @tonal.shift while @tonal.length >= 64
            @tonal[f] ||= f.tonal.freeze
          }
        end
      end
    end
  end
end
