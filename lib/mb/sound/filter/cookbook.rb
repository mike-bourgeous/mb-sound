require 'forwardable'

module MB
  module Sound
    class Filter
      # Implements a filter based on Robert Bristow-Johnson's Audio EQ Cookbook
      # formulae.
      #
      # See https://shepazu.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html
      # Or see https://webaudio.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html
      class Cookbook < Biquad
        # Wrapper around a cookbook filter that uses separate :sample or
        # numeric sources for audio input, cutoff frequency, and filter
        # quality.
        #
        # TODO: This might be mergeable with SampleWrapper or otherwise useful
        # elsewhere, would be nice to be able to make higher-order butterworth
        # filters or first-order filters available, for example
        #
        # TODO: support an audio or MIDI source for filter gain
        # TODO: merge with SampleWrapper now that SampleWrapper supports dynamic_process
        class CookbookWrapper
          extend Forwardable
          include GraphNode
          include GraphNode::SampleRateHelper

          # These return the most recent response, cutoff, quality, etc. from
          # the underlying filter.
          def_delegators :@base_filter, :response, :cutoff, :quality, :omega, :filter_type

          attr_reader :base_filter

          # Initializes a sample-chain wrapper around a cookbook filter that
          # uses Cookbook#dynamic_process to vary the cutoff frequency
          # and quality gradually over time.  Each parameter should have a
          # :sample method that returns an array of audio.
          def initialize(filter:, audio:, cutoff:, quality: 0.5 ** 0.5, in_place: false)
            raise 'Filter must have a #dynamic_process method' unless filter.respond_to?(:dynamic_process)
            @base_filter = filter

            @node_type_name = "Cookbook (#{@base_filter.filter_type})"

            @sample_rate = filter.sample_rate
            @sample_rate ||= audio.sample_rate if audio.respond_to?(:sample_rate)
            @sample_rate ||= cutoff.sample_rate if cutoff.respond_to?(:sample_rate)
            @sample_rate ||= quality.sample_rate if quality.respond_to?(:sample_rate)

            @audio = SampleWrapper.sample_or_narray(audio, filter: @base_filter, field: :audio, sample_rate: @sample_rate)
            @cutoff = SampleWrapper.sample_or_narray(cutoff, filter: @base_filter, field: :cutoff, sample_rate: @sample_rate)
            @quality = SampleWrapper.sample_or_narray(quality, filter: @base_filter, field: :quality, sample_rate: @sample_rate)

            @cutoff = @cutoff.or_for(nil) if @cutoff.respond_to?(:@or_for)
            @quality = @quality.or_for(nil) if @quality.respond_to?(:@or_for)

            @in_place = in_place
          end

          # Processes +count+ samples from the audio source through the filter,
          # using the cutoff and quality sources to control filter parameters.
          def sample(count)
            audio = @audio.sample(count)
            cutoff = @cutoff.sample(count)
            quality = @quality.sample(count)

            return nil if audio.nil? || cutoff.nil? || quality.nil? || audio.empty? || cutoff.empty? || quality.empty?

            audio = audio.real if audio.is_a?(Numo::SComplex) || audio.is_a?(Numo::DComplex)

            min_length = [audio.length, cutoff.length, quality.length].min
            audio = audio[0...min_length]
            cutoff = cutoff[0...min_length]
            quality = quality[0...min_length]

            audio.inplace! if @in_place

            @base_filter.dynamic_process(audio, cutoff: cutoff, quality: quality).not_inplace!
          end

          # See GraphNode#sources.
          def sources
            {
              input: @audio,
              cutoff: @cutoff,
              quality: @quality,
            }
          end

          # Changes the sample rate of the filter and any upstream sources.
          def sample_rate=(new_rate)
            super
            @base_filter.sample_rate = new_rate
            self
          end
          alias at_rate sample_rate=

          # See GraphNode#to_s
          def to_s
            s = "#{super} -- type: #{@base_filter.filter_type} #{source_names.join(', ')}"
            s << " gain: #{@base_filter.db_gain}dB" if @base_filter.db_gain
            s << " slope: #{@base_filter.shelf_slope}" if @base_filter.shelf_slope
            s
          end

          # See GraphNode#to_s_graphviz
          def to_s_graphviz
            s = <<~EOF
            #{super}---------------
            type: #{@base_filter.filter_type}
            #{source_names.join("\n")}
            EOF

            s << "gain: #{@base_filter.db_gain}dB\n" if @base_filter.db_gain
            s << "slope: #{@base_filter.shelf_slope}\n" if @base_filter.shelf_slope

            s
          end

          private

        end

        # These must match the order in `enum filter_types` in
        # ext/mb/fast_sound/fast_sound.c
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

        # Information like units, SI formatting, etc. about extra parameters to
        # #dynamic_process, used by SampleWrapper.sample_or_narray.
        DYNAMIC_INPUTS = {
          cutoff: { si: true, unit: 'Hz', range: ->(filter) { 0..(filter.sample_rate * 0.49) } },
          quality: { si: false, unit: ' Q', range: 0..100 },
        }.freeze

        attr_reader :filter_type, :sample_rate, :center_frequency, :omega, :db_gain
        attr_reader :cutoff, :quality, :bandwidth_oct, :shelf_slope

        # Initializes a filter based on Robert Bristow-Johnson's filter cookbook.
        # +filter_type+ is one of :lowpass, :highpass, :bandpass (peak at db_gain or 0dB),
        # :notch, :allpass, :peak, :lowshelf, or :highshelf.
        #
        # The +:shelf_slope+ should be 1.0 to have maximum slope without
        # overshoot.  See comments on https://www.musicdsp.org/en/latest/Filters/197-rbj-audio-eq-cookbook.html
        def initialize(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          set_parameters(filter_type, f_samp, f_center, db_gain: db_gain, quality: quality, bandwidth_oct: bandwidth_oct, shelf_slope: shelf_slope)
          super(@b0, @b1, @b2, @a1, @a2, sample_rate: f_samp)
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

        # Sets the bandwidth in octaves of the filter, if this is a peaking or
        # bandpass filter.
        def bandwidth_oct=(oct)
          return if @bandwidth_oct&.round(3) == oct.round(3)
          set_parameters(@filter_type, @sample_rate, @center_frequency, db_gain: @db_gain, bandwidth_oct: oct)
        end
        alias width= bandwidth_oct=

        # Sets the shelf slope in dB/octave of the filter, if this is a
        # shelving filter.
        def shelf_slope=(dboct)
          return if @shelf_slope&.round(3) == dboct.round(3)
          set_parameters(@filter_type, @sample_rate, @center_frequency, db_gain: @db_gain, shelf_slope: dboct)
        end

        # Sets the sample rate of the filter.
        def sample_rate=(rate)
          return if @sample_rate.round(3) == rate.round(3)
          @center_frequency = 0.5 * rate if @center_frequency > 0.5 * rate
          @cutoff = @center_frequency
          set_parameters(@filter_type, rate, @center_frequency, db_gain: @db_gain, quality: @quality, bandwidth_oct: @bandwidth_oct, shelf_slope: @shelf_slope)
          self
        end
        alias at_rate sample_rate=

        # Sets the filter type.
        def filter_type=(type)
          return if @filter_type == type
          set_parameters(type, @sample_rate, @center_frequency, db_gain: @db_gain, quality: @quality, bandwidth_oct: @bandwidth_oct, shelf_slope: @shelf_slope)
        end

        def set_parameters(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          set_parameters_c(filter_type, f_samp, f_center, db_gain: db_gain, quality: quality, bandwidth_oct: bandwidth_oct, shelf_slope: shelf_slope)
          self
        end

        def set_parameters_c(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          raise ArgumentError, "Invalid filter type #{filter_type.inspect}" unless FILTER_TYPE_IDS.include?(filter_type)
          type_id = FILTER_TYPE_IDS.fetch(filter_type)
          @filter_type = filter_type
          @sample_rate = f_samp
          @f0_max = 0.49 * @sample_rate
          f_center = 1e-10 if f_center < 1e-10 || !f_center.finite?
          f_center = @f0_max if f_center > @f0_max
          @center_frequency = f_center
          @cutoff = @center_frequency
          @db_gain = db_gain
          @amp = 10.0 ** (db_gain / 40.0) if db_gain

          quality = 1e-10 if quality && quality < 1e-10
          @quality = quality
          @bandwidth_oct = bandwidth_oct
          @shelf_slope = shelf_slope

          @omega, @b0, @b1, @b2, @a1, @a2 = MB::FastSound.cookbook(
            type_id, f_samp, f_center,
            db_gain, quality, bandwidth_oct, shelf_slope
          )

          calc_quality
        end

        # Recalculates filter coefficients based on the given filter parameters.
        def set_parameters_ruby(filter_type, f_samp, f_center, db_gain: nil, quality: nil, bandwidth_oct: nil, shelf_slope: nil)
          raise ArgumentError, "Invalid filter type #{filter_type.inspect}" unless FILTER_TYPE_IDS.include?(filter_type)
          @filter_type = filter_type

          @sample_rate = f_samp
          @f0_max = 0.49 * @sample_rate
          f_center = 1e-10 if f_center < 1e-10 || !f_center.finite?
          f_center = @f0_max if f_center > @f0_max
          @center_frequency = f_center
          @cutoff = @center_frequency
          @db_gain = db_gain

          amp = 10.0 ** (db_gain / 40.0) if db_gain
          linear_gain = db_gain&.db || 1.0
          omega = 2.0 * Math::PI * f_center / f_samp
          @amp = amp
          @omega = omega

          cosine = Math.cos(omega)
          sine = Math.sin(omega)

          if quality
            quality = 1e-10 if quality < 1e-10
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
            @b0 = alpha * a0_inv * linear_gain
            @b1 = 0
            @b2 = -alpha * a0_inv * linear_gain

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

          calc_quality
        end

        # Updates @quality/@bandwidth_oct/@shelf_slope from each other
        private def calc_quality
          if @shelf_slope
            # "solve s/(2*q)=s*0.5*sqrt((a+1/a)*(1/l-1)+2) for q"
            @quality = 1.0 / Math.sqrt((@amp + 1.0 / @amp) * (1.0 / @shelf_slope - 1) + 2)
            @bandwidth_oct = 2 * Math.sin(@omega) * Math.asinh(0.5 / @quality) / (@omega * Math.log(2.0))
          elsif @bandwidth_oct
            # WolframAlpha "solve s/(2*q)=s*sinh(ln(2)/2*b*o/s) for q"
            @quality = 0.5 / Math.sinh(bandwidth_oct * @omega * Math.log(2.0) / (2 * Math.sin(@omega)))
          elsif @quality
            # "solve s/(2*q)=s*sinh(ln(2)/2*b*o/s) for b"
            @bandwidth_oct = 2 * Math.sin(@omega) * Math.asinh(0.5 / @quality) / (@omega * Math.log(2.0))

            # "solve s/(2*q)=s*0.5*sqrt((a+1/a)*(1/l-1)+2) for l"
            if @amp
              a2 = @amp * @amp
              q2 = @quality * @quality
              @shelf_slope = (a2 * q2 + q2) / (a2 * q2 - 2 * @amp * q2 + @amp + q2)
            end
          end
        end

        # Processes just like Biquad#process but changes the cutoff frequency
        # and quality to the values given for each sample processed.  Only
        # works with real data, not complex, and will perform best (no
        # duplication of data) with SFloat.
        def dynamic_process(samples, cutoff:, quality:)
          dynamic_process_c(samples, cutoff: cutoff, quality: quality)
        end

        def dynamic_process_c(samples, cutoff:, quality:)
          coeffs = [@omega, @b0, @b1, @b2, @a1, @a2]
          state = [@x1, @x2, @y1, @y2]

          result = MB::FastSound.dynamic_biquad(
            samples,
            cutoff,
            quality,
            FILTER_TYPE_IDS.fetch(filter_type),
            @sample_rate,
            @db_gain,
            coeffs,
            state
          )

          @omega, @b0, @b1, @b2, @a1, @a2 = coeffs
          @x1, @x2, @y1, @y2 = state

          @quality = quality[-1]
          @quality = 1e-10 if @quality < 1e-10

          f0 = cutoff[-1]
          f0 = 1e-10 if f0 < 1e-10 || !f0.finite?
          f0 = @f0_max if f0 > @f0_max
          @center_frequency = f0
          @cutoff = @center_frequency

          result
        end

        def dynamic_process_ruby_c(samples, cutoff:, quality:)
          y1 = @y1
          y2 = @y2
          x1 = @x1
          x2 = @x2

          samples.map_with_index { |x0, idx|
            set_parameters(@filter_type, @sample_rate, cutoff[idx], db_gain: @db_gain, quality: quality[idx])
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
