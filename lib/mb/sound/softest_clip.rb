module MB
  module Sound
    # A soft-clipping filter that preserves perfect linearity for the vast
    # majority of the dynamic range, preserves continuity of the first
    # derivative, and gently clips an infinite amount of excess dynamic range
    # into the given limit.
    #
    # This is a design I made in the early 2000s as a mod to a classic Linux
    # softsynth, the Ultramaster Juno-6 emulation.  The design is based on
    # descriptions I had read of analog audio tape and filmstock, with a
    # central linear range, and a long, infinite soft tail.
    class SoftestClip
      def initialize(threshold:, limit: 1)
        # TODO: Asymmetric clipping?
        @t = threshold.abs
        @l = limit.abs

        @a = -(-@t + @l) ** 2
        @b = @l
        @c = -2 * @t + @l
      end

      # Soft-clips the given +samples+, returning the result.  The soft-clip
      # has no memory, so prior data cannot affect the output.  Supports
      # in-place processing of NArray.
      def process(samples)
        samples.map { |s|
          case
          when s < -@t
            -@a / (-s + @c) - @b

          when s > @t
            @a / (s + @c) + @b

          else
            s
          end

          # Experimental soft-knee
          v = @a / (s.abs + @c) + @b
          v *= -1 if s < 0
          if s.abs >= @t - 0.1 && s.abs <= @t + 0.1
            blend = (s.abs - (@t - 0.1)) / 0.2
            puts "s: #{s} v: #{v} t: #{@t} blend: #{blend}"
            MB::M.interp(s, v, MB::M.smootherstep(blend))
          elsif s.abs > @t + 0.1
            puts "v: #{v}"
            v
          else
            puts "s: #{s}"
            s
          end
        }
      end
    end
  end
end
