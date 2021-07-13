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
    # complex waveform from MB::Sound::Oscillator.
    class ComplexPan
      # Constant to pass to #initialize for -3dB pan law.
      DB_3 = 0.5 ** 0.5

      # Constant to pass to #initialize for -4.5dB pan law.
      DB_45 = 0.5 ** 0.75

      # Constant to pass to #initialize for -6dB pan law.
      DB_6 = 0.5

      attr_accessor :pan, :phase
      attr_reader :pan_power

      # Initializes a ComplexPan, defaulting to center-panned and in-phase
      # output.  The +:center_gain+ parameter controls the panning gain curve
      # (see the class description).
      def initialize(center_gain: DB_45)
        self.center_pan = center_pan
        @pan = 0.0
        @phase = 0.0

        @pan_s = 0.0
        @phase_s = 0.0
      end

      # Changes the pan gain "law" that affects the volume curve of the two
      # channels.  Sets the +center_gain+ when pan is 0 to the given value,
      # with the curve between full-left and full-right adjusting accordingly.
      def center_gain=(center_gain)
        @center_gain = center_gain
        @pan_power = Math.log(@center_gain) / Math.log(0.5)
      end

      # Pans and rotates the given +data+ and returns [l, r] based on the
      # current settings for :pan and :phase.
      def process(data)
        MB::M.with_inplace(data, false) do |d|
          # TODO: smooth pan and phase per-sample with a LinearFollower and/or low-pass filter
          pan = @pan
          phase = @phase

          lgain, rgain = ComplexPan.gains(pan, phase, @pan_power)
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
