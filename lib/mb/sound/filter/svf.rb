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
      # First-order types (filters-acd-1, 2026-11-07; FIRST_ORDER_TYPES):
      # :lowpass1p and :highpass1p (6 dB/octave, -3 dB at the cutoff; the
      # bilinear one-poles, as Filter::FirstOrder's :lowpass and :highpass),
      # and the shelves :lowshelf1p and :highshelf1p (6 dB/octave; +gain:
      # is the shelf's gain, e.g. 15.db; the cutoff is the corner on the
      # shelf's side: a boost's pole, where its gain is sqrt((G^2 + 1) / 2),
      # about 3 dB short of a large boost; a cut is the boost's mirror image,
      # as in Zolzer's DAFX first-order shelving filters and the 6 dB/octave
      # shelves of many DAW EQs).
      # They ignore the quality.  They run as this SVF at k = 2 (a double
      # pole) with an output mix that cancels one pole, so they share its
      # kernels, plan ops, and loop ops.
      #
      # +response: :matched+ (MATCHED_TYPES; the default is :bilinear, see
      # RESPONSES) replaces the bilinear transform with a design matched to
      # the analog response's magnitude (see .matched_design): the bilinear
      # transform squeezes the analog
      # response above the cutoff into the space below Nyquist, so at 48 kHz
      # a lowpass's top octave falls 5-13 dB too fast and highpasses and
      # bandpasses lose their top octave's shape; the matched design stays
      # within about 1 dB of the analog response up to 20 kHz (lowpass within
      # 12 dB of its peak: 0.8 dB; see design/notes/filters.md).
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
      #     play 110.hz.saw.filter(:lowpass, cutoff: 0.5.hz.lfo.at(200..3000), quality: 4)
      class SVF < Filter
        node_traits memory: :short

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
          :lowpass1p,
          :highpass1p,
          :lowshelf1p,
          :highshelf1p,
        ].freeze

        FILTER_TYPE_IDS = FILTER_TYPES.each_with_index.to_h.freeze

        # The first-order types (one pole; see the class comment).  They
        # ignore the quality.
        FIRST_ORDER_TYPES = [:lowpass1p, :highpass1p, :lowshelf1p, :highshelf1p].freeze

        # Designs for +response:+: :bilinear (the default; the bilinear
        # transform with the cutoff prewarped, the cookbook's) or :matched
        # (the analog magnitude up to Nyquist; MATCHED_TYPES only, see
        # .matched_design).
        RESPONSES = [:bilinear, :matched].freeze

        # Types with a matched design (+response: :matched+).
        MATCHED_TYPES = [:lowpass, :highpass, :bandpass, :bandpass_skirt, :notch, :allpass, :lowpass1p, :highpass1p].freeze

        # Added to a type's id for its matched design (SVF_MATCHED in
        # mb_svf.h).
        MATCHED = 16

        # Every valid kernel type id (FILTER_TYPE_IDS, and MATCHED_TYPES' ids
        # plus MATCHED; mb_svf_type_valid).
        TYPE_IDS = (FILTER_TYPE_IDS.values + MATCHED_TYPES.map { |t| FILTER_TYPE_IDS.fetch(t) + MATCHED }).freeze

        # Checks a +response:+ option for +filter_type+ (nil for :bilinear),
        # returning it.
        def self.check_response(response, filter_type)
          response ||= :bilinear
          unless RESPONSES.include?(response)
            raise ArgumentError, "response: is #{RESPONSES.map(&:inspect).join(' or ')} (got #{response.inspect})"
          end
          if response == :matched && !MATCHED_TYPES.include?(filter_type)
            raise ArgumentError, "response: :matched is for #{MATCHED_TYPES.map(&:inspect).join(', ')} (got #{filter_type.inspect})"
          end
          response
        end

        # The quality first-order types keep (they ignore it).
        FIRST_ORDER_QUALITY = 0.5

        # Types whose response uses the gain.
        GAIN_TYPES = [:bandpass, :bandpass_skirt, :peak, :lowshelf, :highshelf, :lowshelf1p, :highshelf1p].freeze

        # Types that need a gain (Cookbook raises without one).
        GAIN_REQUIRED = [:peak, :lowshelf, :highshelf, :lowshelf1p, :highshelf1p].freeze

        # The lowest cutoff in Hz (NaN and negative values too), as for
        # Cookbook#dynamic_process and FourPole.
        MIN_CUTOFF = 1.0

        # The highest cutoff as a fraction of the sample rate.
        MAX_CUTOFF_RATIO = 0.49

        # The lowest quality and linear gain (NaN too).
        MIN_QUALITY = 1e-10
        MIN_GAIN = 1e-10

        # States smaller than this (or not finite) are flushed to zero on a
        # grid of FLUSH_GRID samples of the filter's own time (MB_FLUSH_GRID
        # in mb_svf.h, shared by the SVF, four-pole, diode ladder, and
        # formant kernels; fixes-7: after each buffer before, so tails below
        # 1e-30 differed by buffer size).  States keep the samples since the
        # last grid point after their values.
        FLUSH = 1e-30

        # See FLUSH.
        FLUSH_GRID = 800

        # The samples since the last flush grid point from entry +idx+ of
        # state Array +state+ (mb_flush_count_read; 0 if absent).
        def self.flush_count(state, idx)
          k = state[idx]
          k.is_a?(Float) && k >= 0 && k < FLUSH_GRID ? k.to_i : 0
        end

        # +v+ flushed (see FLUSH).
        def self.flush_value(v)
          !v.finite? || v.abs < FLUSH ? 0.0 : v
        end

        # Parameter info for SampleWrapper constants (see Cookbook).
        DYNAMIC_INPUTS = {
          cutoff: { si: true, unit: 'Hz', range: ->(filter) { 0..(filter.sample_rate * MAX_CUTOFF_RATIO) } },
          quality: { si: false, unit: ' Q', range: 0..100 },
          gain: { si: false, unit: 'x', range: 0..100 },
        }.freeze

        attr_reader :filter_type, :sample_rate, :cutoff, :quality, :gain

        # The filter type's number in the kernels (FILTER_TYPE_IDS, plus
        # MATCHED for the matched response).
        attr_reader :type_id

        # The design: :bilinear or :matched (see RESPONSES).
        attr_reader :response_design

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
        # and shelves (dB, as its name says, or a Decibels value read as its
        # exact dB), or +:gain+, the same as a linear gain.  First-order types
        # (FIRST_ORDER_TYPES) take no quality.  +:response+ picks the design
        # (RESPONSES: :bilinear, the default, or :matched for MATCHED_TYPES;
        # see .matched_design).
        def initialize(filter_type, sample_rate, f_center, quality: nil, db_gain: nil, gain: nil, bandwidth_oct: nil, shelf_slope: nil, response: :bilinear)
          raise ArgumentError, "Invalid filter type #{filter_type.inspect}" unless FILTER_TYPE_IDS.include?(filter_type)
          response = self.class.check_response(response, filter_type)
          if FIRST_ORDER_TYPES.include?(filter_type)
            raise ArgumentError, "First-order filters (#{filter_type.inspect}) take no quality, bandwidth, or shelf slope" if bandwidth_oct || shelf_slope
            quality ||= FIRST_ORDER_QUALITY
          end
          raise ArgumentError, 'Give db_gain: or gain:, not both' if db_gain && gain
          raise "Sample rate must be a positive numeric (got #{sample_rate.inspect})" unless sample_rate.is_a?(Numeric) && sample_rate > 0

          db_gain = db_gain.db_value if db_gain.is_a?(Decibels)
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
          @response_design = response
          @type_id = FILTER_TYPE_IDS.fetch(filter_type) + (response == :matched ? MATCHED : 0)
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

        # Sets the gain in dB (a number, or a Decibels value as its dB).
        def db_gain=(db)
          db = db.db_value if db.is_a?(Decibels)
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
          out = Kernels.svf(samples, cutoff, quality, gain, @type_id, @state, @sample_rate)
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
          s << ' matched' if @response_design == :matched
          s << " quality: #{@quality.round(4)}" if @quality && !FIRST_ORDER_TYPES.include?(@filter_type)
          s << " gain: #{db_gain.round(2)}dB" if @gain && GAIN_TYPES.include?(@filter_type)
          s
        end

        # See GraphNode#to_s_graphviz
        def to_s_graphviz
          s = "type: svf #{@filter_type}#{' matched' if @response_design == :matched}\n"
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

          if type_id >= MATCHED
            g, k, m0, m1, m2 = matched_design(type_id - MATCHED, 2.0 * fc * (Math::PI / rate), q, gain)
            return [g, k, 1.0 / (1.0 + g * (g + k)), m0, m1, m2]
          end

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
          when 9 # lowpass1p
            k = 2.0
            m0 = 0.0; m1 = 1.0; m2 = 1.0
          when 10 # highpass1p
            k = 2.0
            m0 = 1.0; m1 = -1.0; m2 = -1.0
          when 11 # lowshelf1p
            k = 2.0
            g = g / gain if gain < 1.0
            m0 = 1.0; m1 = gain - 1.0; m2 = gain - 1.0
          when 12 # highshelf1p
            k = 2.0
            g = g * gain if gain < 1.0
            m0 = gain; m1 = 1.0 - gain; m2 = 1.0 - gain
          else # lowpass
            m0 = 0.0; m1 = 0.0; m2 = 1.0
          end

          a1 = 1.0 / (1.0 + g * (g + k))
          [g, k, a1, m0, m1, m2]
        end

        # The matched-response design (mb_svf_matched in mb_svf.h;
        # filters-acd-1, 2026-11-07) of the type with id +base_id+ (without
        # MATCHED) at +w0+
        # radians per sample, quality +q+, and linear gain +gain+ (clamped
        # by .coefficients): [g, k, m0, m1, m2] for a digital response
        # matched to the analog prototype's magnitude instead of the bilinear
        # transform's.  After Martin Vicanek, "Matched Second Order Digital
        # Filters" (2016): the analog poles mapped by z = e^(s T) (impulse
        # invariance; a first-order type's one pole doubled, cancelled by a
        # zero), zeros for the analog magnitude at DC and the cutoff (lowpass,
        # one zero; lowpass1p), a double zero at DC and the cutoff
        # (highpass), a zero at DC and the cutoff (highpass1p), a zero at DC,
        # the slope near DC, and the peak (bandpasses), zeros on the unit
        # circle at the cutoff and DC (notch), or the mirrored poles
        # (allpass).  The biquad is then written as the SVF it equals: with
        # P = 1 + a1 + a2, M = 1 - a1 + a2, W = b0 + b1 + b2, V = b0 - b1 +
        # b2, D = b0 - b2: g = sqrt(P / M), g k = 2 (1 - a2) / M, m0 = V / M,
        # m1 = (2 D - g k V) / (g M), m2 = W / P - m0.  The same operations
        # as the C.
        def self.matched_design(base_id, w0, q, gain)
          s1 = Math.sin(0.5 * w0)
          ph1 = s1 * s1
          ph0 = 1.0 - ph1
          p = 0.0
          e1 = 0.0 # a first-order type's |1 - p e^(-j w0)|^2

          # P, M, and aw (|A(e^(j w0))|^2, the poles' squared magnitude at
          # the cutoff) as products of sums of positive terms: no
          # cancellation at low cutoffs, where the matched zeros come from
          # small differences
          if base_id == 9 || base_id == 10 # lowpass1p, highpass1p
            p = Math.exp(-w0)
            pp = (1.0 - p) * (1.0 - p)
            mm = (1.0 + p) * (1.0 + p)
            a2 = p * p
            e1 = pp + 4.0 * p * ph1
            aw = e1 * e1
          else
            zeta = 0.5 / q
            if zeta < 1.0
              r = Math.exp(-zeta * w0)
              rt = Math.sqrt(1.0 - zeta * zeta)
              sh = Math.sin(0.5 * w0 * rt)
              c = 4.0 * r * sh * sh
              pp = (1.0 - r) * (1.0 - r) + c
              mm = (1.0 + r) * (1.0 + r) - c
              a2 = r * r
              # (w0 -+ the poles' angle) / 2
              sm = Math.sin(0.5 * w0 * zeta * zeta / (1.0 + rt))
              sp = Math.sin(0.5 * w0 * (1.0 + rt))
              r1 = (1.0 - r) * (1.0 - r)
              aw = (r1 + 4.0 * r * sm * sm) * (r1 + 4.0 * r * sp * sp)
            else
              s = Math.sqrt(zeta * zeta - 1.0)
              p1 = Math.exp(-w0 / (zeta + s))
              p2 = Math.exp(-w0 * (zeta + s))
              pp = (1.0 - p1) * (1.0 - p2)
              mm = (1.0 + p1) * (1.0 + p2)
              a2 = p1 * p2
              aw = ((1.0 - p1) * (1.0 - p1) + 4.0 * p1 * ph1) * ((1.0 - p2) * (1.0 - p2) + 4.0 * p2 * ph1)
            end
          end

          case base_id
          when 1 # highpass
            h = q * Math.sqrt(aw) / (4.0 * ph1)
            w = 0.0; v = 4.0 * h; d = 0.0
          when 2, 8 # bandpass, bandpass_skirt
            pk = base_id == 2 ? gain : gain * q
            sl = 2.0 * pk * pp / (q * w0)
            s0 = sl * sl
            rr = pk * pk * aw / ph1
            b2 = (s0 - rr) / (4.0 * ph1)
            b1 = s0 - 4.0 * b2
            b1 = 0.0 unless b1 > 0.0
            disc = 0.25 * b1 + b2
            w = 0.0; v = Math.sqrt(b1); d = disc > 0.0 ? Math.sqrt(disc) : 0.0
          when 3 # notch
            w = pp; v = pp * ph0 / ph1; d = 0.0
          when 4 # allpass
            w = pp; v = mm; d = a2 - 1.0
          when 9 # lowpass1p
            c0 = pp
            c1 = (0.5 * e1 - c0 * ph0) / ph1
            sc1 = c1 > 0.0 ? Math.sqrt(c1) : 0.0
            z0 = 0.5 * ((1.0 - p) + sc1)
            z1 = 0.5 * ((1.0 - p) - sc1)
            w = c0; v = sc1 * (1.0 + p); d = z0 + p * z1
          when 10 # highpass1p
            c = Math.sqrt(0.5 * e1 / (4.0 * ph1))
            w = 0.0; v = 2.0 * c * (1.0 + p); d = c * (1.0 - p)
          else # lowpass
            b1 = (q * q * aw - pp * pp * ph0) / ph1
            sb1 = b1 > 0.0 ? Math.sqrt(b1) : 0.0
            w = pp; v = sb1; d = 0.5 * (pp + sb1)
          end

          g = Math.sqrt(pp / mm)
          gk = 2.0 * (1.0 - a2) / mm
          m0 = v / mm
          [g, gk / g, m0, (2.0 * d - gk * v) / (g * mm), w / pp - m0]
        end

        # The Ruby mirror of MB::Sound::FastFilter.svf: the same arguments,
        # operations, and samples (specs check every sample).  Returns a new
        # SFloat; updates +state+.
        def self.process_ruby(buffer, cutoff, quality, gain, type_id, state, sample_rate)
          raise ArgumentError, 'SVF filter type must be 0..12, or a matched-response type (+16)' unless TYPE_IDS.include?(type_id)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?
          raise ArgumentError, 'SVF state must have two elements' unless state.is_a?(Array) && (state.length == 2 || state.length == 3)

          ic1, ic2 = state.first(2).map { |v| v = v.to_f; v.finite? ? v : 0.0 }
          fk = flush_count(state, 2)

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

            if (fk += 1) >= FLUSH_GRID
              fk = 0
              ic1 = flush_value(ic1)
              ic2 = flush_value(ic2)
            end
          end

          state[0] = ic1
          state[1] = ic2
          state[2] = fk.to_f

          Kernels.inplace_result(buffer, out)
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

      Kernels.register :svf, c: FastFilter.method(:svf), ruby: SVF.method(:process_ruby),
        about: 'the graph cookbook SVF (mb_svf.h)'
    end
  end
end
