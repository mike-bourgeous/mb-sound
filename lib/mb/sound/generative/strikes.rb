module MB
  module Sound
    module Generative
      # Sparse generated hits for textures and ambient pieces: bowls, rin,
      # gongs, drips, plucks now and then (MB::Sound#strikes).  Each step of
      # +every+ is a candidate with probability +chance+; a candidate within
      # +gap+ steps after another candidate is dropped (so strikes never
      # crowd, and the rule looks only at nearby steps: any cycle can be
      # computed alone), and each strike draws its note from +field+ (a
      # Field, FieldTimeline, Weights, Harmony, or Scale; see
      # Generative.field) at its position, sharpened by +sharpen+ (above 1
      # favors the strongest notes).
      #
      # Steps are counted from the clip's start, not per cycle, so the
      # cycle length (+length+) only sets how often the cache refreshes and
      # where a non-looping clip ends.
      class Strikes
        def initialize(field, every:, length:, chance:, gap:, sharpen:, velocity:, note_length:, seed:)
          @field = field
          @every = every
          @length = length
          @steps = length / every
          raise ArgumentError, "strikes' length must be a whole number of steps (#{Sequence::Duration.format(length)} / #{Sequence::Duration.format(every)})" unless @steps.denominator == 1 && @steps > 0
          @steps = @steps.to_i
          raise ArgumentError, "strikes take at most 4096 steps per cycle (got #{@steps})" if @steps > 4096
          @chance = chance
          @gap = gap
          @sharpen = sharpen.to_f
          @velocity = velocity
          @note_length = note_length
          @seed = seed
          @sharp = {}.compare_by_identity
          @mutex = Mutex.new
        end

        # The events of +cycle+ with +dice+ (Dice.new(seed, cycle)).
        def events(cycle, dice)
          root = Dice.new(dice.seed, :strike)
          chance = @chance.respond_to?(:call) ? @chance.call(cycle).to_f : @chance.to_f
          first = cycle * @steps
          # Candidates from gap - 1 steps before the cycle on (one call into C)
          from = first - (@gap - 1)
          cand = Array.new(@steps + @gap - 1) { |i| root.rand(from + i) < chance }
          out = []
          @steps.times do |s|
            i = s + @gap - 1
            next unless cand[i]
            next if (1...@gap).any? { |d| cand[i - d] }

            pos = cycle * @length + s * @every
            f = Generative.field_at(@field, pos)
            note = sharp(f).then { |w| (k = Dice.index(w, dice.rand(:note, s))) && f.notes[k] }
            next unless note
            v = @velocity.is_a?(Range) ? @velocity.begin + (@velocity.end - @velocity.begin) * dice.rand(:vel, s) : @velocity.to_f
            out << Sequence::Event.new(start: s * @every, length: @note_length, value: note, velocity: v.clamp(0.0, 1.0))
          end
          out
        end

        private

        # The sharpened weights of field +f+ (cached per Field object).
        def sharp(f)
          return f.weights if @sharpen == 1.0
          @mutex.synchronize {
            @sharp.shift if @sharp.length >= 64
            @sharp[f] ||= f.weights.map { |w| w**@sharpen }.freeze
          }
        end
      end
    end
  end
end
