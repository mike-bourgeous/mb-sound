module MB
  module Sound
    class Filter
      # A simple implementation of FIR filtering using the FFT to perform
      # convolution.  Filter parameters are specified either as a Hash from
      # frequency to gain values, or as a Numo::NArray with positive FFT
      # coefficients of the desired frequency response.
      #
      # If a Hash frequency/gain map is specified, a naive filter design
      # algorithm will determine filter size (this could be improved) and
      # generate an FIR filter, interpolating between the specified
      # frequencies.  If the Hash does not contain a value for 0Hz or for the
      # Nyquist frequency (half the sample rate), then the slope of the
      # adjacent frequency/gain values will be extrapolated to 0Hz and/or
      # Nyquist as needed.
      #
      # The current filter size selection algorithm will choose a filter size
      # based solely on the closest-spaced frequencies in the gain map.  This
      # may be improved in the future to take slope into account.
      #
      # TODO: Allow specifying a time-domain impulse response
      # TODO: Add getters to return the processing delay, total delay, and impulse delay
      #
      # Examples:
      #
      #     # Bass cut (added 200Hz so that extrapolated slope for Nyquist is flat)
      #     MB::Sound::Filter::FIR.new(gains: { 20 => -60.db, 100 => 0.db, 200 => 0.db)
      #
      #     # Phase rotation (the lower the frequencies and/or closer together, the
      #     # better the bass response)
      #     rotation = Complex.polar(1, Math::PI / 4)
      #     MB::Sound::Filter::FIR.new(gains: { 20 => rotation, 100 => rotation })
      class FIR < Filter
        attr_reader :filter_length, :window_length, :rate, :gain_map, :filter_fft, :gains, :impulse

        # The processing delay of the filter.  This delay allows the filter to
        # buffer incoming data into window-sized chunks while always returning
        # the same number of samples in the #process method.
        attr_reader :processing_delay

        # The impulse delay of the filter (the offset of the impulse's peak
        # sample).
        attr_reader :impulse_delay

        # The total delay of the filter in samples, including processing delay
        # and impulse phase delay.
        attr_reader :delay

        # Initializes an FIR filter with the given frequency +gains+.  The
        # +gains+ may either be a Hash mapping frequencies to gain values, or a
        # Numo::NArray with FFT-domain gain values starting from DC.
        #
        # The +:filter_length+, +:window_length+ (size of FFT, which must be
        # larger than the filter length and should be several times larger for
        # best performance), and sample +:rate+ may be overridden.
        #
        # The +:filter_length+ parameter is ignored if +gains+ is a
        # Numo::NArray.
        def initialize(gains, filter_length: nil, window_length: nil, rate: 48000)
          @filter_length = filter_length
          @window_length = window_length
          @rate = rate
          @nyquist = rate / 2.0

          case gains
          when Hash
            set_from_hash(gains)

          when Numo::NArray
            @gain_map = nil
            set_from_narray(gains)

          else
            raise "Gains must be a Numo::NArray or a Hash mapping frequencies in Hz to linear gains (which may be complex)" unless gains.is_a?(Hash)
          end
        end

        def process(data)
          data = Numo::NArray[data] if data.is_a?(Numeric)
          data = Numo::NArray.cast(data) if data.is_a?(Array)

          # FIXME: ugly and slow
          # Split the incoming buffer into two chunks if it would partially
          # overflow the input buffer
          new_count = @in_count + data.length
          if new_count > @in_max
            excess = new_count - @in_max
            first_chunk = data[0...-excess]
            second_chunk = data[-excess..-1]

            # TODO: create a single buffer and place the data into that buffer
            # iteratively instead of recursively concatenating
            return process(first_chunk).concatenate(process(second_chunk))
          end

          @in_count = append_to_buffer(@in, @in_count, @in_max, data)

          # If the input buffer is full, run another convolution
          if @in_count == @in_max
            fft = MB::Sound.real_fft(@in)
            fft.inplace * @filter_fft
            result = MB::Sound.real_ifft(fft)
            @in_count = 0

            # Append the result of the convolution to the output buffer
            start_overlap = @out_count - @filter_overlap
            start_overlap = 0 if start_overlap < 0
            end_overlap = start_overlap + @filter_overlap
            remaining = result.length - @filter_overlap
            @out[start_overlap...end_overlap] += result[0...@filter_overlap]
            @out[end_overlap...(end_overlap + remaining)] = result[@filter_overlap..-1]
            @out_count += remaining
          end

          # Remove and return data.length samples from the output buffer
          @out_count -= data.length
          raise "BUG: out_count dropped below 0" if @out_count < 0
          ret = @out[0...data.length].copy
          @out = MB::Sound::A.shl(@out, data.length) # TODO: Add an in-place shift instead of allocating a new array
          ret
        end

        # Resets all internal buffers to the given steady-state input value, so
        # the output is as if that value had been steady at the input for a
        # very long time.  Returns the steady-state output for the given input.
        def reset(value = 0)
          @in_count = 0
          @out_count = @window_length
          @in[0...@in_max].fill(value)
          @in[@in_max..-1].fill(0)

          @out[0...@processing_delay].fill((value * filter_fft[0]).real)
          @out[@processing_delay..-1].fill(0)

          start = @window_length / 2
          subset = @out[start...(start + @window_length)]
          fft = MB::Sound.real_fft(subset).inplace * @filter_fft / @filter_fft[0]
          result = MB::Sound.real_ifft(fft)
          @out[(start + @filter_length)...(start + @window_length - @filter_length)] = result[@filter_length...-@filter_length]

          @out[0]
        end

        # Returns the frequency response of the filter at the given angular
        # frequency, from 0 (DC) to Math::PI (Nyquist).
        #
        # FIXME: remove linear phase offset caused by t=N/2 delay
        def response(omega)
          if omega.is_a?(Numo::NArray)
            return Numo::DComplex.cast(omega).map { |v| response(v.real) }
          end

          omega = omega.real % (2.0 * Math::PI)
          clamped = omega > Math::PI ? 2.0 * Math::PI - omega : omega

          idxf = clamped * (filter_fft.length - 1) / Math::PI
          idx1 = idxf.floor
          idx2 = idxf.ceil
          delta = idxf - idx1

          v = filter_fft[idx1] * (1.0 - delta) + filter_fft[idx2] * delta
          v = v.conj if omega > Math::PI
          v
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

            [freq.to_f, gain.to_c]
          }.to_h

          # Find the smallest difference between subsequent frequencies to help
          # decide filter size (TODO there's probably a much better way)
          #
          # TODO: better filter size selection, better interpolation, probably
          # need to take slope into account when deciding filter size for better results
          mindiff, _ = gain_map.each_with_object([nil, nil]) { |(freq, gain), state|
            mindiff = state[0]
            prior = state[1]

            diff = freq - prior if prior
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

          # TODO: What needs to be done differently if an odd filter length is
          # given to the constructor?
          @filter_length ||= (@rate.to_f / mindiff / 2).ceil * 2
          hz_per_bin = @rate.to_f / @filter_length

          final_gain_map = {}

          # Extrapolate to 0Hz
          if gain_map.keys.first > 0
            if gain_map.keys.first <= 0.625
              final_gain_map[0] = gain_map.values.first
            elsif gain_map.values.first == 0
              final_gain_map[0] = 0
            else
              final_gain_map[0] = interp_gain(0, *gain_map.first(2))
            end
          end

          final_gain_map.merge!(gain_map)

          # Extrapolate to Nyquist
          if gain_map.keys.last < @nyquist
            if gain_map.keys.last >= (@nyquist - 1.0).floor
              final_gain_map[@nyquist] = gain_map.values.last
            elsif gain_map.values.last == 0
              final_gain_map[@nyquist] = 0
            else
              final_gain_map[@nyquist] = interp_gain(@nyquist, *gain_map.to_a.last(2))
            end
          end

          @gain_map = final_gain_map.sort_by(&:first)

          response = Numo::DComplex.zeros(@filter_length / 2 + 1)

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

          @gain_map = @gain_map.to_h.freeze

          set_from_narray(response)
        end

        def set_from_narray(gains)
          @gains = gains
          @impulse = MB::Sound.real_ifft(gains)

          # TODO: Do something about minimum phase, etc. so that impulse
          # doesn't have energy at the end?  Will this rol actually do the
          # wrong thing for some complex gain values?
          #
          # TODO: Allow using a window function to taper the ends of the
          # impulse response and specifying a shorter filter length than the
          # gains array or gain map would imply
          @impulse = MB::Sound::A.rol(@impulse, @impulse.length / 2)
          if @filter_length && @filter_length != @impulse.length
            puts "Specified filter length #{@filter_length} does not match impulse length #{@impulse.length}"
          end
          @filter_length = @impulse.length

          # Window length trades off between delay and efficiency
          min_length = 2 ** Math.log2(@filter_length * 3).ceil
          min_length = 128 if min_length < 128
          @window_length ||= min_length
          raise "Window length #{@window_length} is too short for filter length #{@filter_length}" unless @window_length > @filter_length

          @filter_overlap = @filter_length - 1
          @filter_fft = MB::Sound.real_fft(MB::Sound::A.zpad(@impulse, @window_length))

          # TODO: Understand why @filter_fft.length.to_f / @gains.length doesn't fully compensate for lost gain
          @filter_fft.inplace * (@gains[1..-2].abs.mean / @filter_fft[1..-2].abs.mean) # Compensate for padding

          @processing_delay = @window_length - @filter_overlap
          @impulse_delay = @impulse.abs.max_index
          @delay = @processing_delay + @impulse_delay

          # TODO: Allow complex output, like IIR filters
          @in = Numo::SFloat.zeros(@window_length)
          @in_max = @processing_delay
          @in_count = 0

          @out = Numo::SFloat.zeros(@window_length * 2)
          @out_count = @window_length
        end

        # TODO: Make a buffer class that can be linear, circular, overlap-add,
        # or whatever, and can call a processing callback when the buffer
        # reaches a set point?
        # Returns new buffer count
        def append_to_buffer(buffer, buffer_count, buffer_limit, data)
          new_count = buffer_count + data.length
          raise "Buffer is full" if new_count > buffer_limit
          buffer[buffer_count...(buffer_count + data.length)] = data
          new_count
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
