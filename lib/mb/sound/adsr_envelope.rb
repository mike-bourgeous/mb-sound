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
    #       sample_rate: 48000
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

      attr_reader :attack_time, :decay_time, :sustain_level, :release_time, :total, :peak, :time, :sample_rate

      # The approximate amount of time in seconds it takes the smoothing filter
      # to reach equilibrium.  This time is added to the release time when
      # determining whether the envelope is truly finished.
      attr_reader :filter_ringdown

      # Initializes an ADSR envelope with the given +:attack_time+,
      # +:decay_time+, and +:release_time+ in seconds, and the given
      # +:sustain_level+ relative to the peak parameter given to #trigger.  The
      # +:sample_rate+ is required to ensure envelope times are accurate.
      #
      # Note that the +:sustain_level+ may be greater than 1.0.
      def initialize(attack_time:, decay_time:, sustain_level:, release_time:, sample_rate:, filter_freq: 10000)
        @sample_rate = sample_rate.to_f
        @on = false

        update(attack_time, decay_time, sustain_level, release_time)

        @auto_release = nil
        @time = @total + 100
        @frame = @sample_rate * @time

        # Single-pole filter avoids overshoot
        @filter = filter_freq.hz.at_rate(@sample_rate).lowpass1p
        @filter_ringdown = 7.5 * 1.0 / filter_freq.to_f
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

      # Changes the sustain level to +l+, typically from 0..1 (linear; use .db
      # to convert decibels to linear).
      def sustain_level=(l)
        update(@attack_time, @decay_time, l, @release_time)
      end

      # Changes the release time to +t+ seconds.
      def release_time=(t)
        update(@attack_time, @decay_time, @sustain_level, t)
      end

      # Randomizes each of the time parameters within the given +time_range+
      # and randomizes the sustain level between 0 and 1.  Does not reset the
      # envelope (see #reset).
      def randomize(time_range = 0.0..1.0)
        update(rand(time_range), rand(time_range), rand(0.0..1.0), rand(time_range))
      end

      # Returns true while the envelope is either sustained or releasing.
      def active?
        @on || @time < @total + @filter_ringdown
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
        @auto_release = @attack_time + @decay_time if @auto_release == true

        @on = true

        self
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

        self
      end

      # Turn off the envelope, reset the filter, and disable any auto-release
      # given to #trigger.  For testing or visualization only; will cause
      # clicking if used on actual audio.
      def reset
        @time = @total + 100
        @frame = @sample_rate * @time
        @on = false
        @auto_release = nil
        @filter.reset(0)
        self
      end

      # Jump the envelope to the given time.  This does not reset the internal
      # smoothing filter, so the transition of the output will not be
      # instantaneous.
      #
      # See #reset if you want to clear the smoothing filter state and jump to
      # time zero.
      def time=(t)
        @frame = (t * @sample_rate).round
        @time = @frame / @sample_rate.to_f
      end

      # Produces one sample (or many samples if +count+ is not nil) of the
      # envelope.  Call repeatedly to get envelope values over time.  Returns
      # nil if auto_release was set and the envelope has fully released.
      def sample(count = nil, filter: true)
        sample_c(count&.round, filter: filter)
      end

      # Resets, triggers (at level 1.0), and samples the entire envelope,
      # holding the sustain level for +:sustain_time seconds, and returning the
      # resulting Numo::NArray.
      #
      # This will change the internal state of the envelope, so do not call
      # this on an envelope that is processing audio.
      def sample_all(sustain_time: (attack_time + decay_time + release_time) / 3.0)
        reset

        trigger(1)
        d1 = sample(@sample_rate * (@attack_time + @decay_time + sustain_time)).dup.not_inplace!

        release
        d2 = sample(@sample_rate * @release_time).dup.not_inplace!

        d1.concatenate(d2)
      end

      def sample_c(count = nil, filter: true)
        if count
          sample_count_c(count, filter: filter)
        else
          sample_one_c(filter: filter)
        end
      end

      def sample_count_c(count, filter: true)
        # TODO: Use expand_buffer
        setup_buffer(length: count)

        retbuf, @frame, @time, @on, @peak, @sust = MB::FastSound.adsr_narray(
          @buf.inplace!,
          @frame,
          @sample_rate,
          @attack_time,
          @decay_time,
          @sust,
          @release_time,
          @peak,
          @on,
          @auto_release,
          filter ? @filter_ringdown : 0
        )

        @value = retbuf[-1]

        if filter
          @filter.process(retbuf.inplace!)
        else
          # Update filter state without modifying retbuf
          @filter.process(retbuf.not_inplace!)
        end

        return nil if @auto_release && !@on && @time >= @total && retbuf.max < -100.db

        retbuf.not_inplace!
      end

      def sample_ruby_c(count, filter: true)
        if count
          setup_buffer(length: count)

          maybe_idx = @buf.inplace.map_with_index { |_v, idx|
            v = sample_one_c(filter: filter)
            break idx unless v
            v
          }

          if maybe_idx.is_a?(Integer)
            retbuf = @buf[0...maybe_idx]
          else
            retbuf = @buf
          end

          return nil if @auto_release && !@on && @buf.max < -100.db

          return retbuf
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

        return nil if @auto_release && !@on && @time >= @total + (filter ? @filter_ringdown : 0) && @value == 0

        if filter
          @filter.process_one(@value)
        else
          @filter.process_one(@value)
          @value
        end
      end

      def sample_ruby(count = nil, filter: true)
        if count
          setup_buffer(length: count)

          maybe_idx = @buf.inplace.map_with_index { |_v, idx|
            v = sample_ruby(filter: filter)
            break idx unless v
            v
          }

          if maybe_idx.is_a?(Integer)
            retbuf = @buf[0...maybe_idx]
          else
            retbuf = @buf
          end

          # TODO: maybe do this check before spending CPU cycles
          return nil if @auto_release && !@on && @buf.max < -100.db

          return retbuf
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

        return nil if @auto_release && !@on && @time >= @total + (filter ? @filter_ringdown : 0) && @value == 0

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
      def dup(sample_rate = @sample_rate)
        e = super()
        e.instance_variable_set(:@buf, @buf.dup)
        e.named("#{graph_node_name} (dup)")
        e.instance_variable_set(:@peak, 1.0) unless active?
        e.instance_variable_set(:@sample_rate, sample_rate.to_f)
        e.instance_variable_set(:@filter, @filter.center_frequency.hz.at_rate(sample_rate).lowpass1p)
        e.reset
        e
      end

      private

      # Calculates internal parameters based on the given envelope parameters.
      #
      # FIXME: envelopes come back to life or disappear abruptly if their times
      # are changed while playing.  The envelope time should also be updated to
      # be at the same phase and amplitude (unless in the sustain phase) after
      # the update.
      def update(attack_time, decay_time, sustain_level, release_time)
        @attack_time = attack_time.to_f
        @decay_time = decay_time.to_f
        @sustain_level = sustain_level.to_f
        @release_time = release_time.to_f
        @release_start = @attack_time + @decay_time
        @total = @attack_time + @decay_time + @release_time

        self
      end

      # Advances the internal clock by the given number of +samples+ (not used
      # by #sample_count_c as the C code tracks these variables).
      def advance(samples)
        @frame += samples
        @time = @frame / @sample_rate.to_f

        release if @on && @auto_release && @time >= @auto_release
      end
    end
  end
end
