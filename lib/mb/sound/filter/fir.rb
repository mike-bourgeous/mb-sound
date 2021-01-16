module MB
  module Sound
    class Filter
      class FIR < Filter
        def initialize(gains, samples: nil, rate: 48000)
          @samples = samples
          @rate = rate

          case gains
          when Hash
            set_from_hash(gains)

          when Numo::NArray
            set_from_narray(gains)

          else
            raise "Gains must be a Numo::NArray or a Hash mapping frequencies in Hz to linear gains (which may be complex)" unless gains.is_a?(Hash)
          end
        end

        def set_from_hash(gain_map)
          raise "Gain map must contain at least two elements" if gain_map.length < 2

          # Find the smallest difference between subsequent frequencies and
          # validate types of frequencies and gains
          mindiff, _ = gain_map.each_with_object([nil, nil]) { |(freq, gain), state|
            mindiff = state[0]
            prior = state[1]

            freq = freq.frequency if freq.is_a?(Tone)

            raise "Frequencies must be Numeric (got #{freq.class.name})" unless freq.is_a?(Numeric)
            raise "Frequency #{freq} must be real" if freq.imag != 0
            raise "Frequency #{freq} must be non-negative" if freq < 0

            raise "Gains must be numeric (got #{gain.class.name} for #{freq})" unless gain.is_a?(Numeric)

            diff = freq - prior if prior
            puts "Diff from #{prior.inspect} to #{freq.inspect} is #{diff.inspect}"
            puts "Previous diff was #{mindiff.inspect}"
            raise "Frequencies must be in ascending order" unless diff.nil? || diff > 0

            mindiff = diff if mindiff.nil? || diff < mindiff

            state[0] = mindiff
            state[1] = freq
          }

          puts "Mindiff is #{mindiff}"

          filter_length = @rate / mindiff
          puts "Filter length chosen is #{filter_length}"

          raise NotImplementedError

          set_from_narray(filter)
        end

        def set_from_narray(gains)
          raise NotImplementedError
        end
      end
    end
  end
end
