module MB
  module Sound
    class Filter
      # A linear trapezoidal state-variable filter (Andrew Simper's "Cytomic"
      # SVF, topology-preserving transform / zero-delay feedback) with the
      # RBJ cookbook responses: :lowpass, :highpass, :bandpass (0 dB peak),
      # :bandpass_skirt (constant skirt, peak gain Q), :notch, :allpass,
      # :peak, :lowshelf, :highshelf.  Cutoff, quality, and gain mean what
      # they mean for Filter::Cookbook, and static responses are the same
      # (both are the bilinear transform with the cutoff prewarped; they
      # differ only by rounding).
      #
      # The difference is in motion: its states are integrator states, not
      # past samples, so the cutoff, quality, and gain may change on any
      # sample without thumps (a direct form biquad whose cutoff dives
      # quickly toward 0 Hz gives a DC bump, as its stored past outputs
      # don't match the new coefficients).  This is the default for graph
      # filters (GraphNode#filter with a type or a Cookbook object; see
      # GraphNode::FilterMethods), where the cutoff, quality, and gain may
      # be nodes.  `structure: :biquad` there keeps the old direct form
      # Cookbook (thumps and all, e.g. for drums).
      #
      # The kernel is MB::Sound::FastFilter.svf (fast_filter extension); its
      # exact Ruby mirror is .process_ruby.  Coefficients are recomputed
      # only when an input changes, so constant parameters cost no more
      # than a biquad.
      #
      # Example:
      #     f = MB::Sound::Filter::SVF.new(:lowpass, 48000, 1000, quality: 2)
      #     f.process(MB::Sound.noise.sample(4800))
      #     # In a graph (cutoff and quality may be nodes):
      #     play 110.hz.ramp.filter(:lowpass, cutoff: 0.5.hz.lfo.at(200..3000), quality: 4)
      class SVF < Filter
        # Filter types, in the kernel's order (Cookbook::FILTER_TYPES, which
        # has the same order).
        FILTER_TYPES = [
          :lowpass,
          :highpass,
          :bandpass,
          :notch,
          :allpass,
          :peak,
          :lowshelf,
          :highshelf,
          :bandpass_skirt,
        ].freeze

        FILTER_TYPE_IDS = FILTER_TYPES.each_with_index.to_h.freeze

        # Types whose response uses the gain.
        GAIN_TYPES = [:bandpass, :bandpass_skirt, :peak, :lowshelf, :highshelf].freeze

        # Types that need a gain (Cookbook raises without one).
        GAIN_REQUIRED = [:peak, :lowshelf, :highshelf].freeze

        # The lowest cutoff in Hz (NaN and negative values too), as for
        # Cookbook#dynamic_process and FourPole.
        MIN_CUTOFF = 1.0

        # The highest cutoff as a fraction of the sample rate.
        MAX_CUTOFF_RATIO = 0.49

        # The lowest quality and linear gain (NaN too).
        MIN_QUALITY = 1e-10
        MIN_GAIN = 1e-10

        # States smaller than this are flushed to zero after each buffer.
        FLUSH = 1e-30

        # Parameter info for SampleWrapper constants (see Cookbook).
        DYNAMIC_INPUTS = {
          cutoff: { si: true, unit: 'Hz', range: ->(filter) { 0..(filter.sample_rate * MAX_CUTOFF_RATIO) } },
          quality: { si: false, unit: ' Q', range: 0..100 },
          gain: { si: false, unit: 'x', range: 0..100 },
        }.freeze

        attr_reader :filter_type, :sample_rate, :cutoff, :quality, :gain

        # Makes an SVF with the parameters of a Filter::Cookbook (its
        # quality, computed from a bandwidth or shelf slope if it was made
        # with one, at its center frequency), with fresh state.
        def self.from_cookbook(cookbook)
          new(
            cookbook.filter_type, cookbook.sample_rate, cookbook.center_frequency,
            quality: cookbook.quality || 0.5 ** 0.5, db_gain: cookbook.db_gain
          )
        end

        # Arguments as for Filter::Cookbook.new: +filter_type+ (see
        # FILTER_TYPES), +sample_rate+, the cutoff or center frequency in Hz,
        # and +:quality+ or +:bandwidth_oct+ (bandpass, notch, peak) or
        # +:shelf_slope+ (shelves; converted to a quality at +f_center+ as
        # Cookbook does), and +:db_gain+ for bandpass (output gain), peak,
        # and shelves, or +:gain+, the same as a linear gain.
        def initialize(filter_type, sample_rate, f_center, quality: nil, db_gain: nil, gain: nil, bandwidth_oct: nil, shelf_slope: nil)
          raise ArgumentError, "Invalid filter type #{filter_type.inspect}" unless FILTER_TYPE_IDS.include?(filter_type)
          raise ArgumentError, 'Give db_gain: or gain:, not both' if db_gain && gain
          raise "Sample rate must be a positive numeric (got #{sample_rate.inspect})" unless sample_rate.is_a?(Numeric) && sample_rate > 0

          gain = 10.0 ** (db_gain / 20.0) if db_gain
          raise ArgumentError, "Missing gain for #{filter_type}" if gain.nil? && GAIN_REQUIRED.include?(filter_type)

          if quality.nil? && (bandwidth_oct || shelf_slope)
            quality = Cookbook.new(
              GAIN_REQUIRED.include?(filter_type) ? filter_type : :peak, sample_rate, f_center,
              db_gain: (gain || 1.0).to_db, bandwidth_oct: bandwidth_oct, shelf_slope: shelf_slope
            ).quality
          end
          raise ArgumentError, 'Missing quality/bandwidth_oct/shelf_slope' if quality.nil?

          @filter_type = filter_type
          @type_id = FILTER_TYPE_IDS.fetch(filter_type)
          @sample_rate = sample_rate.to_f
          @cutoff = f_center.to_f
          @quality = quality.to_f
          @gain = gain&.to_f
          @state = [0.0, 0.0]
        end

        alias center_frequency cutoff

        # The gain in dB (nil without a gain).
        def db_gain
          @gain&.to_db
        end

        # Sets the cutoff or center frequency in Hz (used by #process).
        def cutoff=(hz)
          @cutoff = hz.to_f
        end
        alias center_frequency= cutoff=

        # Sets the quality (used by #process).
        def quality=(q)
          @quality = q.to_f
        end

        # Sets the linear gain (used by #process).
        def gain=(g)
          @gain = g&.to_f
        end

        # Sets the gain in dB.
        def db_gain=(db)
          @gain = db && 10.0 ** (db / 20.0)
        end

        # Changes the sample rate, keeping the cutoff in Hz (lowered if
        # above the new limit).
        def sample_rate=(rate)
          @sample_rate = rate.to_f
          @cutoff = [@cutoff, @sample_rate * MAX_CUTOFF_RATIO].min
          self
        end
        alias at_rate sample_rate=

        # Filters +samples+ (an NArray) with the current cutoff, quality, and
        # gain, returning a new SFloat, or +samples+ itself (filtered in
        # place) if it is an inplace SFloat.
        def process(samples)
          dynamic_process(samples, cutoff: @cutoff, quality: @quality, gain: @gain)
        end

        # Filters +samples+ with +cutoff+, +quality+, and +gain+ given as
        # numbers or NArrays of the same length (read per sample).  +gain+
        # defaults to the filter's gain.  Called by SampleWrapper with
        # sampled input nodes.
        def dynamic_process(samples, cutoff:, quality:, gain: @gain)
          samples = samples.real if samples.is_a?(Numo::SComplex) || samples.is_a?(Numo::DComplex)
          out = MB::Sound::FastFilter.svf(samples, cutoff, quality, gain, @type_id, @state, @sample_rate)
          remember(cutoff, quality, gain)
          out
        end

        # Same as #dynamic_process, through the Ruby mirror (slow; specs).
        def dynamic_process_ruby(samples, cutoff:, quality:, gain: @gain)
          samples = samples.real if samples.is_a?(Numo::SComplex) || samples.is_a?(Numo::DComplex)
          out = self.class.process_ruby(samples, cutoff, quality, gain, @type_id, @state, @sample_rate)
          remember(cutoff, quality, gain)
          out
        end

        # Sets the state as if +value+ had been the input for a long time
        # (band output 0, low output +value+), returning the steady output.
        def reset(value = 0)
          value = value.to_f
          @state = [0.0, value]
          _, _, _, m0, _, m2 = self.class.coefficients(@type_id, @cutoff, @quality, @gain || 1.0, @sample_rate)
          m0 * value + m2 * value
        end

        # A copy of the integrator states [ic1, ic2] (specs and debugging).
        def state
          @state.dup
        end

        # The complex response at +omega+ (radians per sample; a number or
        # NArray) at the current cutoff, quality, and gain: the analog
        # prototype m0 + (m1 s + m2) / (s^2 + k s + 1) with
        # s = (1 - z^-1) / (g (1 + z^-1)).
        def response(omega)
          g, k, _, m0, m1, m2 = self.class.coefficients(@type_id, @cutoff, @quality, @gain || 1.0, @sample_rate)
          z1 = omega.is_a?(Numo::NArray) ? Numo::NMath.exp(Numo::DComplex.cast(omega) * -1i) : CMath.exp(-1i * omega)
          s = (1 - z1) / ((1 + z1) * g)
          m0 + (m1 * s + m2) / (s * s + k * s + 1)
        end

        # Filters +source+ through this filter at its current settings (see
        # Filter#wrap; GraphNode#filter passes nodes as inputs instead).
        def wrap(source, in_place: false)
          SampleWrapper.new(self, source, in_place: in_place)
        end

        # See GraphNode#to_s
        def to_s
          s = "svf #{@filter_type}"
          s << " quality: #{@quality.round(4)}" if @quality
          s << " gain: #{db_gain.round(2)}dB" if @gain && GAIN_TYPES.include?(@filter_type)
          s
        end

        # See GraphNode#to_s_graphviz
        def to_s_graphviz
          s = "type: svf #{@filter_type}\n"
          s << "gain: #{db_gain.round(2)}dB\n" if @gain && GAIN_TYPES.include?(@filter_type)
          s
        end

        # The kernel's per-change coefficients for a +type_id+, cutoff +fc+
        # (Hz), quality +q+, linear gain +gain+, and +rate+, clamped as in
        # the kernel: [g, k, a1, m0, m1, m2] (k is the peak filter's
        # 1 / (Q A); a2 = g a1, a3 = g a2).
        def self.coefficients(type_id, fc, q, gain, rate)
          fc = fc.to_f
          q = q.to_f
          gain = gain.to_f
          fc_max = rate * MAX_CUTOFF_RATIO
          if !(fc >= MIN_CUTOFF)
            fc = MIN_CUTOFF
          elsif fc > fc_max
            fc = fc_max
          end
          q = MIN_QUALITY unless q >= MIN_QUALITY
          gain = MIN_GAIN unless gain >= MIN_GAIN

          g = FourPole.tan(fc * (Math::PI / rate))
          k = 1.0 / q

          case type_id
          when 1 # highpass
            m0 = 1.0; m1 = -k; m2 = -1.0
          when 2 # bandpass
            m0 = 0.0; m1 = k * gain; m2 = 0.0
          when 8 # bandpass_skirt
            m0 = 0.0; m1 = gain; m2 = 0.0
          when 3 # notch
            m0 = 1.0; m1 = -k; m2 = 0.0
          when 4 # allpass
            m0 = 1.0; m1 = -2.0 * k; m2 = 0.0
          when 5 # peak
            a = Math.sqrt(gain)
            k = 1.0 / (q * a)
            m0 = 1.0; m1 = k * (gain - 1.0); m2 = 0.0
          when 6 # lowshelf
            a = Math.sqrt(gain)
            g = g / Math.sqrt(a)
            m0 = 1.0; m1 = k * (a - 1.0); m2 = gain - 1.0
          when 7 # highshelf
            a = Math.sqrt(gain)
            g = g * Math.sqrt(a)
            m0 = gain; m1 = k * (1.0 - a) * a; m2 = 1.0 - gain
          else # lowpass
            m0 = 0.0; m1 = 0.0; m2 = 1.0
          end

          a1 = 1.0 / (1.0 + g * (g + k))
          [g, k, a1, m0, m1, m2]
        end

        # The Ruby mirror of MB::Sound::FastFilter.svf: the same arguments,
        # operations, and samples (specs check every sample).  Returns a new
        # SFloat; updates +state+.
        def self.process_ruby(buffer, cutoff, quality, gain, type_id, state, sample_rate)
          raise ArgumentError, 'SVF filter type must be 0..8' unless (0..8).cover?(type_id)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?
          raise ArgumentError, 'SVF state must have two elements' unless state.is_a?(Array) && state.length == 2

          ic1, ic2 = state.map { |v| v = v.to_f; v.finite? ? v : 0.0 }

          data = Numo::SFloat.cast(buffer)
          raise ArgumentError, "Only 1D NArrays may be processed (got #{data.ndim} dimensions)" unless data.ndim == 1
          length = data.length
          x_arr = data.to_a
          out = Array.new(length)

          gain = 1.0 if gain.nil?
          fc_arr = signal_input(cutoff, length, 'Cutoff')
          q_arr = signal_input(quality, length, 'Quality')
          g_arr = signal_input(gain, length, 'Gain')
          fc_s = fc_arr ? nil : cutoff.to_f
          q_s = q_arr ? nil : quality.to_f
          g_s = g_arr ? nil : gain.to_f

          last_fc = last_q = last_g = Float::NAN
          a1 = 1.0
          a2 = a3 = m0 = m1 = 0.0
          m2 = 0.0

          length.times do |i|
            fc = fc_arr ? fc_arr[i] : fc_s
            q = q_arr ? q_arr[i] : q_s
            gn = g_arr ? g_arr[i] : g_s

            # NaN != NaN, as in C
            if fc != last_fc || q != last_q || gn != last_g
              last_fc = fc
              last_q = q
              last_g = gn
              g, _k, a1, m0, m1, m2 = coefficients(type_id, fc, q, gn, rate)
              a2 = g * a1
              a3 = g * a2
            end

            x = x_arr[i]
            v3 = x - ic2
            v1 = a1 * ic1 + a2 * v3
            v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2.0 * v1 - ic1
            ic2 = 2.0 * v2 - ic2
            out[i] = m0 * x + m1 * v1 + m2 * v2
          end

          ic1 = 0.0 if !ic1.finite? || ic1.abs < FLUSH
          ic2 = 0.0 if !ic2.finite? || ic2.abs < FLUSH
          state[0] = ic1
          state[1] = ic2

          Numo::SFloat.cast(out)
        end

        # Reads a signal input like mb_read_signal_input: an NArray (real
        # parts as float32 Floats) or nil for a Numeric.
        def self.signal_input(value, length, name)
          return nil unless value.is_a?(Numo::NArray)
          raise ArgumentError, "#{name} array length does not match sample buffer length" if value.length != length
          value = value.real if value.is_a?(Numo::SComplex) || value.is_a?(Numo::DComplex)
          Numo::SFloat.cast(value).to_a
        end
        private_class_method :signal_input

        private

        # Keeps the last cutoff, quality, and gain (for #reset, #response,
        # #to_s).
        def remember(cutoff, quality, gain)
          @cutoff = last_value(cutoff, @cutoff)
          @quality = last_value(quality, @quality)
          @gain = last_value(gain, @gain) if gain
        end

        def last_value(v, previous)
          return previous if v.nil? || (v.is_a?(Numo::NArray) && v.empty?)
          (v.is_a?(Numo::NArray) ? v[-1].real : v).to_f
        end
      end
    end
  end
end
