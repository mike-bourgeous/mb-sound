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
      attr_reader :threshold, :limit, :a, :b, :c

      # Initializes a soft clipper that is linear between +/- +:threshold+, and
      # hyperbolically approaches +:limit+ above that.
      def initialize(threshold:, limit: 1)
        update(threshold.abs, limit.abs)
      end

      # Sets the threshold between the linear and hyperbolic regions.
      def threshold=(t)
        update(t.abs, @limit)
      end

      # Sets the upper output limit of the hyperbolic region.  The output
      # cannot exceed +/- this level.  The default limit is 1.
      def limit=(l)
        update(@threshold, l.abs)
      end

      # Soft-clips the given +samples+, returning the result.  The soft-clip
      # has no memory, so prior data cannot affect the output.  Supports
      # in-place processing of NArray.
      def process(samples)
        return process([samples])[0] if samples.is_a?(Numeric)

        samples.map { |s|
          case
          when s < -@threshold
            -@a / (-s + @c) - @b

          when s > @threshold
            @a / (s + @c) + @b

          else
            s
          end
        }
      end

      private

      # Recalculates the hyperbolic curve parameters
      def update(threshold, limit)
        raise 'Limit must be greater than or equal to threshold' if limit < threshold

        @threshold = threshold
        @limit = limit

        @a = -(-@threshold + @limit) ** 2.0
        @b = @limit
        @c = -2.0 * @threshold + @limit
      end
    end
  end
end
