module MB
  module Sound
    # Methods related to analyzing room acoustics, such as RT60
    module AcousticsMethods
      # Calculates the RT60 (reverberation time to -60dB), or decay time to the
      # given +:level+ (as a ratio with the peak) if given, from the highest
      # amplitude peak within the +data+ (a 1D Numo::NArray or a Ruby Array of
      # 1D Numo::NArray).  If +data+ is a Ruby Array, then the RT60 is
      # calculated for each Numo::NArray within the Array.
      #
      # The decay +:level+ may be anything from -inf to 1, exclusive, and
      # defaults to -60dB (0.001).  The sample +:rate+ defaults to 48000.
      #
      # Returns the number of seconds to reach the given ratio, or raises an
      # error if that level is never reached.
      def rt60(data, level: -60.dB, rate: 48000)
        return data.map { |c| rt60(c, level: level) } if data.is_a?(Array)
        raise 'Data must be a 1D Numo::NArray' unless data.is_a?(Numo::NArray) && data.ndim == 1

        # Some other ideas:
        # - find peak, then calculate a series of RT20, do the appropriate mean
        #   (geometric?  arithmetic probably), and convert to RT60

        # Convert to instantaneous magnitude form
        # FIXME: analytic_signal drastically changes the envelope
        # FIXME: e.g. analytic_signal(Numo::SFloat.logspace(0, -4, 48000) *
        # FIXME: 123.Hz.sample(48000)) ends with analytic signal around 0.2, not
        # FIXME: 0.0001.
        asig = analytic_signal(data).abs
        peak_idx = asig.max_index
        peak_val = asig[peak_idx]
        target_val = peak_val * level

        decay_val = peak_val
        asig[peak_idx..].each_with_index do |d, idx|
          decay_val = d
          return idx.to_f / rate if decay_val <= target_val
        end

        # TODO: derive an RT60 from whatever decay we do find?
        raise ArgumentError, "Signal never reaches #{level.to_db}; minimum is #{(decay_val / peak_val).to_db}"
      end
    end
  end
end
