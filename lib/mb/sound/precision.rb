module MB
  module Sound
    # Whether sines and 2^x use fast approximations (fast-sine-1,
    # maintainer decision 2026-10-25: "I want to do more FM in the future,
    # so don't want to pay the performance penalty to use double precision
    # to match Ruby.  Have unplanned Ruby use the C fast sine by default
    # with an option for double precision.").
    #
    # :fast (the default): naive real sine Tones without noise use a
    # vectorized float polynomial (mb_vec_sine.h / mb_vec_sine_osc.h, Ruby
    # mirror Plan::VecSine; within about 5e-7 of the true sine, -126 dB, at
    # about a sixth of libm's cost), and note frequencies and powers of a
    # Constant or Knob base use a vectorized 2^x (mb_vec_exp2.h, Ruby mirror
    # Plan::VecExp2), in plans (Plan::Op::Tone, NoteFreq, Pow), in the
    # unfused C kernels (FastSound.oscillate, .number_to_freq,
    # FastArithmetic.power_fast), and in the Tone's Ruby path, so planned
    # and unplanned graphs give the same samples by construction.  The fast
    # shapes drift from exact math where a sine is integrated (an FM
    # modulator into a carrier's frequency: about -110 dB after a second,
    # -76 dB after a minute) or decides something (sample-hold edges,
    # decimator rates: a flip where the polynomial gives exactly 0).
    #
    # :exact (MB_SOUND_PRECISION=exact): libm everywhere, also in both
    # paths.  Set it before building graphs: plans read it when a region
    # compiles, unfused nodes on every buffer.
    module Precision
      PRECISIONS = [:fast, :exact].freeze

      class << self
        # :fast or :exact (see Precision).
        attr_reader :precision

        def precision=(value)
          raise ArgumentError, "Precision is :fast or :exact (got #{value.inspect})" unless PRECISIONS.include?(value)

          MB::FastSound.fast_math = value == :fast
          @precision = value
        end

        # True when precision is :fast.
        def fast?
          @precision == :fast
        end
      end

      self.precision = ENV['MB_SOUND_PRECISION'] == 'exact' ? :exact : :fast
    end

    class << self
      # :fast (the default) or :exact: see MB::Sound::Precision.
      def precision
        Precision.precision
      end

      # Sets MB::Sound.precision (see MB::Sound::Precision).
      def precision=(value)
        Precision.precision = value
      end
    end
  end
end
