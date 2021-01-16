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
          #
          # TODO: better filter size selection, better interpolation
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

            # FIXME: This is all ugly
            if mindiff.nil?
              mindiff = diff
              mindiff ||= freq if freq > 0
            else
              mindiff = freq if freq && freq > 0 && freq < mindiff
              mindiff = diff if diff && diff < mindiff
            end

            state[0] = mindiff
            state[1] = freq
          }

          puts "Mindiff is #{mindiff}"

          filter_length = (@rate.to_f / mindiff).ceil
          hz_per_bin = @rate.to_f / filter_length
          puts "Filter length chosen is #{filter_length} with #{hz_per_bin}Hz per bin"

          # Convert to logarithmic
          logmap = {}
          gain_map.each do |freq, gain|
            octave = Math.log2(freq / 20.0)
            octave = -5.0 if octave < -5.0
            phase = gain.arg
            gain = Complex.polar(gain.to_db, phase)

            # WRONG
          end

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
