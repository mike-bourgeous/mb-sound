module MB
  module Sound
    # Methods related to analyzing sound signals to find things like
    # cross-correlation, peak autocorrelation/estimated frequency,  
    module AnalysisMethods
      # Returns the cross correlation array of the two given arrays using
      # convolution.
      def crosscorrelate(a, b)
        MB::M.convolve(a, b.reverse.conj)
      end

      def freq_estimate(a, sample_rate: 48000)
        q = crosscorrelate(a, a).abs
        idx = q.max_index
        sample_rate / idx.to_f
      end
    end
  end
end
