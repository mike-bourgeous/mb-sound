module MB
  module Sound
    # This class takes a single complex-valued input stream and produces two
    # output streams, one for left and one for right.
    #
    # The "pan" parameter controls relative left/right volume.  -1 is left, 1
    # is right, 0 is center.  The output gain curve for the left and right
    # channels is determined by a "pan law".  For -6dB pan law, the gain curve
    # is linear and both channels are at -6dB (0.5) when pan is 0.  For -3dB
    # pan law, the gain curve is quadratic and both channels are at -3dB
    # (0.707) when pan is 0.  -6dB is useful for signals that might be mixed
    # down to mono before reaching speakers.  -3dB is useful for uncorrelated
    # signals played over speakers in a room.  -4.5dB is a compromise between
    # the two, and is the default.
    #
    # The "phase" parameter rotates the two output streams in complex space
    # relative to each other, so a phase of 45.degrees means one channel is
    # rotated -22.5 degrees and the other is rotated +22.5 degrees.
    #
    # You can pass the output of MB::Sound::FFTMethods#analytic_signal or a
    # complex waveform from MB::Sound::Oscillator to the #process method to
    # generate a panned and phased result.
    #
    # Pan and phase values are smoothed to prevent clicks in the output.
    class ComplexPan
      # Constant to pass to #initialize for -3dB pan law.
      DB_3 = 0.5 ** 0.5

      # Constant to pass to #initialize for -4.5dB pan law.
      DB_45 = 0.5 ** 0.75

      # Constant to pass to #initialize for -6dB pan law.
      DB_6 = 0.5

      # The left-right pan (-1 to 1, 0 being center, -1 left, 1 right).
      attr_accessor :pan

      # The phase (0 to Math::PI).
      attr_accessor :phase

      # The exponent used to produce the center gain (0.5 for -3dB, 0.75 for
      # -4.5dB, 1 for -6dB).
      attr_reader :pan_power

      # Initializes a ComplexPan, defaulting to center-panned and in-phase
      # output.  The +:center_gain+ parameter controls the panning gain curve
      # (see the class description).
      #
      # The +:pan_hz+ and +:phase_hz+ parameters control filtering of pan and
      # phase values through LinearFollower and FirstOrder filters, preventing
      # clicks in the output when pan and phase are changed.
      def initialize(center_gain: DB_45, pan_hz: 30.0, phase_hz: 30.0)
        self.center_gain = center_gain
        @pan = 0.0
        @phase = 0.0

        @pan_filter = MB::Sound::Filter::FilterChain.new(
          pan_hz.hz.at(1).follower,
          pan_hz.hz.lowpass1p
        )
        @pan_buf = Numo::SFloat.zeros(800)

        @phase_filter = MB::Sound::Filter::FilterChain.new(
          phase_hz.hz.at(Math::PI / 2).follower,
          phase_hz.hz.lowpass1p
        )
        @phase_buf = Numo::SFloat.zeros(800)
      end

      # Changes the pan gain "law" that affects the volume curve of the two
      # channels.  Sets the +center_gain+ when pan is 0 to the given value,
      # with the curve between full-left and full-right adjusting accordingly.
      def center_gain=(center_gain)
        @center_gain = center_gain
        @pan_power = Math.log(@center_gain) / Math.log(0.5)
      end

      # Immediately set pan and phase values to their target values, skipping
      # any smoothing curve.  Call #pan= and/or #phase= first, then call this.
      def reset(pan: @pan, phase: @phase)
        @pan = pan
        @phase = phase
        @pan_filter.reset(@pan)
        @phase_filter.reset(@phase)
      end

      # Pans and rotates the given +data+ and returns [l, r] based on the
      # current settings for :pan and :phase.
      def process(data)
        if data.is_a?(Numeric)
          local_pan = @pan_filter.process([@pan])[0]
          local_phase = @phase_filter.process([@phase])[0]
        else
          @pan_buf = Numo::SFloat.zeros(data.length) if @pan_buf.length != data.length
          @phase_buf = Numo::SFloat.zeros(data.length) if @phase_buf.length != data.length

          @pan_buf.fill(@pan)
          @phase_buf.fill(@phase)

          local_pan = @pan_filter.process(@pan_buf.inplace).not_inplace!
          local_phase = @phase_filter.process(@phase_buf.inplace).not_inplace!
        end

        MB::M.with_inplace(data, false) do |d|
          lgain, rgain = ComplexPan.gains(local_pan, local_phase, @pan_power)
          return d * lgain, d * rgain
        end
      end

      # Calculates left and right channel gains, assuming complex-valued input,
      # for the given +pan+ (-1 to 1) and relative +phase+ (radians, with
      # Math::PI or 180.degrees being exactly out of phase).  The center gain
      # and gain curve is controlled by the +power+ parameter.  A +power+ of 1
      # is -6dB, and a +power+ of 0.5 is -3dB.
      def self.gains(pan, phase, power)
        # TODO: Maybe allow out-of-range pan values for "extra stereo"?
        r = MB::M.clamp(0.5 * pan + 0.5, 0, 1)
        l = 1.0 - r
        l **= power
        r **= power

        l *= Math::E ** (-phase * 0.5i)
        r *= Math::E ** (phase * 0.5i)

        return l, r
      end
    end
  end
end
