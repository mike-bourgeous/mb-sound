module MB
  module Sound
    class Filter
      # Implements a filter based on Robert Bristow-Johnson's Audio EQ Cookbook
      # formulae.
      #
      # See https://shepazu.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html
      class Cookbook < Biquad
        # Wrapper around a cookbook filter that uses separate :sample or
        # numeric sources for audio input, cutoff frequency, and filter
        # quality.
        #
        # TODO: This might be mergeable with SampleWrapper or otherwise useful
        # elsewhere, would be nice to be able to make higher-order butterworth
        # filters or first-order filters available, for example
        class CookbookWrapper
          include ArithmeticMixin

          class WrapperArgumentError < ArgumentError
            def initialize(msg = nil, source: nil)
              msg ||= 'Pass a Numeric, a Numo::NArray, or a non-Array object that responds to :sample, such as Tone, Oscillator, or IOInput'
              msg << "(got #{source})" if source
              super(msg)
            end
          end

          attr_reader :audio, :cutoff, :quality

          # Initializes a sample-chain wrapper around a cookbook filter that
          # uses Cookbook#dynamic_process to vary the cutoff frequency
          # and quality gradually over time.  Each parameter should have a
          # :sample method that returns an array of audio.
          def initialize(filter:, audio:, cutoff:, quality: 0.5 ** 0.5)
            raise 'Filter must have a #dynamic_process method' unless filter.respond_to?(:dynamic_process)
            @filter = filter

            @audio = sample_or_narray(audio)
            @cutoff = sample_or_narray(cutoff)
            @quality = sample_or_narray(quality)

            @cutoff = @cutoff.or_for(nil) if @cutoff.respond_to?(:@cutoff)
            @quality = @quality.or_for(nil) if @quality.respond_to?(:@quality)
          end

          # Processes +count+ samples from the audio source through the filter,
          # using the cutoff and quality sources to control filter parameters.
          def sample(count, in_place: true)
            audio = @audio.sample(count)
            cutoff = @cutoff.sample(count)
            quality = @quality.sample(count)

            return nil if audio.nil? || cutoff.nil? || quality.nil? || audio.empty? || cutoff.empty? || quality.empty?

            audio.inplace! if in_place

            @filter.dynamic_process(audio, cutoff, quality).not_inplace!
          end

          # See ArithmeticMixin#sources.
          def sources
            [@audio, @cutoff, @quality]
          end

          private

          # If given an object with :sample, returns the object itself.  If
          # given a numeric value, returns an object with a :sample method that
          # returns that value as a constant indefinitely.  If given a
          # Numo::NArray, returns an ArrayInput that wraps it, without looping.
          # Otherwise, raises an error.
          def sample_or_narray(v)
            case v
            when Array
              raise WrapperArgumentError.new(source: v)

            when Numeric
              MB::Sound::Constant.new(v)

            when Numo::NArray
              MB::Sound::ArrayInput.new(data: [v])

            else
              if v.respond_to?(:sample)
                # TODO: Might need a better way to detect sampleable audio
                # objects, as opposed to Ruby objects with a sample method that
                # returns a random sampling.  Or maybe I should rename all of
                # my sample methods to something else.
                v
              else
                raise WrapperArgumentError.new(source: v)
              end
            end
          end
        end

        FILTER_TYPES = [
          :lowpass,
          :highpass,
          :bandpass,
          :notch,
          :allpass,
          :peak,
          :lowshelf,
          :highshelf,
        ].freeze

        FILTER_TYPE_IDS = FILTER_TYPES.map.with_index.to_h.freeze

        attr_reader :filter_type, :sample_rate, :center_frequency, :omega, :db_gain
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
          if freq <= 0 || freq > @sample_rate * 0.5
            raise "Frequency #{freq.inspect} must be between 0 and sample_rate/2 (#{@sample_rate * 0.5})"
          end

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
          @center_frequency = 0.5 * rate if @center_frequency > 0.5 * rate
          set_parameters(@filter_type, rate, @center_frequency, db_gain: @db_gain, quality: @quality, bandwidth_oct: @bandwidth_oct, shelf_slope: @shelf_slope)
        end

        # Sets the filter type.
        def filter_type=(type)
          raise "Invalid filter type #{type.inspect}" unless FILTER_TYPE_IDS.include?(type)
          return if @filter_type == type
          set_parameters(type, @sample_rate, @center_frequency, db_gain: @db_gain, quality: @quality, bandwidth_oct: @bandwidth_oct, shelf_slope: @shelf_slope)
        end

        def set_parameters(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          set_parameters_c(filter_type, f_samp, f_center, db_gain: db_gain, quality: quality, bandwidth_oct: bandwidth_oct, shelf_slope: shelf_slope)
        end

        def set_parameters_c(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          type_id = FILTER_TYPE_IDS.fetch(filter_type)
          @filter_type = filter_type
          @sample_rate = f_samp
          @center_frequency = f_center
          @db_gain = db_gain

          @quality = quality
          @bandwidth_oct = bandwidth_oct
          @shelf_slope = shelf_slope

          @omega, @b0, @b1, @b2, @a1, @a2 = MB::FastSound.cookbook(
            type_id, f_samp, f_center,
            db_gain, quality, bandwidth_oct, shelf_slope
          )
        end

        # Recalculates filter coefficients based on the given filter parameters.
        def set_parameters_ruby(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          @filter_type = filter_type
          @sample_rate = f_samp
          @center_frequency = f_center
          @db_gain = db_gain

          amp = 10.0 ** (db_gain / 40.0) if db_gain
          omega = 2.0 * Math::PI * f_center / f_samp
          @omega = omega

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
        # and quality to the values given for each sample processed.  Only
        # works with real data, not complex, and will perform best (no
        # duplication of data) with SFloat.
        def dynamic_process(samples, cutoffs, qualities)
          dynamic_process_c(samples, cutoffs, qualities)
        end

        def dynamic_process_c(samples, cutoffs, qualities)
          coeffs = self.coefficients
          state = [@x1, @x2, @y1, @y2]

          result = MB::FastSound.dynamic_biquad(
            samples,
            cutoffs,
            qualities,
            FILTER_TYPE_IDS.fetch(filter_type),
            @sample_rate,
            @db_gain,
            coeffs,
            state
          )

          @b0, @b1, @b2, @a1, @a2 = coeffs
          @x1, @x2, @y1, @y2 = state
          @quality = qualities[-1]
          @center_frequency = cutoffs[-1]

          result
        end

        def dynamic_process_ruby_c(samples, cutoffs, qualities)
          y1 = @y1
          y2 = @y2
          x1 = @x1
          x2 = @x2

          samples.map_with_index { |x0, idx|
            set_parameters(@filter_type, @sample_rate, cutoffs[idx], db_gain: @db_gain, quality: qualities[idx])
            out = MB::FastSound.biquad(@b0, @b1, @b2, @a1, @a2, x0, x1, x2, y1, y2)
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
