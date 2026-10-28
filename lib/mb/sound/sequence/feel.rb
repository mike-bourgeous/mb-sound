module MB
  module Sound
    module Sequence
      # The shared core of the feel transforms (midi-consol-1, 2026-10-16:
      # "shared core, two front ends"): one event-level implementation of
      # humanize, quantize, swing, and cycle conditions, used by the Clip
      # methods (Clip#humanize, #quantize, #swing, #every, which know the
      # future, so they move notes both ways and wrap loops) and by the MIDI
      # stream transforms (MIDI::Stream#humanize, #quantize, #swing, #every,
      # which only delay, since live input has no lookahead).  Both front
      # ends take the same option names and defaults where the physics
      # allows (a stream can't move a note earlier than it was played).
      module Feel
        # The default largest timing offset of humanize (4 ms; user,
        # 2026-10-10: 1/64 was too much).  Clips move notes up to this much
        # earlier or later, streams up to this much later (maintainer
        # decision 7, 2026-10-16).
        HUMANIZE_TIME = MB::Sound::Length::Seconds.new(0.004)

        # The default swing amount (a light shuffle; 0.5 is straight).
        SWING = 0.58

        # The default grid of quantize and swing (16th notes).
        GRID = 16

        # Quantize directions: :nearest step (clips), or :next step (live
        # streams, which can only delay).
        DIRECTIONS = [:nearest, :next].freeze

        class << self
          # Validates a 0..1 amount (quantize's +:amount+, humanize's
          # +:velocity+), returning it.
          def check_fraction(name, value)
            raise ArgumentError, "#{name} must be from 0 to 1 (got #{value.inspect})" unless value.is_a?(Numeric) && value.between?(0, 1)
            value
          end

          # Validates a swing amount: over 0 and under 1 (0.5 straight), or
          # from 0.5 with +delay_only+ (streams can't move notes earlier).
          # Returns it as a Rational.
          def check_swing(amount, delay_only: false)
            unless amount.is_a?(Numeric) && amount > 0 && amount < 1
              raise ArgumentError, "Swing must be between 0 and 1 (got #{amount.inspect})"
            end
            if delay_only && amount < 0.5
              raise ArgumentError, "A stream's swing only delays offbeats, so it goes from 0.5 (straight) up (got #{amount.inspect}); clips can swing early (Clip#swing)"
            end
            Duration.rational(amount)
          end

          # One note's humanize draws from +rng+ (two draws, timing then
          # velocity, whether or not the velocity changes, so every front
          # end draws the same sequence): returns [offset, velocity], where
          # +offset+ is a fraction of the humanize time (-1..1 with
          # +both_ways+, else 0..1, later only), and +velocity+ is
          # +velocity_in+ changed by up to +amount+ (a fraction; 0 or a nil
          # velocity leaves it as given).
          def humanize_draw(rng, velocity_in, amount, both_ways:)
            r = rng.rand
            offset = both_ways ? r * 2 - 1 : r
            v = rng.rand * 2 - 1
            velocity = velocity_in
            velocity = MB::M.clamp(velocity_in * (1 + v * amount), 1 / 127.0, 1.0) if amount > 0 && velocity_in
            [offset, velocity]
          end

          # The step of +grid+ (whole notes) that +position+ (whole notes)
          # quantizes to: the nearest (+:nearest+, halfway rounds away from
          # 0) or the next at or after it (+:next+).  Returns nil if the step
          # is more than +window+ (whole notes, nil for any distance) away.
          def quantize_step(position, grid, direction: :nearest, window: nil)
            target = case direction
                     when :nearest then (position / grid).round * grid
                     when :next then (position / grid).ceil * grid
                     else raise ArgumentError, "Quantize direction must be one of #{DIRECTIONS.map(&:inspect).join(', ')} (got #{direction.inspect})"
                     end
            return nil if window && (target - position).abs > window
            target
          end

          # Where a groove template (Sequence::Groove) puts a note at
          # +position+ (whole notes): its quantize step on +grid+ (whole
          # notes; #quantize_step, +direction+ :nearest for clips, :next
          # for streams) plus the template's offset for that step, cycling
          # through +offsets+ from position 0.  Returns [target, index].
          def groove_target(position, grid, offsets, direction: :nearest)
            step = quantize_step(position, grid, direction: direction)
            i = (step / grid).to_i % offsets.length
            [step + offsets[i], i]
          end

          # +position+ (whole notes) through the swing time warp: within each
          # pair of +grid+ steps, the second step starts at +amount+ of the
          # pair instead of halfway, and times in between stretch to match
          # (so note starts and ends move smoothly).  Exact for Rationals.
          def swing_warp(position, amount, grid)
            pair = grid * 2
            base = (position / pair).floor * pair
            p = (position - base) / grid # 0..2 within the pair
            base + (p <= 1 ? p * amount * 2 : amount * 2 + (p - 1) * (2 - amount * 2)) * grid
          end

          # True if a cycle condition [n, from] (Clip#every, Seq::Step#every;
          # nil for none) lets a note play in 0-based +cycle+ (a loop cycle
          # for clips, a bar of the timeline for streams).
          def condition_plays?(condition, cycle)
            return true unless condition
            n, from = condition
            cycle >= from - 1 && (cycle - (from - 1)) % n == 0
          end
        end
      end
    end
  end
end
