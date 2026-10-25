module MB
  module Sound
    class LatencyProbe
      # Log-bucket latency histograms in nanoseconds: the Ruby mirror of
      # FastLatency's bucket function (fast_latency.c), used for the Ruby
      # ticker and session series and for reading the probe's histograms.
      #
      # Values under 16 ns have a bucket each; above, 16 buckets per power
      # of two (each ~4.4% of its value wide) up to 2^41 ns (~37 minutes),
      # the last bucket holding everything larger.
      class Histogram
        SUB_BITS = 4
        SUB = 1 << SUB_BITS
        MAX_EXP = 40
        BUCKETS = (MAX_EXP - SUB_BITS + 2) * SUB

        # The bucket index of +ns+ (an Integer; negatives count as 0).
        def self.bucket(ns)
          ns = ns.to_i
          ns = 0 if ns < 0
          return ns if ns < SUB

          e = ns.bit_length - 1
          return BUCKETS - 1 if e > MAX_EXP

          m = (ns >> (e - SUB_BITS)) & (SUB - 1)
          (e - SUB_BITS + 1) * SUB + m
        end

        # The smallest value in bucket +i+.
        def self.floor(i)
          return i if i < SUB

          e = (i >> SUB_BITS) + SUB_BITS - 1
          (SUB + (i & (SUB - 1))) << (e - SUB_BITS)
        end

        # How many values bucket +i+ holds.
        def self.width(i)
          return 1 if i < SUB

          1 << ((i >> SUB_BITS) - 1)
        end

        # The value reported for bucket +i+: its middle.
        def self.value(i)
          floor(i) + (width(i) - 1) / 2
        end

        # The value at quantile +q+ (0..1) of bucket +counts+: the middle of
        # the first bucket whose running count reaches ceil(q * total) (at
        # least 1); 0 when empty.  The same rule as the probe's per-second
        # p50/p99 (FastLatency.percentile).
        def self.percentile(counts, q)
          total = counts.sum
          return 0 if total == 0

          target = [(q * total).ceil, 1].max
          sum = 0
          counts.each_with_index do |c, i|
            sum += c
            return value(i) if sum >= target
          end
          value(BUCKETS - 1)
        end

        # How many values are at least +ns+, counting whole buckets that
        # start at or above it (so within one bucket's width, ~4.4%).
        def self.count_at_least(counts, ns)
          first = bucket(ns)
          first += 1 if floor(first) < ns
          counts[first..].sum
        end

        attr_reader :counts, :max

        def initialize(counts = nil)
          @counts = counts ? counts.dup : Array.new(BUCKETS, 0)
          raise ArgumentError, "Pass #{BUCKETS} bucket counts" unless @counts.length == BUCKETS

          @max = nil
        end

        # Counts one value in nanoseconds.
        def add(ns)
          @counts[self.class.bucket(ns)] += 1
          @max = ns if @max.nil? || ns > @max
          self
        end
        alias << add

        def total
          @counts.sum
        end

        def empty?
          total == 0
        end

        def percentile(q)
          self.class.percentile(@counts, q)
        end

        def count_at_least(ns)
          self.class.count_at_least(@counts, ns)
        end

        # The largest value: the exact maximum if known, else the top
        # occupied bucket's middle.
        def max_ns
          return @max if @max

          i = @counts.rindex { |c| c > 0 }
          i && self.class.value(i)
        end

        # Adds another histogram's counts.
        def merge!(other)
          other_counts = other.is_a?(Histogram) ? other.counts : other
          @counts = @counts.zip(other_counts).map { |a, b| a + b }
          if other.is_a?(Histogram) && other.max
            @max = other.max if @max.nil? || other.max > @max
          end
          self
        end

        # Occupied buckets as [floor_ns, count] pairs (for saving).
        def to_pairs
          @counts.each_with_index.filter_map { |c, i| [self.class.floor(i), c] if c > 0 }
        end
      end
    end
  end
end
