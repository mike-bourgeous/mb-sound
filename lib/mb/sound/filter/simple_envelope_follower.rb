module MB
  module Sound
    class Filter
      # Implements a very simple envelope follower based on instant rise and
      # exponential decay.
      class SimpleEnvelopeFollower < Filter
        attr_reader :decay_db, :decay_s, :decay_per_sample, :sample_rate

        # Initializes a simple envelope follower.  Peaks decay +:decay_db+
        # decibels every +decay_s+ seconds, with the given sample +rate+.
        def initialize(rate:, decay_db: -5.0, decay_s: 0.1)
          @sample_rate = rate.to_f
          @decay_db = decay_db.to_f
          @decay_s = decay_s.to_f
          @decay_per_sample = @decay_db.db ** (1.0 / (@decay_s * @sample_rate))

          @v = 0.0
        end

        # Resets the envelope to 0, or to the given value.
        def reset(initial_value = 0)
          @v = initial_value
        end

        # Processes the given array of samples, updating the state of the
        # envelope along the way.  Supports in-place processing of NArray.
        def process(samples)
          samples.map { |v|
            v = v.abs
            @v = v > @v ? v : @v * @decay_per_sample
          }
        end
      end
    end
  end
end
