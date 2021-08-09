module MB
  module Sound
    class Filter
      # Implements a filter based on Robert Bristow-Johnson's Audio EQ Cookbook
      # formulae.
      #
      # See https://shepazu.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html
      class Cookbook < Biquad
        FILTER_TYPES = [
          :lowpass,
          :highpass,
          :bandpass,
          :notch,
          :allpass,
          :peak,
          :lowshelf,
          :highshelf,
        ]

        attr_reader :filter_type, :sample_rate, :center_frequency, :db_gain
        attr_reader :quality, :bandwidth_oct, :shelf_slope

        # Initializes a filter based on Robert Bristow-Johnson's filter cookbook.
        # +filter_type+ is one of :lowpass, :highpass, :bandpass (0dB peak),
        # :notch, :allpass, :peak, :lowshelf, or :highshelf.
        #
        # The +:shelf_slope+ should be 1.0 to have maximum slope without
        # overshoot.  See comments on https://www.musicdsp.org/en/latest/Filters/197-rbj-audio-eq-cookbook.html
        def initialize(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          set_parameters(filter_type, f_samp, f_center, db_gain: db_gain, quality: quality, bandwidth_oct: bandwidth_oct, shelf_slope: shelf_slope)
          super(@b0, @b1, @b2, @a1, @a2)
        end

        # Sets the center/cutoff frequency of the filter.
        def center_frequency=(freq)
          raise 'Frequency must be between 0 and sample_rate/2' if freq <= 0 || freq > @sample_rate * 0.5
          return if @center_frequency&.round(3) == freq.round(3)
          set_parameters(@filter_type, @sample_rate, freq, db_gain: @db_gain, quality: @quality, bandwidth_oct: @bandwidth_oct, shelf_slope: @shelf_slope)
        end

        # Sets the quality factor of the filter.
        def quality=(q)
          return if @quality&.round(3) == q.round(3)
          set_parameters(@filter_type, @sample_rate, @center_frequency, db_gain: @db_gain, quality: q)
        end

        # Sets the sample rate of the filter.
        def sample_rate=(rate)
          return if @sample_rate.round(3) == rate.round(3)
          set_parameters(@filter_type, rate, @center_frequency, db_gain: @db_gain, quality: @quality, bandwidth_oct: @bandwidth_oct, shelf_slope: @shelf_slope)
        end

        # Recalculates filter coefficients based on the given filter parameters.
        def set_parameters(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          @filter_type = filter_type
          @sample_rate = f_samp
          @center_frequency = f_center
          @db_gain = db_gain

          amp = 10.0 ** (db_gain / 40.0) if db_gain
          omega = 2.0 * Math::PI * f_center / f_samp
          x = Math.exp(-omega)

          cosine = Math.cos(omega)
          sine = Math.sin(omega)

          if quality
            @quality = quality
            @bandwidth_oct = nil
            @shelf_slope = nil
            alpha = sine / (2.0 * quality)
          elsif bandwidth_oct
            @bandwidth_oct = bandwidth_oct
            @quality = nil
            @shelf_slope = nil
            alpha = sine * Math.sinh(Math.log(2.0) / 2.0 * bandwidth_oct * omega / sine)
          elsif shelf_slope
            @shelf_slope = shelf_slope
            @quality = nil
            @bandwidth_oct = nil
            alpha = sine * 0.5 * Math.sqrt((amp + 1.0 / amp) * (1.0 / shelf_slope - 1) + 2)
          else
            raise "Missing quality/bandwidth_oct/shelf_slope"
          end

          case filter_type
          when :lowpass
            a0_inv = 1.0 / (1.0 + alpha)
            @a1 = -2.0 * cosine * a0_inv
            @a2 = (1.0 - alpha) * a0_inv
            @b0 = 0.5 * (1.0 - cosine) * a0_inv
            @b1 = (1.0 - cosine) * a0_inv
            @b2 = 0.5 * (1.0 - cosine) * a0_inv

          when :highpass
            a0_inv = 1.0 / (1.0 + alpha)
            @a1 = -2.0 * cosine * a0_inv
            @a2 = (1.0 - alpha) * a0_inv
            @b0 = 0.5 * (1.0 + cosine) * a0_inv
            @b1 = -(1.0 + cosine) * a0_inv
            @b2 = 0.5 * (1.0 + cosine) * a0_inv

          when :bandpass
            a0_inv = 1.0 / (1.0 + alpha)
            @a1 = -2.0 * cosine * a0_inv
            @a2 = (1.0 - alpha) * a0_inv
            @b0 = alpha * a0_inv
            @b1 = 0
            @b2 = -alpha * a0_inv

          when :notch
            a0_inv = 1.0 / (1.0 + alpha)
            @a1 = -2.0 * cosine * a0_inv
            @a2 = (1.0 - alpha) * a0_inv
            @b0 = a0_inv
            @b1 = -2.0 * cosine * a0_inv
            @b2 = a0_inv

          when :allpass
            a0_inv = 1.0 / (1.0 + alpha)
            @a1 = -2.0 * cosine * a0_inv
            @a2 = (1.0 - alpha) * a0_inv
            @b0 = (1.0 - alpha) * a0_inv
            @b1 = -2.0 * cosine * a0_inv
            @b2 = (1.0 + alpha) * a0_inv

          when :peak
            raise 'Missing db_gain' unless amp

            a0_inv = 1.0 / (1.0 + alpha / amp)
            @a1 = -2.0 * cosine * a0_inv
            @a2 = (1.0 - alpha / amp) * a0_inv
            @b0 = (1.0 + alpha * amp) * a0_inv
            @b1 = -2.0 * cosine * a0_inv
            @b2 = (1.0 - alpha * amp) * a0_inv

          when :lowshelf
            raise 'Missing db_gain' unless amp

            ap1 = amp + 1
            am1 = amp - 1
            asq2al = 2.0 * Math.sqrt(amp) * alpha

            a0_inv = 1.0 / (ap1 + am1 * cosine + asq2al)
            @a1 = -2.0 * (am1 + ap1 * cosine) * a0_inv
            @a2 = (ap1 + am1 * cosine - asq2al) * a0_inv
            @b0 = amp * (ap1 - am1 * cosine + asq2al) * a0_inv
            @b1 = 2.0 * amp * (am1 - ap1 * cosine) * a0_inv
            @b2 = amp * (ap1 - am1 * cosine - asq2al) * a0_inv

          when :highshelf
            raise 'Missing db_gain' unless amp

            ap1 = amp + 1
            am1 = amp - 1
            asq2al = 2.0 * Math.sqrt(amp) * alpha

            a0_inv = 1.0 / (ap1 - am1 * cosine + asq2al)
            @a1 = 2.0 * (am1 - ap1 * cosine) * a0_inv
            @a2 = (ap1 - am1 * cosine - asq2al) * a0_inv
            @b0 = amp * (ap1 + am1 * cosine + asq2al) * a0_inv
            @b1 = -2.0 * amp * (am1 + ap1 * cosine) * a0_inv
            @b2 = amp * (ap1 + am1 * cosine - asq2al) * a0_inv

          else
            raise "Invalid filter type #{filter_type.inspect}"
          end
        end

        # Processes just like Biquad#process but changes the cutoff frequency
        # and quality to the values given for each sample processed.
        def dynamic_process(samples, cutoffs, qualities)
          y1 = @y1
          y2 = @y2
          x1 = @x1
          x2 = @x2

          samples.map_with_index { |x0, idx|
            set_parameters(@filter_type, @sample_rate, cutoffs[idx], db_gain: @db_gain, quality: qualities[idx])
            out = @b0 * x0 + @b1 * x1 + @b2 * x2 - @a1 * y1 - @a2 * y2
            y2 = y1
            y1 = out
            x2 = x1
            x1 = x0
            out
          }.tap {
            @x1 = x1
            @x2 = x2
            @y1 = y1
            @y2 = y2
          }
        end
      end
    end
  end
end
