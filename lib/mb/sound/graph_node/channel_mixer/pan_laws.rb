module MB
  module Sound
    module GraphNode
      class ChannelMixer
        # Gain curves for panning and balance.  Every function takes a
        # position from -1 (left) through 0 (center) to 1 (right) as a number
        # or an NArray (one position per sample), clamps it to -1..1, and
        # returns gains of the same kind: [left gain, right gain] for mono
        # laws (.gains, .balance), or a 2x2 matrix for stereo laws (.stereo).
        module PanLaws
          # Laws for mono panning (#gains), by center level:
          # - :equal_power: -3 dB at the center (cos/sin), so loudness stays
          #   even as an uncorrelated signal moves
          # - :minus_4_5db: -4.5 dB at the center, a compromise between the
          #   other two
          # - :linear: -6 dB at the center, so a mono mixdown stays even
          LAWS = ChannelMethods::PAN_LAWS

          # Laws for panning a stereo input (#stereo), as
          # Channels#balance(law:) and Channels#pan(law:) take them:
          # - :balance (the default): unity at the center; the favored side
          #   stays at full level and the other fades out on an equal-power
          #   curve scaled to unity (about -5.3 dB at +/-0.5; see .balance)
          # - :constant_power (ACID's "Constant Power", and its "Film" in
          #   stereo): the mono :equal_power gains, the left one on the left
          #   channel and the right one on the right (-3 dB on both at the
          #   center; hard right keeps only the right channel)
          # - :balance_0db, :balance_3db, :balance_6db (ACID's "Balance
          #   0 dB", "-3 dB", "-6 dB"): the center at 1, -3 dB, or -6 dB
          #   (g), with straight lines out to full level on the favored side
          #   (g + (1 - g)|x|) and silence on the other (g(1 - |x|));
          #   :balance_6db is the mono :linear law on each channel
          # - :add_channels (ACID's default, "Add Channels"): unity at the
          #   center, and the far channel moves into the near one as the
          #   position moves, so a hard pan is the mono sum on one side and
          #   nothing disappears (except by phase cancellation): for x >= 0,
          #   L' = (1 - x)L and R' = R + xL (mirrored for x < 0).
          #   Provisional: modeled from ACID's description, not yet measured
          #   against an ACID render (whether ACID scales the sum).
          # The ACID laws were measured against ACID's own render of a
          # pan-law reference project (2026-11-04, research-acd-format-linux).
          STEREO_LAWS = %i[balance constant_power balance_0db balance_3db balance_6db add_channels].freeze

          # The center gains of the linear balance laws (see STEREO_LAWS).
          BALANCE_CENTERS = { balance_0db: 1.0, balance_3db: Math.sqrt(0.5), balance_6db: 0.5 }.freeze

          # Returns [left, right] gains for panning a mono signal to
          # +position+ with +law+ (one of LAWS).
          def self.gains(law, position)
            p = clamp(position)

            case law
            when :equal_power
              angle = (p + 1) * (Math::PI / 4)
              m = ChannelMixer.math(angle)
              [m.cos(angle), m.sin(angle)]

            when :linear
              [(1 - p) * 0.5, (p + 1) * 0.5]

            when :minus_4_5db
              # The -6 dB curve raised to the 0.75 power (as ComplexPan did)
              [((1 - p) * 0.5) ** 0.75, ((p + 1) * 0.5) ** 0.75]

            else
              raise ArgumentError, "Unknown pan law #{law.inspect} (use one of #{LAWS.map(&:inspect).join(', ')})"
            end
          end

          # Returns [left, right] gains for balancing a stereo signal to
          # +position+, as most DAWs do for stereo tracks: full level on the
          # favored side, and an equal-power fade on the other side, scaled
          # to unity at the center (about -5.3 dB at +/-0.5).
          def self.balance(position)
            p = clamp(position)
            angle = (p + 1) * (Math::PI / 4)

            if p.is_a?(Numo::NArray)
              [(Numo::NMath.cos(angle) * Math.sqrt(2)).clip(0, 1), (Numo::NMath.sin(angle) * Math.sqrt(2)).clip(0, 1)]
            else
              [[Math.cos(angle) * Math.sqrt(2), 1].min, [Math.sin(angle) * Math.sqrt(2), 1].min]
            end
          end

          # Returns the 2x2 gain matrix for panning a stereo signal to
          # +position+ with +law+ (one of STEREO_LAWS): rows are the
          # outputs and columns the inputs, [[L to L, R to L], [L to R,
          # R to R]], with 0 (an Integer) where a law never mixes channels.
          def self.stereo(law, position)
            case law
            when :balance
              left, right = balance(position)
              [[left, 0], [0, right]]

            when :constant_power
              left, right = gains(:equal_power, position)
              [[left, 0], [0, right]]

            when *LINEAR_STEREO_LAWS
              linear_stereo(law, clamp(position)) { |x, lo, hi| clip(x, lo, hi) }

            else
              raise ArgumentError, "Unknown stereo pan law #{law.inspect} (use one of #{STEREO_LAWS.map(&:inspect).join(', ')})"
            end
          end

          # The stereo laws that are straight lines between the center and
          # the ends (see .linear_stereo).
          LINEAR_STEREO_LAWS = (BALANCE_CENTERS.keys + [:add_channels]).freeze

          # The matrix of a straight-line stereo law (LINEAR_STEREO_LAWS)
          # for a position +p+ already clamped to -1..1, with the block
          # clipping a value to lo..hi (`{ |x, lo, hi| ... }`).  Written once
          # for numbers, NArrays, and plan Values (Plan::Value: only *, +,
          # and the block's clip), so a planned ChannelMixer::Balance
          # computes the same float32 steps as an unplanned one: u (how far
          # right, 0..1) and v (how far left), then products and sums of
          # them with the law's constants.
          def self.linear_stereo(law, p)
            u = yield(p, 0, 1)
            v = yield(p * -1, 0, 1)

            # (1 - u written as -u + 1: plan Values have no subtraction; in
            # float the two are the same)
            keep_left = u * -1 + 1
            keep_right = v * -1 + 1

            return [[keep_left, v], [u, keep_right]] if law == :add_channels

            g = BALANCE_CENTERS.fetch(law)
            return [[keep_left, 0], [0, keep_right]] if g == 1

            # Near side g + (1 - g)|x| (times 1), far side g times 1 - |x|
            [[(v * (1 - g) + g) * keep_left, 0], [0, (u * (1 - g) + g) * keep_right]]
          end

          # Clamps +position+ to -1..1.
          def self.clamp(position)
            clip(position, -1, 1)
          end

          # Clips +value+ (a number or NArray) to +lo+..+hi+.
          def self.clip(value, lo, hi)
            value.is_a?(Numo::NArray) ? value.clip(lo, hi) : MB::M.clamp(value, lo, hi)
          end
        end
      end
    end
  end
end
