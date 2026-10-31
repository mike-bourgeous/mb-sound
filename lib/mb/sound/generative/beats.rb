module MB
  module Sound
    module Generative
      # Evolving rhythms (MB::Sound#beats, #rhythm; G3, from the research
      # spike's prototype b_rhythm.rb): rows of per-step hit probabilities
      # (drum voices, or melodic lines drawing notes from a field) that
      # drift slowly, mutate (Euclidean rows change their hit count and
      # rotation), thin and fill with an +energy+ (a number or a knob), hold
      # each random bar for +hold+ cycles, take groove velocities and swing,
      # and fill at phrase ends.
      #
      # Everything is counter-based (Dice): a cycle is a pure function of
      # the seed, the cycle, and the decided energy and swing, so any cycle
      # comes out the same computed cold or in order.  Hit draws are fixed
      # per hold block and step, so raising the energy only adds hits (the
      # pattern grows instead of reshuffling) and lowering it removes them
      # in reverse.
      class Beats
        # Velocity per step by default: strong beats, offbeats, the rest.
        GROOVE = [1.0, 0.55, 0.75, 0.6].freeze

        # Contour moves of melodic rows (scale steps => weight).
        MOVES = { 0 => 1.0, 1 => 3.0, -1 => 3.0, 2 => 1.0, -2 => 1.0 }.freeze

        # A row: +name+ (a Symbol), the drum +note+ it plays or a +field+
        # its notes come from, the per-step +pattern+ (probabilities) or a
        # +euclid+ [hits, steps, rotate], the +keep+ steps (anchors that
        # never drift), +drift+ (how far probabilities wander, 0..1),
        # +mutate+ (Euclidean rows: how much the hit count and rotation
        # change), +level+ (velocity scale), +energy+ (false: the row
        # ignores the energy), +length+ (notes, in steps).
        Row = Data.define(:name, :note, :field, :pattern, :euclid, :keep, :drift, :mutate, :level, :energy, :length)

        # A phrase fill: in the last cycle of every +every+ cycles, steps
        # from +from+ on add +rows+' probabilities (name => amount).  With
        # +energy+ true the fill follows the energy (#fill_span).
        Fill = Data.define(:every, :from, :rows, :energy)

        # A Euclidean row's pattern (see Builder#euclid).
        Euclid = Data.define(:hits, :steps, :rotate)

        attr_reader :rows, :steps, :step, :length, :fill

        # +rows+ are Rows; the options as MB::Sound#beats.
        def initialize(rows, steps:, step:, hold:, over:, energy:, swing:, groove:, humanize:, fill:, seed:)
          @rows = rows.freeze
          @steps = steps
          @step = step
          @length = step * steps
          @hold = hold
          @over = over
          @energy = energy
          @swing = swing
          @groove = groove
          @humanize = humanize.to_f
          @fill = fill
          @seed = seed
          @keys = rows.to_h { |r| [r.name, r.keep.to_h { |s| [s, true] }.freeze] }.freeze
          @tonal = {}.compare_by_identity
          @mutex = Mutex.new
        end

        # The notes the rows may play (drum notes, and melodic rows' field notes).
        def values
          @rows.flat_map { |r| r.note ? [r.note] : Generative.notes_of(r.field) }.uniq
        end

        # The probabilities of row +r+ in +cycle+ at energy +e+ (after
        # drift, mutation, energy, and fills).
        def probabilities(r, cycle, e)
          block = cycle.div(@hold)
          base = r.euclid ? euclid_pattern(r, block) : r.pattern
          keep = @keys[r.name]
          t = Rational(block, @over)
          d = Dice.new(@seed, :drift, r.name)
          add, from = fill_amount(r, cycle, e)
          Array.new(@steps) { |s|
            p = base[s % base.length].to_f
            anchored = keep[s]
            p = (p + r.drift * (d.smooth(t, s) * 2 - 1)).clamp(0.0, 1.0) if r.drift > 0 && !anchored
            p = Beats.energize(p, e) unless r.energy == false || (anchored && e > 0)
            p = (p + add).clamp(0.0, 1.0) if add && s >= from
            p
          }
        end

        # Energy 0.5 leaves a probability as it is; below, it scales down
        # toward 0 (certain hits too: a breakdown thins the hats); above, it
        # fills toward 1 (1 - (1 - p)^(2e): rare hits become likely first).
        def self.energize(p, e)
          e < 0.5 ? p * 2 * e : 1 - (1 - p)**(2 * e)
        end

        # The events of +cycle+ with its +dice+; +energy+ and +swing+ come
        # decided for the cycle when they are steered (Steer).
        def events(cycle, dice, energy: @energy, swing: @swing)
          e = (energy.respond_to?(:call) ? energy.call(cycle) : energy).to_f.clamp(0.0, 1.0)
          swing = (swing.respond_to?(:call) ? swing.call(cycle) : swing).to_f.clamp(0.5, 0.75)
          block = cycle.div(@hold)
          late = (swing - 0.5) * 2 * @step
          late = late.rationalize(1r / 3840) if late.is_a?(Float)
          out = []
          @rows.each do |r|
            probs = probabilities(r, cycle, e)
            u = Dice.new(@seed, :hit, r.name, block).rands(@steps)
            prev = nil
            walk = r.field && Dice.new(@seed, :line, r.name, block) # (held with the hits)
            @steps.times do |s|
              next unless u[s] < probs[s]
              v = groove_at(s) * r.level * (1 + @humanize * (2 * dice.rand(:vel, r.name, s) - 1))
              start = @step * s + (s.odd? ? late : 0)
              note = r.note || (prev = line_note(r, cycle, s, prev, walk))
              next unless note
              out << [start, @step * r.length, note, v.clamp(0.0, 1.0)]
            end
          end
          out
        end

        # A one-line text score of +cycle+ per row ('X' strong, 'x' soft,
        # '.' rest), for listings and tests.
        def score(cycle, energy: @energy, swing: @swing)
          list = events(cycle, Dice.new(@seed, cycle), energy: energy, swing: swing)
          @rows.map { |r|
            hits = list.select { |ev| r.note ? ev[2] == r.note : true }
            line = (0...@steps).map { |s|
              h = hits.find { |ev| (ev[0] / @step).floor == s }
              h ? (h[3] > 0.8 ? 'X' : 'x') : '.'
            }.join
            "#{r.name.to_s.ljust(10)} #{line}"
          }.join("\n")
        end

        private

        def groove_at(s)
          g = @groove
          g.respond_to?(:call) ? g.call(Rational(s, @steps)).to_f : g[s % g.length].to_f
        end

        # The added probability of row +r+ in +cycle+'s fill at energy +e+
        # and the step the fill starts on, or nil.
        def fill_amount(r, cycle, e)
          f = @fill
          return nil unless f && (cycle + 1) % f.every == 0
          a = f.rows[r.name]
          return nil unless a
          return [a, f.from] unless f.energy
          a = Beats.energize(a, e)
          a > 0 ? [a, @steps - Beats.fill_span(@steps - f.from, e, @steps)] : nil
        end

        # The steps a fill written over +span+ steps covers at energy +e+
        # when it follows the energy (`fill every: 8, energy: true`): as
        # written at 0.5, twice as long at 1, half at 0 (where its amounts,
        # energized like the rows', reach 0), at most +steps+.
        def self.fill_span(span, e, steps)
          (span * 2.0**(2 * e - 1)).round.clamp(1, steps)
        end

        # A Euclidean row's pattern for hold block +block+: the hit count
        # wanders by up to mutate * steps / 2 on smooth noise over +over+
        # blocks, and the rotation changes with probability +mutate+.
        def euclid_pattern(r, block)
          ec = r.euclid
          n = ec.steps
          hits = ec.hits
          rot = ec.rotate
          if r.mutate > 0
            d = Dice.new(@seed, :euclid, r.name)
            hits += ((d.smooth(Rational(block, @over), :hits) * 2 - 1) * r.mutate * n * 0.5).round
            rot = d.int(0...n, :rotate, block) if d.rand(:turn, block) < r.mutate
          end
          Sequence::Generators.euclid_pattern(hits.clamp(0, n), n, rotate: rot).map { |x| x ? 1.0 : 0.0 }
        end

        # A melodic row's note at step +s+: the field's strongest note near
        # its middle for the cycle's first hit, else a walk of scale steps
        # (mostly steps, some repeats and skips) from the previous hit,
        # drawn from +dice+ of the hold block (a held bar repeats its line).
        def line_note(r, cycle, s, prev, dice)
          f = Generative.field_at(r.field, cycle * @length + @step * s)
          t = tonal(f)
          return nil if t.empty?
          return f.home((t.first + t.last) / 2) || t[t.length / 2] if prev.nil?

          i = t.bsearch_index { |x| x >= prev } || t.length - 1
          mv = MOVES.keys[Dice.index(MOVES.values, dice.rand(:move, s))]
          j = i + mv
          j = i - mv unless j.between?(0, t.length - 1) # (turns back at the edges)
          t[j.clamp(0, t.length - 1)]
        end

        def tonal(f)
          @mutex.synchronize {
            @tonal.shift while @tonal.length >= 64
            @tonal[f] ||= f.tonal.freeze
          }
        end

        # Builds Beats rows from a block (MB::Sound#beats): a method per
        # row, named after a GM drum or drum machine voice (`kick`, `hat`,
        # `open_hat`, `cp`, ...; a typo raises with did-you-mean), or `row
        # :name, ..., note:` / `notes:` for other names; `euclid(hits,
        # steps)` patterns; `fill every: 8, snare: 0.7`.
        class Builder
          # Row names (GM drums and drum machine voices).
          NAMES = Sequence::Grid::GM_DRUMS.merge(Sequence::Grid::ROW_ALIASES).freeze

          def initialize(steps, cycle_length)
            @steps = steps
            @cycle_length = cycle_length
            @rows = []
            @fill = nil
          end

          # The rows and fill built (for MB::Sound#beats).
          def __result
            [@rows, @fill]
          end

          # A Euclidean pattern for a row: +hits+ spread over +steps+
          # (the row's steps by default), rotated by +rotate+; the row's
          # +mutate:+ makes the count and rotation wander.
          def euclid(hits, steps = @steps, rotate: 0)
            ::Kernel.raise ::ArgumentError, "euclid needs 0 to #{steps} hits (got #{hits.inspect})" unless hits.is_a?(::Integer) && hits.between?(0, steps)
            Euclid.new(hits: hits, steps: steps, rotate: rotate)
          end

          # A row named +name+: drum names play their note; other names
          # need +note:+ (a note) or +notes:+ (a Field, Harmony, Weights,
          # or Scale to draw a line from).
          def row(name, pattern = nil, note: nil, notes: nil, keep: [], drift: 0, mutate: 0, level: 1.0, energy: true, length: 1)
            name = name.to_sym
            ::Kernel.raise ::ArgumentError, "Row #{name.inspect} is already defined" if @rows.any? { |r| r.name == name }
            pattern ||= [1.0]
            if pattern.is_a?(Euclid)
              euc = pattern
              pattern = nil
            else
              unless pattern.is_a?(::Array) && !pattern.empty? && pattern.all? { |p| p.is_a?(::Numeric) && p.between?(0, 1) }
                ::Kernel.raise ::ArgumentError, "Row #{name.inspect}'s pattern is an Array of probabilities from 0 to 1, like [1, 0, 0.5, 0] * 4, or euclid(5, 16) (got #{pattern.inspect})"
              end
              pattern = pattern.map(&:to_f).freeze
            end
            field = nil
            if notes
              ::Kernel.raise ::ArgumentError, "Row #{name.inspect} takes note: or notes:, not both" if note
              field = Generative.field(notes)
            else
              note = note ? Scale.root_number(note) : NAMES[name]
              unless note
                hint = ::DidYouMean::SpellChecker.new(dictionary: NAMES.keys).correct(name).first
                ::Kernel.raise ::ArgumentError, "No drum named #{name.inspect}#{hint ? " (did you mean #{hint.inspect}?)" : ''}; other rows need note: or notes:"
              end
            end
            check = ->(x, what) { ::Kernel.raise ::ArgumentError, "Row #{name.inspect}'s #{what}: is from 0 to 1 (got #{x.inspect})" unless x.is_a?(::Numeric) && x.between?(0, 1) }
            check.(drift, :drift)
            check.(mutate, :mutate)
            ::Kernel.raise ::ArgumentError, "Row #{name.inspect}'s level: is from 0 to 2 (got #{level.inspect})" unless level.is_a?(::Numeric) && level.between?(0, 2)
            ::Kernel.raise ::ArgumentError, "Row #{name.inspect}'s keep: is an Array of steps (got #{keep.inspect})" unless keep.is_a?(::Array) && keep.all?(::Integer)
            ::Kernel.raise ::ArgumentError, "Row #{name.inspect}'s length: is a positive number of steps (got #{length.inspect})" unless length.is_a?(::Numeric) && length > 0
            @rows << Row.new(name: name, note: field ? nil : note, field: field, pattern: pattern, euclid: euc, keep: keep.dup.freeze,
              drift: drift.to_f, mutate: mutate.to_f, level: level.to_f, energy: energy ? true : false, length: length.to_r)
            nil
          end

          # A phrase fill: in the last cycle of every +every+ cycles (an
          # Integer, or a length like 8.bars), the last +last+ of the cycle
          # (a length; a quarter of it by default) adds each row's amount
          # (`snare: 0.7`) to its probabilities.  Drums named here without
          # a row of their own get one that plays only in fills.  With
          # +energy: true+ the fill grows denser and longer as the energy
          # rises (its amounts energized like the rows', its length as
          # written at 0.5, doubled at 1, halved toward 0, where it fades
          # out); by default it plays the same at any energy.
          def fill(every:, last: nil, energy: false, **rows)
            ::Kernel.raise ::ArgumentError, 'Only one fill per beats block' if @fill
            cycles = every.is_a?(::Integer) ? every : Generative.length_of(every, :every, divisions: false) / @cycle_length
            ::Kernel.raise ::ArgumentError, "fill every: is a whole number of cycles (got #{every.inspect})" unless cycles.is_a?(::Integer) || cycles.denominator == 1
            cycles = cycles.to_i
            ::Kernel.raise ::ArgumentError, "fill every: is at least 1 cycle (got #{every.inspect})" unless cycles >= 1
            last = last ? Generative.length_of(last, :last, divisions: false) : @cycle_length / 4
            from = @steps - (last / @cycle_length * @steps).ceil.to_i
            ::Kernel.raise ::ArgumentError, 'fill last: is at most one cycle' if from < 0
            ::Kernel.raise ::ArgumentError, 'fill needs rows to fill, like snare: 0.7' if rows.empty?
            rows.each do |name, amount|
              ::Kernel.raise ::ArgumentError, "fill's #{name}: is from 0 to 1 (got #{amount.inspect})" unless amount.is_a?(::Numeric) && amount.between?(0, 1)
            end
            ::Kernel.raise ::ArgumentError, "fill's energy: is true or false (got #{energy.inspect})" unless energy == true || energy == false
            @fill = Fill.new(every: cycles, from: from, rows: rows.transform_values(&:to_f).freeze, energy: energy)
            nil
          end

          # Rows named after drums (see #row).
          def method_missing(name, *args, **kwargs, &block)
            return row(name, *args, **kwargs) if NAMES.key?(name) && block.nil?
            hint = ::DidYouMean::SpellChecker.new(dictionary: NAMES.keys + %i[row euclid fill]).correct(name).first
            ::Kernel.raise ::NoMethodError, "beats has no row or method #{name.inspect}#{hint ? " (did you mean #{hint.inspect}?)" : ''}; rows with other names: row #{name.inspect}, [...], note: or notes:"
          end

          def respond_to_missing?(name, _all = false)
            NAMES.key?(name)
          end
        end
      end
    end
  end
end
