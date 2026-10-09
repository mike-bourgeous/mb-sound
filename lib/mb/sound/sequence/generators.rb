module MB
  module Sound
    module Sequence
      # Pattern generators (the MIDI transforms project, 2026-10-10):
      # Euclidean rhythms and scale-weighted random melodies, used by
      # MB::Sound#euclid and MB::Sound#melody.  Random choices come from a
      # seed (by default drawn from MB::Sound's root seed when the pattern
      # is made, so a script makes the same patterns every run; see
      # MB::Sound#seed), kept as the clip's seed.
      module Generators
        # Bjorklund's algorithm: +hits+ onsets spread as evenly as possible
        # over +steps+ steps, as an Array of true/false starting with an
        # onset (Toussaint's canonical rotation: E(3, 8) is x..x..x.,
        # E(5, 8) is x.xx.xx.).  +rotate+ moves the pattern later by that
        # many steps (negative for earlier).
        def self.euclid_pattern(hits, steps, rotate: 0)
          raise ArgumentError, "Euclidean steps must be a positive Integer (got #{steps.inspect})" unless steps.is_a?(Integer) && steps > 0
          raise ArgumentError, "Euclidean hits must be an Integer from 0 to #{steps} (got #{hits.inspect})" unless hits.is_a?(Integer) && hits.between?(0, steps)

          return Array.new(steps, false) if hits == 0

          groups = Array.new(hits) { [true] }
          rest = Array.new(steps - hits) { [false] }
          while rest.length > 1
            m = MB::M.min(groups.length, rest.length)
            merged = Array.new(m) { |i| groups[i] + rest[i] }
            rest = groups.length > m ? groups[m..] : rest[m..]
            groups = merged
          end

          (groups + rest).flatten.rotate(-rotate)
        end

        # How likely a melody repeats a note, against a step of one degree
        # (times the degree's weight).
        REPEAT_WEIGHT = 0.3

        # Default weights by scale degree for #melody: the root, third, and
        # fifth of a seven-note scale are favored (for other sizes, every
        # other degree from the root).
        def self.default_weights(size)
          if size == 7
            [4, 1, 3, 1, 3, 1, 1]
          else
            Array.new(size) { |i| i == 0 ? 4 : (i.even? ? 2 : 1) }
          end
        end

        # Note numbers for a random melody (see MB::Sound#melody): a walk
        # over the degrees of +scale+ starting at degree +start+, each step
        # moving at most +leap+ degrees, choosing among the degrees within
        # +range+ (note numbers) by +weights+ (per degree in the period,
        # cycled) divided by the size of the move (so steps beat leaps), or
        # times REPEAT_WEIGHT for staying on a note.  Returns +count+
        # values (nil for rests, with probability +rest+).
        def self.melody_notes(scale, count, rng:, range:, weights:, leap:, rest:, start:)
          size = scale.size
          weights = weights ? Array(weights) : default_weights(size)
          lo, hi = range
          deg = start
          deg += size while scale.note(deg) < lo
          deg -= size while scale.note(deg) > hi

          Array.new(count) { |i|
            next nil if i > 0 && rest > 0 && rng.rand < rest

            if i > 0
              options = (deg - leap..deg + leap).select { |d| (lo..hi).cover?(scale.note(d)) }
              options = [deg] if options.empty?
              w = options.map { |d| weights[d % size].to_f * (d == deg ? REPEAT_WEIGHT : 1.0 / (d - deg).abs) }
              pick = rng.rand * w.sum
              idx = w.index { |x| (pick -= x) < 0 } || options.length - 1
              deg = options[idx]
            end
            scale.note(deg)
          }
        end
      end
    end
  end
end
