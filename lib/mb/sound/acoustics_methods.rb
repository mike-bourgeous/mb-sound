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

      # Returns a list of offsets with positive and negative peaks between zero
      # crossings.
      #
      # TODO: This probably belongs in a different class/module.
      def peak_list(data)
        return data.map { |c| peak_envelope(data) } if data.is_a?(Array)
        raise 'Data must be a 1D Numo::NArray' unless data.is_a?(Numo::NArray) && data.ndim == 1

        # { index: Integer, value: Float }
        peak_list = []

        prior_val = data[0]
        prior_max_val = data[0]
        prior_max_idx = 0
        max_val = data[0]
        max_idx = 0

        # TODO: include zero crossings in the list too?
        # TODO: maybe create a distortion/low-pass filter that interpolates
        # between peaks, or between peaks and zeros
        data.each_with_index do |v, idx|
          if (idx == 1 && (prior_val > 0 && v < 0) || (prior_val < 0 && v > 0)) || (idx > 1 && prior_val >= 0 != v >= 0)
            # Sign changed; record the last peak
            peak_list << { index: max_idx, value: max_val }
            prior_max_val = max_val
            prior_max_idx = max_idx
            max_idx = idx
            max_val = v
          end

          if v.abs > max_val.abs
            max_idx = idx
            max_val = v
          end

          prior_val = v
        end

        if max_idx != prior_max_idx && max_val != 0
          # Record the last peak
          peak_list << { index: max_idx, value: max_val }
        end

        peak_list
      end

      # Generates an envelope from the given +data+ by looking for peaks
      # between zero crossings and interpolating between them.
      def peak_envelope(data, include_negative: true)
        return data.map { |c| peak_envelope(data) } if data.is_a?(Array)
        raise 'Data must be a 1D Numo::NArray' unless data.is_a?(Numo::NArray) && data.ndim == 1

        peaks = peak_list(data)
        peaks.select! { |p| p[:value] > 0 } unless include_negative

        raise NotImplementedError, 'TODO'

        # TODO
        # include first data value if first peak is not at start
        # include last data value if last peak is not at end
        # if only two peaks, interpolate using smootherstep?
        # if three to four (six?) peaks, interpolate using ????
        # if four or more peaks (six or more?), interpolate using catmull-rom
      end
    end
  end
end
