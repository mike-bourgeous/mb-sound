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
        class CookbookWrapper
          extend Forwardable
          include GraphNode
          include GraphNode::SampleRateHelper

          class WrapperArgumentError < ArgumentError
            def initialize(msg = nil, source: nil)
              msg ||= 'Pass a Numeric, a Numo::NArray, or a non-Array object that responds to :sample, such as Tone, Oscillator, or IOInput'
              msg << "(got #{source})" if source
              super(msg)
            end
          end

          # These return the most recent response, cutoff, quality, etc. from
          # the underlying filter.
          def_delegators :@base_filter, :sample_rate, :response, :cutoff, :quality, :omega, :filter_type

          attr_reader :base_filter

          # Initializes a sample-chain wrapper around a cookbook filter that
          # uses Cookbook#dynamic_process to vary the cutoff frequency
          # and quality gradually over time.  Each parameter should have a
          # :sample method that returns an array of audio.
          def initialize(filter:, audio:, cutoff:, quality: 0.5 ** 0.5, in_place: false)
            raise 'Filter must have a #dynamic_process method' unless filter.respond_to?(:dynamic_process)
            @base_filter = filter

            @node_type_name = "Cookbook (#{@base_filter.filter_type})"

            @audio = sample_or_narray(audio, si: false, unit: nil, range: -2..2)
            @cutoff = sample_or_narray(cutoff, si: true, unit: 'Hz', range: 0..(filter.sample_rate * 0.5))
            @quality = sample_or_narray(quality, si: false, unit: ' Q', range: 0..100)

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

            @base_filter.dynamic_process(audio, cutoff, quality).not_inplace!
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

          # If given an object with :sample, returns the object itself.  If
          # given a numeric value, returns an object with a :sample method that
          # returns that value as a constant indefinitely.  If given a
          # Numo::NArray, returns an ArrayInput that wraps it, without looping.
          # Otherwise, raises an error.
          def sample_or_narray(v, unit:, si:, range:)
            case v
            when Array
              raise WrapperArgumentError.new(source: v)

            when Numeric
              MB::Sound::GraphNode::Constant.new(v, sample_rate: @base_filter.sample_rate, unit: unit, si: si, range: range)

            when Numo::NArray
              MB::Sound::ArrayInput.new(data: [v], sample_rate: @base_filter.sample_rate)

            else
              if v.respond_to?(:sample)
                # TODO: Might need a better way to detect sampleable audio
                # objects, as opposed to Ruby objects with a sample method that
                # returns a random sampling.  Or maybe I should rename all of
                # my sample methods to something else.
                v.get_sampler
              else
                raise WrapperArgumentError.new(source: v)
              end
            end
          end
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

        attr_reader :filter_type, :sample_rate, :center_frequency, :omega, :db_gain
        attr_reader :cutoff, :quality, :bandwidth_oct, :shelf_slope

        # Initializes a filter based on Robert Bristow-Johnson's filter cookbook.
        # +filter_type+ is one of :lowpass, :highpass, :bandpass (0dB peak),
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

          quality = 1e-10 if quality && quality < 1e-10
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
          omega = 2.0 * Math::PI * f_center / f_samp
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
          coeffs = [@omega, @b0, @b1, @b2, @a1, @a2]
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

          @omega, @b0, @b1, @b2, @a1, @a2 = coeffs
          @x1, @x2, @y1, @y2 = state

          @quality = qualities[-1]
          @quality = 1e-10 if @quality < 1e-10

          f0 = cutoffs[-1]
          f0 = 1e-10 if f0 < 1e-10 || !f0.finite?
          f0 = @f0_max if f0 > @f0_max
          @center_frequency = f0
          @cutoff = @center_frequency

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
