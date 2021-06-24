module MB
  module Sound
    # Methods for generating noise with different spectral characteristics.
    module Noise
      # TODO: Remember why a separate Random instance was used here, and make a
      # better way to set the seed for reproducibility.
      RAND = ENV['RANDOM_SEED'] ? Random.new(ENV['RANDOM_SEED'].to_i) : Random.new

      # Returns the given number of (positive plus zero) bins of frequency
      # domain white noise.  For example, to generate 4800 time domain samples,
      # use 2401 bins.  The gain will be set so that clipping in the time
      # domain is unlikely, but not absolutely impossible.  This is probably
      # not the ideal way of generating white noise.  The noise will have a
      # normal/Gaussian distribution when converted to the time domain.
      def self.spectral_white_noise(bins)
        # The gain value was determined empirically using white_noise_gain_experiment.rb.
        # There's probably a statistical way to derive a true value.
        gain = 0.25 / Math.sqrt(bins)
        Numo::DComplex.zeros(bins).inplace!.map { |_|
          Complex.polar(gain, RAND.rand(2.0 * Math::PI))
        }.not_inplace!
      end

      # Returns the given number of (positive plus zero) bins of frequency
      # domain pink noise.  For example, to generate 4800 time domain samples,
      # use 2401 bins.  The gain will be set based on the number of bins so
      # that clipping in the time domain is unlikely, but not impossible.  The
      # time domain noise will have a normal distribution.
      #
      # Low frequency extension improves with more bins.  For example, at a
      # sample rate of 48000Hz, the noise spectrum will be white instead of pink
      # below ~200Hz with 121 bins.  To extend to 20Hz, use 2401 bins at 48kHz.
      def self.spectral_pink_noise(bins)
        # The gain value was determined empirically using pink_noise_gain_experiment.rb.
        gain = 0.185 / (bins ** 0.095)
        Numo::DComplex.zeros(bins).inplace!.map_with_index { |_, idx|
          # This is sqrt(idx) because pink noise is 1/f power, we are dealing
          # with amplitude and not power, and power is amplitude squared.
          div = idx > 0 ? Math.sqrt(idx) : 1
          amp = gain / div
          Complex.polar(amp, RAND.rand(2.0 * Math::PI))
        }.not_inplace!
      end

      # Returns the given number of (positive plus zero) bins of frequency
      # domain brown noise.  There will be occasional clicks at block edges, so
      # use overlapping windows when synthesizing multiple blocks of brown
      # noise.
      #
      # Low frequency extension improves with more bins.  For example, at a
      # sample rate of 48000Hz, the noise spectrum will be white instead of pink
      # below ~200Hz with 121 bins.  To extend to 20Hz, use 2401 bins at 48kHz.
      def self.spectral_brown_noise(bins)
        # Gain set empirically with brown_noise_gain_experiment.rb and checking
        # test files in Audacity.
        gain = 0.28
        Numo::DComplex.zeros(bins).inplace!.map_with_index { |_, idx|
          div = idx > 0 ? idx : 1
          amp = gain / div
          Complex.polar(amp, RAND.rand(2.0 * Math::PI))
        }.not_inplace!
      end

      # Generates frequency domain noise with a controllable slope.  Normalizes
      # total energy as slope changes, but does not try to manage time domain
      # amplitude, so clipping may occur when converting to the time domain.
      #
      # If +buffer+ is given, then the noise will be generated in-place using
      # that buffer, avoiding allocating a new buffer.
      #
      # See bin/play_noise.rb for an example.
      def self.spectral_power_noise(bins, db_per_octave, linear_gain, buffer: nil)
        buffer ||= Numo::DComplex.zeros(bins)
        raise "Buffer length must equal the number of bins: #{bins}" unless buffer.length == bins

        gain = 1.0 / bins

        power = -Math.log2(db_per_octave.db)

        amp_sum = 0
        noise = buffer.inplace!.map_with_index { |_, idx|
          div = idx > 0 ? idx ** power : 1
          amp = gain / div
          amp_sum += amp
          Complex.polar(amp, RAND.rand(2.0 * Math::PI))
        }

        noise *= linear_gain / amp_sum

        noise.not_inplace!
      end
    end
  end
end
