module MB
  module Sound
    module GraphNode
      class Dynamics
        # A very simple envelope follower: instant rise and exponential
        # decay (peaks fall +decay_db+ every +decay_s+ seconds), as a Filter
        # (`sig.filter(Dynamics::SimpleEnvelopeFollower.new(sample_rate:
        # 48000))`).
        #
        # The maintainer's 2021 code, moved here from Filter in omnibus18
        # (2026-10-30; his note: "should be used/moved/extended in
        # follower-type effect code"): the base to grow for the effects
        # round's `follow`/swell (anti-duck) work (dynamics.md, Later).  The
        # compander's own detector (peak/RMS in dB, in fast_dynamics) is a
        # different design, so nothing duplicates it today.
        class SimpleEnvelopeFollower < MB::Sound::Filter
          attr_reader :decay_db, :decay_s, :decay_per_sample, :sample_rate

          # Initializes a simple envelope follower.  Peaks decay +:decay_db+
          # decibels every +decay_s+ seconds, with the given +:sample_rate+.
          def initialize(sample_rate:, decay_db: -5.0, decay_s: 0.1)
            @sample_rate = sample_rate.to_f
            @decay_db = decay_db.is_a?(Decibels) ? decay_db.db_value : decay_db.to_f
            @decay_s = decay_s.to_f
            @decay_per_sample = @decay_db.db ** (1.0 / (@decay_s * @sample_rate))

            @v = 0.0
          end

          # Keeps the decay time in seconds at a new sample rate.
          def sample_rate=(rate)
            @sample_rate = rate.to_f
            @decay_per_sample = @decay_db.db ** (1.0 / (@decay_s * @sample_rate))
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
end
