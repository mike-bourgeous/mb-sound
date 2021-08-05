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
      attr_reader :attack_time, :decay_time, :sustain_level, :release_time, :total, :peak, :time, :rate

      # Initializes an ADSR envelope with the given +:attack_time+,
      # +:decay_time+, and +:release_time+ in seconds, and the given
      # +:sustain_level+ relative to the peak parameter given to #trigger.  The
      # sample +:rate+ is required to ensure envelope times are accurate.
      #
      # Note that the +:sustain_level+ may be greater than 1.0.
      def initialize(attack_time:, decay_time:, sustain_level:, release_time:, rate:)
        @rate = rate.to_f
        @on = false

        update(attack_time, decay_time, sustain_level, release_time)

        @time = @total + 100
        @frame = @rate * @time

        # Single-pole filter avoids overshoot
        @filter = 100.hz.at_rate(rate).lowpass1p
        @peak = 1
        @value = 0
        @sust = 0
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

      # Starts (or restarts) the envelope at the beginning, multiplying the
      # entire envelope by +peak+.
      def trigger(peak)
        # @sust is a copy of the sustain level that will be changed if the
        # envelope is released before attack+decay finish
        @sust = @sustain_level
        @time = 0
        @frame = 0
        @peak = peak
        @value = 0
        @on = true
      end

      # Starts the release phase of the envelope, if it is not already in the
      # release phase.
      def release
        # @sust is a copy of the sustain level that will be changed if the
        # envelope is released before attack+decay finish
        if @on
          @sust = @value
          @time = @release_start
          @frame = @release_start * @rate
          @on = false
        end
      end

      # Produces one sample of the envelope (or many samples if +count+ is not
      # nil).  Call repeatedly to get envelope values over time.
      def sample(count = nil)
        if count
          return Numo::SFloat.zeros(count).map { sample }
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

        @frame += 1
        @time = @frame / @rate

        @filter.process([@value])[0] * @peak
      end

      # Returns a duplicate copy of the envelope, allowing the duplicate to be
      # sampled (e.g. for plotting) without changing the state of the original
      # envelope.
      def dup(rate = @rate)
        e = super()
        e.instance_variable_set(:@rate, rate)
        e.instance_variable_set(:@filter, 100.hz.at_rate(rate).lowpass1p)
        e
      end

      private

      def update(attack_time, decay_time, sustain_level, release_time)
        @attack_time = attack_time.to_f
        @decay_time = decay_time.to_f
        @sustain_level = sustain_level.to_f
        @release_time = release_time.to_f
        @release_start = @attack_time + @decay_time
        @total = @attack_time + @decay_time + @release_time
      end
    end
  end
end
