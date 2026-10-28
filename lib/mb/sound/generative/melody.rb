module MB
  module Sound
    module Generative
      # The note walk of MB::Sound#melody over a probability scale (Weights,
      # Harmony, Field, or Harmony#over): each note moves at most +leap+
      # notes along the field's notes with weight, choosing by the notes'
      # weights divided by the size of the move (steps beat leaps), or
      # times Sequence::Generators::REPEAT_WEIGHT to stay; a blurred field
      # gives its "wrong" notes a small chance.  The field is read where
      # each note starts, so a Harmony's key and chord changes steer the
      # line.  Draws come from the cycle's Dice: any cycle can be computed
      # alone.
      class Melody
        # +slots+ are Events (start, length, velocity) to give notes;
        # +start+ is the note to start nearest to (the field's strongest
        # note nearest it).
        # +fields+ (a steered range) gives [field, start] for a range.
        def initialize(field, slots, length:, leap:, rest:, start:, fields: nil)
          @field = field
          @fields = fields
          @by_range = {}
          @mutex = Mutex.new
          @slots = slots
          @length = length
          @leap = leap
          @rest = rest
          @start = start
        end

        # The events of +cycle+ with +dice+; steered options (G3) come
        # decided for the cycle: +rest+ (0..1), +leap+ (rounded, at least
        # 1), and +range+ (one of the ranges the steered range chooses).
        def events(cycle, dice, rest: @rest, leap: @leap, range: nil)
          rest = rest.to_f.clamp(0.0, 1.0)
          leap = MB::M.max(leap.round, 1)
          field, start = range ? field_for(range) : [@field, @start]
          current = nil
          @slots.each_with_index.filter_map { |slot, i|
            next nil if i > 0 && rest > 0 && dice.rand(:rest, i) < rest

            f = Generative.field_at(field, cycle * @length + slot.start)
            notes = f.notes.select.with_index { |_, k| f.weights[k] > 0 }
            next nil if notes.empty?

            current = if current.nil?
                        f.home(start) || notes.min_by { |n| (n - start).abs }
                      else
                        step(f, notes, current, dice.rand(:step, i), leap)
                      end
            slot.with(value: current)
          }
        end

        private

        # [field, start note] for a steered +range+ (cached).
        def field_for(range)
          @mutex.synchronize { @by_range[range] } || begin
            pair = @fields.call(range).freeze
            @mutex.synchronize {
              @by_range.shift while @by_range.length >= 16
              @by_range[range] ||= pair
            }
          end
        end

        def step(f, notes, current, u, leap)
          idx = notes.index(current) || notes.index { |n| n >= current } || notes.length - 1
          lo = MB::M.max(idx - leap, 0)
          hi = MB::M.min(idx + leap, notes.length - 1)
          options = notes[lo..hi]
          w = options.each_with_index.map { |n, k|
            d = (lo + k - idx).abs
            f[n] * (d == 0 ? Sequence::Generators::REPEAT_WEIGHT : 1.0 / d)
          }
          k = Dice.index(w, u)
          k ? options[k] : current
        end
      end
    end
  end
end
