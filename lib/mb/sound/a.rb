module MB
  module Sound
    # Methods for shifting, modifying, etc. Numo::NArray
    module A
      # Appends +append+ to +array+, removing elements from the start of
      # +array+ so that its length remains the same.  Modifies +array+ in
      # place.  Returns the data that was shifted out.
      def self.append_shift(array, append)
        raise "Only 1D arrays supported" if array.ndim != 1 || append.ndim != 1

        return append if append.length == 0

        remainder = array.length - append.length

        case
        when remainder < 0
          raise "Cannot append more than the length of the original array"

        when remainder == 0
          leftover = array[0..-1].copy
          array[0..-1] = append

        else
          leftover = array[0...append.length].copy
          array[0...remainder] = array[-remainder..-1]
          array[remainder..-1] = append
        end

        leftover
      end

      # Returns a new array padded with the given +value+ (or +before+ before and
      # +after+ after) to provide a size of at least +min_length+.  Returns the
      # original array if it is already long enough.  The default value is zero if
      # not specified.
      #
      # Use 0 for +alignment+ to leave the original data at the start of the
      # resulting array, 1 to leave it at the end of the array, and something in
      # between to place it in the middle (e.g. 0.5 for centering the data).
      def self.pad(narray, min_length, value: nil, before: nil, after: nil, alignment: 0)
        return narray if narray.size >= min_length

        value ||= 0
        before ||= value
        after ||= value

        add = min_length - narray.size
        length_after = (add * (1.0 - alignment)).round
        length_before = add - length_after

        if length_before > 0
          narray_before = narray.class.new(length_before).fill(before)
          if narray.size > 0
            narray = narray_before.append(narray)
          else
            narray = narray_before
          end
        end

        if length_after > 0
          narray_after = narray.class.new(length_after).fill(after)
          if narray.size > 0
            narray = narray.append(narray_after)
          else
            narray = narray_after
          end
        end

        narray
      end

      # Returns a new array padded with zeros to provide a size of at least
      # +min_length+.  Returns the original array if it is already long enough.
      #
      # See #pad for +alignment+.
      def self.zpad(narray, min_length, alignment: 0)
        pad(narray, min_length, value: 0, alignment: alignment)
      end

      # Returns a new array padded with ones to provide a size of at least
      # +min_length+.  Returns the original array if it is already long enough.
      #
      # See #pad for +alignment+.
      def self.opad(narray, min_length, alignment: 0)
        pad(narray, min_length, value: 1, alignment: alignment)
      end

      # Rotates a 1D NArray left by +n+ places, which must be less than the
      # length of the NArray.  Returns the array unmodified if +n+ is zero.
      # Use negative values for +n+ to rotate right.
      def self.rol(array, n)
        return array if n == 0
        a, b = array.split([n])
        b.concatenate(a)
      end

      # Rotates a 1D NArray right by +n+ places (calls .rol(array, -n)).
      def self.ror(array, n)
        rol(array, -n)
      end

      # Removes the first +n+ entries of 1D +array+ and adds +n+ zeros at the
      # end.  Cannot shift right; use .shr for that.
      def self.shl(array, n)
        return array if n == 0 || array.size == 0
        return array.class.zeros(array.size) if array.size <= n
        array[n..-1].concatenate(array.class.zeros(n))
      end

      # Removes the last +n+ entries of 1D +array+ and adds +n+ zeros at the
      # start.  Cannot shift left; use .shl for that.
      def self.shr(array, n)
        return array if n == 0 || array.size == 0
        return array.class.zeros(array.size) if array.size <= n
        array.class.zeros(n).concatenate(array[0..-(n + 1)])
      end
    end
  end
end
