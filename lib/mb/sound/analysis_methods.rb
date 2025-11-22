module MB
  module Sound
    # Methods related to analyzing sound signals to find things like
    # cross-correlation, peak autocorrelation/estimated frequency, etc.
    module AnalysisMethods
      # Returns the cross correlation array of the two given arrays using
      # FFT-based convolution.
      #
      # The middle value of the output is the zero-shift correlation amount,
      # values to the left are negative shifts, and values to the right are
      # positive shifts.
      def crosscorrelate(a, b)
        Numo::Pocketfft.fftconvolve(Numo::NArray.cast(a), Numo::NArray.cast(b).reverse.conj)
      end

      # Returns the shift of b relative to a that yields the highest
      # cross-correlation value from #crosscorrelate.
      #
      # In other words, for a periodic signal, MB::M.ror(b, peak_correlation(a,
      # b)) will be the closest rotation to approximating a.
      def peak_correlation(a, b)
        v = crosscorrelate(a, b)
        v.max_index - v.length / 2
      end

      # Returns the positive-time-shift section of the cross-correlation of
      # +data+ with itself.
      def autocorrelate(data)
        q = crosscorrelate(data, data)
        mid = q.length / 2
        q[mid..]
      end

      # Returns an estimate in Hz of the fundamental frequency of the given
      # audio +data+.  If +:range+ is a Range, then the peak frequency within
      # that range will be returned.
      def freq_estimate(data, sample_rate: 48000, range: nil, cepstrum: false)
        data = data.sample(48000) if data.is_a?(GraphNode)

        # TODO: decide what method(s) to use.  autocorrelation gives better
        # values for some files (e.g. sounds/piano0.flac), while cepstrum gives
        # better values for others (e.g. sounds/transient_synth.flac).
        #
        # Why does the cepstrum return very bad estimates for
        # piano_120hz_b2.flac while the plot looks very good?
        if cepstrum
          q = ifft(fft(data).map { |v| Math.log(v.abs) }).abs
          #q = ifft(fft(data).map { |v| CMath.log(v ** 2) }).real
          mid = q.length / 2
          q = q[0...mid]
          q[0] = 0
        else
          q = autocorrelate(data)
        end

        plist = peaks(q, 2)
          .reject { |idx, v, sign| sign == -1 || idx == 0 }
          .sort_by { |idx, v, sign| -v }

        plist = plist.select { |idx, _, _| range.cover?(sample_rate / idx.to_f) } if range

        idx = plist[0]&.[](0)

        idx ? sample_rate / idx.to_f : nil
      end

      # Finds all points in the given +narray+ that are larger or smaller than
      # at least +min_distance+ of their neighbors on either side.
      def peaks(narray, min_distance)
        peaks = []
        narray = narray.abs if narray[0].is_a?(Complex)
        narray.each_with_index do |v, idx|
          neighbors = fetch_oob(narray, (idx - min_distance)..(idx + min_distance))

          if neighbors.all? { |n| n == v }
            next
          elsif neighbors.all? { |n| n <= v }
            peaks << [idx, v, 1]
          elsif neighbors.all? { |n| n >= v }
            peaks << [idx, v, -1]
          end
        end
        peaks
      end

      # Retrieves the value at +idx+ from the given +array+.  If +idx+ is below the
      # array start (i.e. less than 0), returns +before+ if not nil, or the first
      # array value if +before+ is nil.  Likewise, if +idx+ is above the array end
      # (i.e. greater than array.size - 1), +after+ will be returned if +after+ is
      # not nil, or the last array value if +after+ is nil.
      #
      # If +idx+ is a Range, then each index value covered by the Range will be
      # handled as if passed individually to this function.  Reverse ranges as
      # passed to the normal array lookup (e.g. 1..-1) will return an empty array.
      def fetch_oob(array, idx, before: nil, after: nil)
        # TODO: rename to fetch_clamp and split out fetch_fill?
        # TODO: move to mb-math or something
        case idx
        when Range
          idx.map { |n| fetch_oob(array, n, before: before, after: after) }

        else
          if idx < 0
            before || array[0]
          elsif idx >= array.size
            after || array[array.size - 1]
          else
            array[idx]
          end
        end
      end
    end
  end
end
