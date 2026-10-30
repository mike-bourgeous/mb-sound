module MB
  module Sound
    class Filter
      # GraphNode#smooth's filter: MB::Sound::Notes::Smoother (the MIDI
      # controller smoother) on any signal, so `smooth` and controller
      # smoothing are one engine, in C (FastControl) and planned
      # (Plan::Op::Smooth).
      #
      # Without a curve it is a linear FIR filter whose kernel is a triangle
      # of +length+ (two moving averages), so each step becomes an S-shaped
      # quadratic B-spline transition over +length+ (continuous slope, the
      # shape of the smoothstep within 0.07 of the step), a stream of steps
      # (a 7-bit knob, note numbers) becomes their smooth interpolation, and
      # a moving signal passes delayed by half the length (a 3 Hz LFO
      # through smooth(0.01) keeps its level within 0.01 dB).  The output
      # reaches the input exactly once it has held for +length+.
      #
      # With +curve:+ (an MB::Sound::Curve name, a Curve, or a Proc) the
      # step response is that curve over +length+ (see Notes::Smoother):
      # a single step follows the curve exactly, overlapping steps add up.
      # A Range +length+ (5.ms..200.ms) is the controllers' adaptive
      # smoothing.
      #
      # The output starts on the input's first sample, or on +from+.
      #
      # Replaced Filter::Smoothstep (smoothing-1, 2026-10-30), which
      # restarted a smoothstep from the current output on every change: on
      # moving inputs it barely moved (a 3 Hz LFO through smooth(0.01) came
      # out 29.6 dB lower and 80 ms late) and on a turned knob it lagged a
      # whole step behind (see design/notes/curves.md).
      class Smooth < Filter
        # The smoothing time as given (seconds, a Length, or a Range).
        attr_reader :length

        # The step-response curve (an MB::Sound::Curve), or nil.
        attr_reader :curve

        # The starting value given to the constructor (nil: the input's
        # first sample).
        attr_reader :from

        # The Notes::Smoother doing the work.
        attr_reader :smoother

        # See the class description.
        def initialize(length, sample_rate:, curve: nil, from: nil)
          raise ArgumentError, "Smoothing length must be positive (got #{length.inspect})" if length.is_a?(Numeric) && !(length > 0)
          raise ArgumentError, "Smoothing start must be a number (got #{from.inspect})" unless from.nil? || from.is_a?(Numeric)

          @length = length
          @from = from&.to_f
          @smoother = MB::Sound::Notes::Smoother.new(length, sample_rate: sample_rate, curve: curve)
          @curve = @smoother.curve
          @smoother.plan_start(@from) if @from
        end

        # The sample rate in Hz.
        def sample_rate
          @smoother.sample_rate
        end

        # Changes the sample rate (the length stays the same in time).
        def sample_rate=(rate)
          @smoother.sample_rate = rate
          self
        end
        alias at_rate sample_rate=

        # The transition's length in samples at the current rate.
        def kernel_samples
          @smoother.kernel_samples
        end

        # Holds +value+ with nothing moving (as if it had been the input for
        # a long time).
        def reset(value = 0.0)
          @smoother.plan_start(value.to_f)
          self
        end

        # Returns +samples+ smoothed (a reused SFloat).
        def process(samples)
          @smoother.process(real(samples))
        end

        # Like #process, but at every sample where +reset+ (an NArray of the
        # same length) is nonzero the output jumps to the input instead of
        # gliding (and any glide in progress stops), e.g. to glide only
        # between legato notes.  Used by GraphNode#smooth with +reset:+.
        def dynamic_process(samples, reset:)
          reset = reset[0...samples.length] if reset.length > samples.length
          @smoother.process(real(samples), nil, reset.ne(0).where.to_a)
        end

        def to_s
          "Smooth(#{@length.inspect}#{", curve: #{@curve}" if @curve})"
        end

        private

        def real(samples)
          raise ArgumentError, 'smooth takes real signals only' if samples.is_a?(Numo::DComplex) || samples.is_a?(Numo::SComplex)

          samples
        end
      end
    end
  end
end
