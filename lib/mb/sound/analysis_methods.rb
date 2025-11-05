module MB
  module Sound
    # Methods related to analyzing sound signals to find things like
    # cross-correlation, peak autocorrelation/estimated frequency, etc.
    module AnalysisMethods
      # Returns the cross correlation array of the two given arrays using
      # convolution.
      def crosscorrelate(a, b)
        MB::M.convolve(a, b.reverse.conj)
      end

      def freq_estimate(a, sample_rate: 48000)
        q = crosscorrelate(a, a)
        mid = q.length / 2
        q = q[mid..]

        plist = peaks(q, 2)
          .reject { |idx, v, sign| sign == -1 || idx == 0 }
          .sort_by { |idx, v, sign| -v }

        idx = plist[0]&.[](0)

        # TODO: pick largest peak?  pick first peak?  return top N peaks? XXX
        # idx ? sample_rate / idx.to_f : 0
        plist[0..25].map { |idx, _, _| sample_rate / idx.to_f }
      end

      # Finds all points in the given narray that are larger or smaller than at
      # least +min_distance+ of their neighbors on either side.
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
