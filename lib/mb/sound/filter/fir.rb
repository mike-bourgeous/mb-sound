module MB
  module Sound
    class Filter
      class FIR < Filter
        attr_reader :filter_length

        def initialize(gains, filter_length: nil, window_length: nil, rate: 48000)
          @filter_length = filter_length
          @rate = rate
          @nyquist = rate / 2.0

          case gains
          when Hash
            set_from_hash(gains)

          when Numo::NArray
            set_from_narray(gains)

          else
            raise "Gains must be a Numo::NArray or a Hash mapping frequencies in Hz to linear gains (which may be complex)" unless gains.is_a?(Hash)
          end
        end

        def process(data)
          data = Numo::NArray[data] if data.is_a?(Numeric)
          A.append_shift(@buffer, data) # Wrong

          # If the input buffer is full, run another convolution
          # TODO

          # Append the result of the convolution to the output buffer
          # TODO

          # Remove and return data.length samples from the output buffer
        end

        private

        def set_from_hash(gain_map)
          raise "Gain map must contain at least two elements" if gain_map.length < 2

          gain_map = gain_map.map { |freq, gain|
            freq = freq.frequency if freq.is_a?(Tone)

            raise "Frequencies must be Numeric (got #{freq.class.name})" unless freq.is_a?(Numeric)
            raise "Frequency #{freq} must be real" if freq.imag != 0
            raise "Frequency #{freq} must be non-negative" if freq < 0
            raise "Frequency #{freq} must be less than or equal to half sample rate (#{@nyquist})" if freq > @nyquist

            raise "Gains must be numeric (got #{gain.class.name} for #{freq})" unless gain.is_a?(Numeric)

            [freq.to_f, gain.to_f]
          }.to_h

          # Find the smallest difference between subsequent frequencies to help
          # decide filter size (TODO there's probably a much better way)
          #
          # TODO: better filter size selection, better interpolation
          mindiff, _ = gain_map.each_with_object([nil, nil]) { |(freq, gain), state|
            mindiff = state[0]
            prior = state[1]

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

          @filter_length ||= (@rate.to_f / mindiff / 2).ceil * 2
          hz_per_bin = @rate.to_f / @filter_length
          puts "Filter length chosen is #{@filter_length} with #{hz_per_bin}Hz per bin"

          final_gain_map = {}

          # Extrapolate to 0Hz
          if !gain_map.include?(0)
            if gain_map.keys.first <= 0.625
              final_gain_map[0] = gain_map.first[1]
            elsif gain_map.values.first == 0
              final_gain_map[0] = 0
            else
              final_gain_map[0] = interp_gain(0, *gain_map.first(2)).real
            end
          end

          final_gain_map.merge!(gain_map)

          # Extrapolate to nyquist
          if !gain_map.include?(@nyquist)
            if gain_map.keys.last >= (@nyquist - 1.0).floor
              final_gain_map[@nyquist] = gain_map.values.last
            elsif gain_map.values.last == 0
              final_gain_map[@nyquist] = 0
            else
              final_gain_map[@nyquist] = interp_gain(@nyquist, *gain_map.to_a.last(2))
            end
          end

          @gain_map = final_gain_map.sort_by(&:first)

          response = Numo::DComplex.zeros(@filter_length / 2)

          g0 = @gain_map[0]
          g1 = @gain_map[1]
          gidx = 1
          response.inplace.map_with_index do |_, idx|
            hz = idx.to_f * @rate / @filter_length
            if hz > g1[0]
              g0 = g1
              gidx += 1
              g1 = @gain_map[gidx]
              raise "BUG: ran out of gains at hz=#{hz}, index #{gidx}, nyquist #{@nyquist}, final gain #{@gain_map.last}" unless g1
            end

            interp_gain(hz, g0, g1)
          end

          @gain_map = @gain_map.to_h

          set_from_narray(response)
        end

        def set_from_narray(gains)
          # TODO: pad size to convenient FFT size
          @gains = gains
          @impulse = MB::Sound.real_ifft(gains)

          @window_length ||= 2 ** Math.log2(@filter_length * 8).ceil
          raise "Window length #{@window_length} is too short for filter length #{@filter_length}" unless @window_length >= @filter_length

          # TODO: Allow complex output like IIR filters
          @buffer = Numo::SFloat.zeros(@window_length)
        end

        def interp_gain(f, f1g1, f2g2)
          # Octave -5 relative to 20Hz is 0.625Hz; use that as minimum frequency
          if f <= 0.625
            oct_f = -5
          else
            oct_f = Math.log2(f / 20.0)
          end

          oct1 = Math.log2(f1g1[0] / 20.0)
          oct1 = -100 if oct1 < -100
          oct2 = Math.log2(f2g2[0] / 20.0)
          oct2 = -100 if oct2 < -100
          oct_range = oct1..oct2

          db1 = f1g1[1].to_db
          db1 = -100 if db1 < -100
          db2 = f2g2[1].to_db
          db2 = -100 if db2 < -100

          # TODO: Better phase interpolation around the circle (e.g. +0.9PI and
          # -0.9PI should interpolate through +PI instead of 0)
          mag = MB::Sound::M.scale(oct_f, oct_range, db1..db2).db
          phase = MB::Sound::M.scale(oct_f, oct1..oct2, f1g1[1].arg..f2g2[1].arg)

          Complex.polar(mag, phase)
        end
      end
    end
  end
end
