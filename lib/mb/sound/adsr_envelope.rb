module MB
  module Sound
    # An envelope generator with a traditional attack-decay-sustain-release
    # layout.  The envelope rises from 0 to +peak+ in #attack_time seconds when
    # #trigger(peak) is called, then decays to #sustain_level over #decay_time
    # seconds.  The envelope stays at #sustain_level until #release is called,
    # after which the envelope decays to 0 in #release_time seconds.  The
    # envelope is linearly interpolated using the smoothstep function.
    #
    # If the #release method is called before the #sustain_level is reached,
    # then the #release_time seconds decay will start at the envelope's current
    # level.
    #
    # This implementation may resuscitate decayed envelopes or end playing
    # notes if times are changed shortly after a note is released.  If I were
    # to reimplement this, I would use a state machine instead of comparing the
    # time value to switch between phases of the curve.
    #
    # Also, one notable difference between this implementation and other
    # possible implementations is that the times here are literal, while in an
    # exponential envelope the time value may be an exponential time constant
    # (time at which the decay is 1/e).
    #
    # A visual demonstration of the ADSR curve:
    #     # Attack /\ Decay
    #     #       /  \   Sustain
    #     #      /    \_________  Release
    #     #     /               \
    #     #    /                 \
    #     #   /                   \
    #     ################################
    #
    # Example:
    #     # Plot the envelope (also see bin/plot_adsr.rb).
    #     env = MB::Sound::ADSREnvelope.new(
    #       attack_time: 0.05,
    #       decay_time: 0.1,
    #       sustain_level: 0.7,
    #       release_time: 0.5,
    #       rate: 48000
    #     )
    #     env.trigger(1)
    #     a = env.sample(48000)
    #     env.release
    #     b = env.sample(48000)
    #     total = a.concatenate(b)
    #     plotter.plot(envelope: total)
    class ADSREnvelope
      include GraphNode
      include BufferHelper

      attr_reader :attack_time, :decay_time, :sustain_level, :release_time, :total, :peak, :time, :rate

      # Initializes an ADSR envelope with the given +:attack_time+,
      # +:decay_time+, and +:release_time+ in seconds, and the given
      # +:sustain_level+ relative to the peak parameter given to #trigger.  The
      # sample +:rate+ is required to ensure envelope times are accurate.
      #
      # Note that the +:sustain_level+ may be greater than 1.0.
      def initialize(attack_time:, decay_time:, sustain_level:, release_time:, rate:, filter_freq: 1000)
        @rate = rate.to_f
        @on = false

        update(attack_time, decay_time, sustain_level, release_time)

        @auto_release = nil
        @time = @total + 100
        @frame = @rate * @time

        # Single-pole filter avoids overshoot
        @filter = filter_freq.hz.at_rate(rate).lowpass1p
        @peak = 0.5
        @value = 0
        @sust = 0

        @buf = nil
      end

      # Changes the envelope's attack time to +t+ seconds.
      def attack_time=(t)
        update(t, @decay_time, @sustain_level, @release_time)
      end

      # Changes the envelope's decay time to +t+ seconds.
      def decay_time=(t)
        update(@attack_time, t, @sustain_level, @release_time)
      end

      def sustain_level=(l)
        update(@attack_time, @decay_time, l, @release_time)
      end

      def release_time=(t)
        update(@attack_time, @decay_time, @sustain_level, t)
      end

      # Returns true while the envelope is either sustained or releasing.
      def active?
        @on || @time < @total
      end

      # Returns true while the envelope is sustained.
      def on?
        @on
      end

      # Starts (or restarts) the envelope at the beginning, multiplying the
      # entire envelope by +peak+.  The +:auto_release+ parameter may be an
      # approximate number of seconds after which to release the envelope
      # automatically.
      def trigger(peak, auto_release: nil)
        # @sust is a copy of the sustain level that will be changed if the
        # envelope is released before attack+decay finish
        @sust = @sustain_level
        @time = 0
        @frame = 0
        @peak = peak
        @value = 0
        @auto_release = auto_release
        @on = true
      end

      # Starts the release phase of the envelope, if it is not already in the
      # release phase.
      def release
        # @sust is a copy of the sustain level that will be changed if the
        # envelope is released before attack+decay finish
        if @on
          @peak = 1.0
          # Convert to 32-bit float for rounding consistency between C and Ruby loops
          @sust = MB::FastSound.f64to32(@value)
          self.time = @release_start
          @on = false
        end
      end

      # Turn off the envelope, reset the filter, and disable any auto-release
      # given to #trigger.  For testing only; will cause clicking if used on
      # actual audio.
      def reset
        @time = @total + 100
        @frame = @rate * @time
        @on = false
        @auto_release = nil
        @filter.reset(0)
      end

      # Jump the envelope to the given time.  This does not reset the internal
      # smoothing filter, so the transition of the output will not be
      # instantaneous.
      def time=(t)
        @frame = (t * @rate).round
        @time = @frame / @rate.to_f
      end

      # Produces one sample (or many samples if +count+ is not nil) of the
      # envelope.  Call repeatedly to get envelope values over time.  Returns
      # nil if auto_release was set and the envelope has fully released.
      def sample(count = nil, filter: true)
        sample_c(count&.round, filter: filter)
      end

      def sample_c(count = nil, filter: true)
        if count
          sample_count_c(count, filter: filter)
        else
          sample_one_c(filter: filter)
        end
      end

      def sample_count_c(count, filter: true)
        setup_buffer(length: count)

        MB::FastSound.adsr_narray(
          @buf.inplace!,
          @frame,
          @rate,
          @attack_time,
          @decay_time,
          @sust,
          @release_time,
          @peak,
          @on
        )

        @value = @buf[-1]

        advance(count)

        if filter
          @filter.process(@buf.inplace!)
        else
          @filter.process(@buf.not_inplace!)
        end

        return nil if @auto_release && !@on && @time >= @total && @buf.max < -100.db

        @buf.not_inplace!
      end

      def sample_ruby_c(count, filter: true)
        if count
          buf = Numo::SFloat.zeros(count).map { sample_one_c(filter: filter) }
          return nil if @auto_release && !@on && buf.max < -100.db
          return buf
        end

        return sample_one_c(filter: filter)
      end

      def sample_one_c(filter: true)
        @value = MB::FastSound.adsr(
          @time,
          @attack_time,
          @decay_time,
          @sust,
          @release_time,
          @peak,
          @on
        )

        advance(1)

        if filter
          @filter.process_one(@value)
        else
          @filter.process_one(@value)
          @value
        end
      end

      def sample_ruby(count = nil, filter: true)
        if count
          buf = Numo::SFloat.zeros(count).map { sample_ruby(filter: filter) }
          return nil if @auto_release && !@on && buf.max < -100.db
          return buf
        end

        if @on
          case
          when @time < 0
            @value = 0.0

          when @time < @attack_time
            @value = MB::M.smoothstep(@time / @attack_time)

          when @time < @release_start
            @value = 1.0 - MB::M.smoothstep((@time - @attack_time) / @decay_time) * (1.0 - @sust)

          else
            @value = @sust
          end
        else
          case
          when @time < @release_start
            @value = @sust

          when @time < @total
            @value = (1.0 - MB::M.smoothstep((@time - @release_start) / @release_time)) * @sust

          else
            @value = 0.0
          end
        end

        @value *= @peak

        advance(1)

        if filter
          @filter.process_one(@value)
        else
          @filter.process_one(@value)
          @value
        end
      end

      # Returns an inactive duplicate copy of the envelope, allowing the
      # duplicate to be sampled (e.g. for plotting) without changing the state
      # of the original envelope.
      def dup(rate = @rate)
        e = super()
        e.instance_variable_set(:@peak, 1.0) unless active?
        e.instance_variable_set(:@rate, rate.to_f)
        e.instance_variable_set(:@filter, @filter.center_frequency.hz.at_rate(rate).lowpass1p)
        e.reset
        e
      end

      private

      # Calculates internal parameters based on the given envelope parameters.
      # FIXME: envelopes come back to life or disappear abruptly if their times
      # are changed while playing.
      def update(attack_time, decay_time, sustain_level, release_time)
        @attack_time = attack_time.to_f
        @decay_time = decay_time.to_f
        @sustain_level = sustain_level.to_f
        @release_time = release_time.to_f
        @release_start = @attack_time + @decay_time
        @total = @attack_time + @decay_time + @release_time
      end

      # Advances the internal clock by the given number of +samples+.
      def advance(samples)
        @frame += samples
        @time = @frame / @rate.to_f
        release if @auto_release && @on && @time >= @auto_release
      end
    end
  end
end
