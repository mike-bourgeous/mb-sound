module MB
  module Sound
    module GraphNode
      # A bank of N state-variable filter sections (Filter::SVF's design and
      # step) in one node: each band has its own type (:bandpass by default;
      # any Filter::SVF type), frequency, width, gain, and pan, and the
      # bands are summed into C output channels (stereo now, written for N:
      # each band has a gain per channel) or chained (+serial: true+, as
      # GraphNode#peq uses).  See design/notes/filter_bank.md.
      #
      # Built by GraphNode#filter_bank, #bandpass_series, #peq_series,
      # #peq, and (as the Formant subclass) #formant.  Per-band settings
      # are numbers or nodes read every sample:
      # - frequency: F * (1 + R * h) Hz, with F (+frequency+) and R
      #   (+ratio+) numbers or nodes and h (+harmonic+) the band's harmonic
      #   offset, so a moving fundamental is one input for every band;
      # - width (Width): a Q, an octave bandwidth (an Interval: Q follows
      #   the band's frequency as Filter::Cookbook computes it), or a
      #   bandwidth in Hz (a Pitch: Q = f / bandwidth);
      # - gain: linear (Decibels read exactly);
      # - pan: a position -1..1 for two channels (+pan_law+, one of
      #   PAN_LAWS, the ChannelMixer::PanLaws formulas), or +gains+, one
      #   per channel (any channel count).
      #
      # +normalize: true+ scales the output so pink noise keeps its power
      # over 100 Hz-10 kHz whatever the bands' widths and gains (bandpass
      # types; see .pink_power), recomputed whenever a width or gain moves.
      #
      # The kernel is MB::Sound::FastFilter.filter_bank (mb_filter_bank.h,
      # shared with the plan layer's Plan::Op::FilterBank; exact Ruby mirror
      # .process_ruby): coefficients change only on samples where an input
      # changes, and the output is the same at any buffer size.  Ends when
      # the input or any parameter node ends.
      #
      # With one channel the bank is the node to sample; with more,
      # #outputs are the channels (a Router computes them in one kernel
      # call), and the DSL methods return them as a Channels bundle.
      class FilterBank
        include GraphNode
        include SampleRateHelper
        # (its state and held values: #plan_snapshot)
        node_traits memory: :short, carry: :snapshot

        # A band's width: +mode+ :q, :octaves, or :hz, and +value+ a Float
        # or a node.
        Width = Data.define(:mode, :value) do
          def to_s
            v = value.is_a?(Numeric) ? MB::M.sigfigs(value, 4) : 'node'
            case mode
            when :q then "Q #{v}"
            when :octaves then "#{v} oct"
            else "#{v} Hz"
            end
          end
        end

        # Config layout (see mb_filter_bank.h).
        VERSION = 1
        HEADER = 16
        BAND = 13
        MAX_BANDS = 512
        MAX_CHANNELS = 16
        MAX_SIGNALS = 2048
        MAX_SNAPSHOTS = 256

        # Width modes as the kernel numbers them.
        WIDTH_MODES = { q: 0, octaves: 1, hz: 2 }.freeze

        # Pan laws of node pans as the kernel numbers them (the
        # ChannelMixer::PanLaws laws of the same names).
        PAN_LAWS = { equal_power: 0, linear: 1, minus_4_5db: 2 }.freeze

        # Normalization modes as the kernel numbers them (:width_law is the
        # morph tables' own, Formant's).
        NORMALIZE_MODES = { false => 0, true => 1, width_law: 2 }.freeze

        # Band types +normalize: true+ takes.
        NORMALIZE_TYPES = %i[bandpass bandpass_skirt].freeze

        # ln(10000 / 100): pink noise's power over 100 Hz-10 kHz (Formant's
        # NORMALIZE_RANGE), per unit of power per natural log of frequency.
        NORMALIZE_REFERENCE = 4.605170185988092

        # The narrowest morph width scale.
        MIN_WIDTH = 0.01

        # The width of a band without one (Q 0.7071).
        DEFAULT_WIDTH = Width.new(:q, Math.sqrt(0.5))

        # The input node (a sampler branch).
        attr_reader :input

        # The number of output channels.
        attr_reader :channels

        # The number of bands.
        attr_reader :band_count

        # The pan law of node pans.
        attr_reader :pan_law

        # The settings as the kernel reads them (a frozen DFloat; see
        # mb_filter_bank.h).
        attr_reader :config

        # Creates a bank on +input+ with +bands+, each a Hash of :type
        # (default :bandpass), :response (:bilinear or :matched), :frequency
        # (Hz, a Pitch, or a node), :ratio (default 0), :harmonic (default
        # 0), :width (a Width, Interval, Pitch, number (Q), or node (Q);
        # default Q 0.7071), :gain (default 1), :pan (a position or node), and
        # :gains (one gain per channel).  +channels+ defaults to 2 when any
        # band has a pan, else to the length of the bands' +gains+, else 1.
        # +morph+ (Formant) is a Hash of :logs (3 * S * N natural logs: every
        # snapshot's band frequencies, then qualities, then gains), :position,
        # :shift (semitones), and :scale (width scale), numbers or nodes.
        def initialize(input, bands:, channels: nil, serial: false, normalize: false, pan_law: :equal_power, morph: nil, sample_rate: nil)
          raise ArgumentError, "A filter bank's input must be a graph node (got #{input.inspect})" unless input.respond_to?(:sample)
          raise ArgumentError, 'A filter bank needs at least one band' unless bands.is_a?(Array) && !bands.empty?
          raise ArgumentError, "A filter bank has at most #{MAX_BANDS} bands (got #{bands.length})" if bands.length > MAX_BANDS
          raise ArgumentError, "Unknown pan law #{pan_law.inspect} (#{PAN_LAWS.keys.map(&:inspect).join(', ')})" unless PAN_LAWS.key?(pan_law)
          raise ArgumentError, "normalize: must be true or false (got #{normalize.inspect})" unless NORMALIZE_MODES.key?(normalize)

          @input = input.get_sampler
          @sample_rate = (sample_rate || input.sample_rate).to_f
          @serial = !!serial
          @normalize = normalize
          @pan_law = pan_law
          @band_count = bands.length
          @signals = []
          @signal_index = {}.compare_by_identity
          @bands = bands.map { |b| band_spec(b) }.freeze

          explicit = @bands.map { |b| b[:gains]&.length }.compact.uniq
          raise ArgumentError, "Bands give gains for different channel counts (#{explicit.join(', ')})" if explicit.length > 1
          @channels = (channels || (@bands.any? { |b| b[:pan] } ? 2 : explicit[0] || 1)).to_i
          raise ArgumentError, "A filter bank has 1 to #{MAX_CHANNELS} channels (got #{@channels})" unless (1..MAX_CHANNELS).cover?(@channels)
          check_settings(explicit[0], morph)

          morph_slots = morph ? %i[position shift scale].flat_map { |k| signal_slot(morph.fetch(k), "morph #{k}") } : [-1.0, 0.0] * 3
          logs = morph ? morph.fetch(:logs).map(&:to_f) : []
          snapshots = morph ? logs.length / (3 * @band_count) : 0
          raise ArgumentError, "Morph tables need 3 values per band per snapshot (got #{logs.length})" if morph && (logs.empty? || logs.length % (3 * @band_count) != 0)
          raise ArgumentError, "A filter bank has at most #{MAX_SNAPSHOTS} morph snapshots" if snapshots > MAX_SNAPSHOTS
          raise ArgumentError, "A filter bank reads at most #{MAX_SIGNALS} nodes" if @signals.length > MAX_SIGNALS

          @snapshots = snapshots
          @config = Numo::DFloat.cast(
            [VERSION, @band_count, @channels, @serial ? 1 : 0, NORMALIZE_MODES.fetch(@normalize), PAN_LAWS.fetch(@pan_law),
             @signals.length, snapshots, *morph_slots, 0, 0] +
            @bands.flat_map { |b| band_config(b) } + logs
          ).freeze
          @state = Numo::DFloat.zeros(2 * @band_count + 1) # (and the flush grid count; see Filter::SVF::FLUSH_GRID)
          @signal_data = Array.new(@signals.length)
          @out_sets = nil # (reused output buffers; see #output_buffers)
          @out_index = 0
          @router = nil
          @node_type_name = self.class.name.rpartition('::').last
        end

        # True for a chained (serial) bank.
        def serial?
          @serial
        end

        # The normalization (false, true, or Formant's :width_law).
        def normalize?
          @normalize
        end

        # The bands' settings: Hashes of :type, :frequency, :ratio,
        # :harmonic, :width (a Width), :gain, :pan, and :gains (numbers or
        # nodes; nodes as their sampler branches).
        def band_list
          @bands
        end

        # The output nodes: this bank for one channel, else the Router's.
        def outputs
          @channels == 1 ? [self] : router.outputs
        end

        # What the DSL methods return: this bank for one channel, else a
        # Channels bundle of the outputs.
        def output
          @channels == 1 ? self : Channels.new(router.outputs)
        end

        # The Router computing every channel of a multichannel bank.
        def router
          raise ArgumentError, 'A one-channel filter bank is its own output' if @channels == 1

          @router ||= Router.new(self)
        end

        # The mono output (see #frame); a multichannel bank's channels are
        # its #outputs.
        def sample(count)
          raise NotImplementedError, "A #{@channels}-channel filter bank has no single output; sample its outputs (bank.outputs)" if @channels != 1

          f = frame(count)
          f && f[0]
        end

        # One buffer of every channel (an Array reused every other call), or
        # nil once the input or a parameter node ended.
        def frame(count)
          x = @input.sample(count)
          return nil if x.nil? || x.empty?

          n = x.length
          data = @signal_data
          i = 0
          while i < @signals.length
            v = @signals[i].sample(n)
            return nil if v.nil? || v.empty?

            n = v.length if v.length < n
            data[i] = v
            i += 1
          end

          x = x[0...n] if x.length > n
          i = 0
          while i < data.length
            data[i] = data[i][0...n] if data[i].length > n
            i += 1
          end

          Kernels.filter_bank(output_buffers(n), x, @config, data, @state, @sample_rate)
        end

        # The node inputs.
        def sources
          s = { input: @input }
          @signals.each_with_index { |n, i| s[:"param_#{i + 1}"] = n }
          s
        end

        # Clears the bands' states.
        def reset
          @state.fill(0)
          self
        end

        def to_s
          kind = @bands.map { |b| b[:type] }.uniq.join('/')
          "FilterBank #{@band_count} #{kind}#{' serial' if @serial}#{", #{@channels} ch" if @channels > 1}"
        end

        # The combined response (a DComplex) at +freqs+ Hz of the bands'
        # constant settings (nodes at their last sample are not known here:
        # bands with node settings are left out), for previews and specs.
        # Serial banks multiply their bands' responses; parallel ones add
        # them, through channel +channel+'s gains.
        def response(freqs, channel: 0)
          omega = Numo::DFloat.cast(freqs) * (2 * Math::PI / @sample_rate)
          total = @serial ? Numo::DComplex.ones(omega.length) : Numo::DComplex.zeros(omega.length)
          @bands.each_with_index do |b, idx|
            f = band_frequency(b)
            w = b[:width]
            next unless f && w.value.is_a?(Numeric) && b[:gain].is_a?(Numeric)

            q = self.class.width_quality(w.mode, w.value, f, @sample_rate)
            r = Filter::SVF.new(b[:type], @sample_rate, f, quality: q, gain: b[:gain], response: b[:response]).response(omega)
            if @serial
              total = total * r
            else
              total = total + r * band_gains(b, idx)[channel]
            end
          end
          total
        end

        # Plan layer (see MB::Sound::Plan and Plan::Op::FilterBank): the
        # kernel in C on this node's config and state, fused with its input
        # and parameter nodes and grouped across synth voices.  A
        # multichannel bank is planned through its Router (a
        # Plan::MultiDescribable), which describes it with #plan_values.
        include Plan::Describable

        def plan_inputs
          [@input] + @signals
        end

        def plan_unsupported_reason
          return "a #{@channels}-channel filter bank (computed in its router's region)" if @channels != 1

          nil
        end

        def plan_describe(p)
          plan_values(p)[0]
        end

        # One Value per channel (see Plan::Builder#filter_bank).
        def plan_values(p)
          p.filter_bank(self, p[@input], @signals.map { |s| p[s] })
        end

        # Plan layer state for check mode and Session::Carry (the bands'
        # integrator states and flush count).
        def plan_snapshot
          @state.to_a
        end

        # Restores a #plan_snapshot (one of another band count starts
        # fresh instead).
        def plan_restore(snapshot)
          @state[0..] = snapshot if snapshot.length == @state.length
        end

        # A band's Q for width +mode+ and +value+ at +freq+ Hz (the
        # kernel's: octaves as Filter::Cookbook converts them, f clamped to
        # 1e-10..0.49 of the rate; Hz as f / bandwidth).
        def self.width_quality(mode, value, freq, rate)
          case mode
          when :octaves
            fq = freq
            fc_max = rate * Filter::SVF::MAX_CUTOFF_RATIO
            if fq < 1e-10 || !fq.finite?
              fq = 1e-10
            elsif fq > fc_max
              fq = fc_max
            end
            w0 = 2.0 * Math::PI * fq / rate
            0.5 / Math.sinh(value * w0 * Math.log(2.0) / (2.0 * Math.sin(w0)))
          when :hz then freq / value
          else value
          end
        end

        # The power an analog bandpass of peak gain 1 at quality +q+ passes
        # from pink noise, per unit of input power per natural log of
        # frequency: the integral of |H|^2 over ln f, 2 atan(r) / r with r =
        # sqrt(4 q^2 - 1) (2 atanh(r) / r with r = sqrt(1 - 4 q^2) below Q
        # 0.5; 2 at 0.5; about pi / (2 q) for narrow bands).
        def self.pink_power(q)
          d = 4.0 * q * q - 1.0
          if d > 0.0
            r = Math.sqrt(d)
            2.0 * Math.atan(r) / r
          elsif d < 0.0
            r = Math.sqrt(-d)
            2.0 * Math.atanh(r) / r
          else
            2.0
          end
        end

        # [left, right] gains of pan position +p+ with law id +law+ (the
        # kernel's mb_fbank_pan: ChannelMixer::PanLaws.gains, p clamped to
        # -1..1, NaN as 0).
        def self.pan_gains(law, p)
          if !(p >= -1.0)
            p = p.nan? ? 0.0 : -1.0
          elsif p > 1.0
            p = 1.0
          end
          case law
          when 1 then [(1 - p) * 0.5, (p + 1) * 0.5]
          when 2 then [((1 - p) * 0.5)**0.75, ((p + 1) * 0.5)**0.75]
          else
            angle = (p + 1) * (Math::PI / 4)
            [Math.cos(angle), Math.sin(angle)]
          end
        end

        # A width argument as a Width, by its type (MB::Sound::ArgTypes): an
        # Interval (`30.cents`) is an octave bandwidth, a frequency (a Pitch,
        # `40.hz`, or a frequency node such as `v.freq` or `node.freq`) a
        # bandwidth in Hz, a number or other node a Q.
        def self.width_of(value, name = 'width')
          return value if value.is_a?(Width)

          w =
            case ArgTypes.classify(value)
            when :interval then Width.new(:octaves, value.to_octaves.to_f)
            when :frequency
              if value.is_a?(Pitch)
                Width.new(:hz, value.constant? ? value.frequency.to_f : value.oscillator_frequency)
              else
                Width.new(:hz, value)
              end
            when :number, :ratio
              raise ArgumentError, "#{name} must be a real number (got #{value.inspect})" unless value.real?

              Width.new(:q, value.to_f)
            when :node then Width.new(:q, value)
            else
              raise ArgumentError, "#{name} must be a Q (a number or node), an Interval (30.cents), or a frequency (40.hz) (got #{value.inspect})"
            end
          if w.value.is_a?(Numeric) && !(w.value > 0 && w.value.finite?)
            raise ArgumentError, "#{name} must be positive (got #{value.inspect})"
          end
          w
        end

        # The value for band +index+ of +count+ of a per-band argument: a
        # PerHarmonic (or a bare Range: per_harmonic with the linear curve),
        # an Array (one per band, repeating), a Proc of the index, or one
        # value for every band.
        def self.per_band(value, index, count)
          case value
          when PerHarmonic then value.value(index, count)
          when Range then PerHarmonic.new(value).value(index, count)
          when Array
            raise ArgumentError, 'A per-band list needs at least one value' if value.empty?

            value[index % value.length]
          when Proc then value.call(index)
          else value
          end
        end

        # The exact Ruby mirror of MB::Sound::FastFilter.filter_bank (same
        # arguments; see mb_filter_bank.h): the same double operations in the
        # same order (Filter::SVF.coefficients for each band's design),
        # inputs read as float32 values, so specs compare the two for
        # equality.
        def self.process_ruby(outs, x, config, signals, state, sample_rate)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?

          cfg = config.to_a
          check_config(cfg, signals.length, outs.length, state.length)
          n = outs[0].length
          raise ArgumentError, 'Filter bank outputs must have the same length' unless outs.all? { |o| o.length == n }

          nbands = cfg[1].to_i
          nch = cfg[2].to_i
          serial = cfg[3] == 1
          normalize = cfg[4].to_i
          law = cfg[5].to_i
          nsnap = cfg[7].to_i
          stride = BAND + nch
          band = ->(b) { cfg[HEADER + b * stride, stride] }
          tables = cfg[HEADER + nbands * stride..] || []

          xs = signal_values(x, n)
          sigs = signals.map { |s| signal_values(s, n) }
          st = state.to_a
          fk = st[2 * nbands]
          fk = fk >= 0 && fk < Filter::SVF::FLUSH_GRID ? fk.to_i : 0
          flush = ->(v) { (!v.finite? || v.abs < Filter::SVF::FLUSH) ? 0.0 : v }
          semitone_log = Math.log(2.0) / 12.0
          fc_max = rate * Filter::SVF::MAX_CUTOFF_RATIO

          coeffs = Array.new(nbands) { [1.0, 0.0, 0.0, 0.0, 0.0, 0.0] }
          last_c = Array.new(nbands) { [Float::NAN, Float::NAN, Float::NAN] }
          power = Array.new(nbands, 0.0)
          last_pan = Array.new(nbands, Float::NAN)
          pan_gain = Array.new(nbands) { [0.0, 0.0] }
          mix = Array.new(nbands) { |b| band.(b)[11] >= 0 ? pan_gain[b] : band.(b)[BAND, nch] }
          vals = Array.new(sigs.length, Float::NAN)
          value = ->(slot, c) { slot >= 0 ? vals[slot.to_i] : c }
          update = ->(b, type, fc, q, g) {
            next false if fc == last_c[b][0] && q == last_c[b][1] && g == last_c[b][2]

            last_c[b] = [fc, q, g]
            gg, _k, a1, m0, m1, m2 = Filter::SVF.coefficients(type, fc, q, g, rate)
            a2 = gg * a1
            coeffs[b] = [a1, a2, gg * a2, m0, m1, m2]
            true
          }
          step = ->(b, xi) {
            a1, a2, a3, m0, m1, m2 = coeffs[b]
            ic1 = st[2 * b]
            ic2 = st[2 * b + 1]
            v3 = xi - ic2
            v1 = a1 * ic1 + a2 * v3
            v2 = ic2 + a2 * ic1 + a3 * v3
            st[2 * b] = 2.0 * v1 - ic1
            st[2 * b + 1] = 2.0 * v2 - ic2
            m0 * xi + m1 * v1 + m2 * v2
          }
          f32 = ->(v) { [v].pack('f').unpack1('f') }

          scale = 1.0
          n.times do |i|
            changed = i == 0
            sigs.each_with_index do |s, k|
              v = s.is_a?(Array) ? s[i] : s
              if v != vals[k]
                vals[k] = v
                changed = true
              end
            end

            if changed
              moved = false
              if nsnap > 0
                m = value.(cfg[8], cfg[9])
                sh = value.(cfg[10], cfg[11])
                w = value.(cfg[12], cfg[13])
                lo = hi = 0
                frac = 0.0
                if nsnap > 1
                  mc = m
                  if !(mc >= 0.0)
                    mc = 0.0
                  elsif mc > 1.0
                    mc = 1.0
                  end
                  pos = mc * (nsnap - 1).to_f
                  lo = pos.floor
                  lo = nsnap - 2 if lo > nsnap - 2
                  hi = lo + 1
                  frac = pos - lo.to_f
                end
                shift_log = sh * semitone_log
                wc = w
                wc = MIN_WIDTH unless wc >= MIN_WIDTH
                width_log = Math.log(wc)
                level_log = normalize == 2 ? width_log * -0.5 : 0.0
                block = nsnap * nbands
                nbands.times do |b|
                  a = lo * nbands + b
                  c = hi * nbands + b
                  lf = tables[a] + (tables[c] - tables[a]) * frac + shift_log
                  lq = tables[block + a] + (tables[block + c] - tables[block + a]) * frac - width_log
                  lg = tables[2 * block + a] + (tables[2 * block + c] - tables[2 * block + a]) * frac + level_log
                  moved = true if update.(b, band.(b)[0].to_i, Math.exp(lf), Math.exp(lq), Math.exp(lg))
                end
              else
                nbands.times do |b|
                  bd = band.(b)
                  type = bd[0].to_i
                  f = value.(bd[1], bd[2]) * (1.0 + value.(bd[3], bd[4]) * bd[5])
                  wv = value.(bd[7], bd[8])
                  g = value.(bd[9], bd[10])
                  q =
                    case bd[6]
                    when 1
                      fq = f
                      if fq < 1e-10 || !fq.finite?
                        fq = 1e-10
                      elsif fq > fc_max
                        fq = fc_max
                      end
                      w0 = 2.0 * Math::PI * fq / rate
                      0.5 / Math.sinh(wv * w0 * Math.log(2.0) / (2.0 * Math.sin(w0)))
                    when 2 then f / wv
                    else wv
                    end
                  if update.(b, type, f, q, g) && normalize == 1
                    qc = q >= Filter::SVF::MIN_QUALITY ? q : Filter::SVF::MIN_QUALITY
                    gc = g >= Filter::SVF::MIN_GAIN ? g : Filter::SVF::MIN_GAIN
                    pk = (type & ~Filter::SVF::MATCHED) == Filter::SVF::FILTER_TYPE_IDS[:bandpass_skirt] ? gc * qc : gc
                    power[b] = pk * pk * pink_power(qc)
                    moved = true
                  end
                end
              end

              if normalize == 1 && moved
                sum = 0.0 # (in band order, as the kernel adds)
                power.each { |p| sum += p }
                scale = sum > 0.0 ? Math.sqrt(NORMALIZE_REFERENCE / sum) : 1.0
              end

              nbands.times do |b|
                slot = band.(b)[11]
                next unless slot >= 0

                p = vals[slot.to_i]
                next if p == last_pan[b]

                last_pan[b] = p
                pan_gain[b].replace(pan_gains(law, p))
              end
            end

            xi = xs.is_a?(Array) ? xs[i] : xs
            if serial
              v = xi
              nbands.times { |b| v = f32.(step.(b, v)) }
              outs[0][i] = v
            else
              acc = Array.new(nch, 0.0)
              nbands.times do |b|
                y = step.(b, xi)
                g = mix[b]
                nch.times { |c| acc[c] += g[c] * y }
              end
              nch.times { |c| outs[c][i] = normalize == 1 ? acc[c] * scale : acc[c] }
            end

            if (fk += 1) >= Filter::SVF::FLUSH_GRID
              fk = 0
              (2 * nbands).times { |k| st[k] = flush.(st[k]) }
            end
          end

          st[2 * nbands] = fk.to_f
          st.each_with_index { |v, k| state[k] = v }
          outs
        end

        # Raises unless +cfg+ (an Array) is a bank config for +nsig+
        # signals, +nouts+ outputs, and a state of +stlen+ values (as
        # mb_fbank_check).
        def self.check_config(cfg, nsig, nouts, stlen)
          raise ArgumentError, "Not a filter bank config (version #{VERSION})" unless cfg.length >= HEADER && cfg[0] == VERSION

          nb, nc, ns = cfg[1], cfg[2], cfg[7]
          raise ArgumentError, "A filter bank has 1 to #{MAX_BANDS} bands" unless nb >= 1 && nb <= MAX_BANDS && nb == nb.floor
          raise ArgumentError, "A filter bank has 1 to #{MAX_CHANNELS} channels" unless nc >= 1 && nc <= MAX_CHANNELS && nc == nc.floor
          raise ArgumentError, "A filter bank has 0 to #{MAX_SNAPSHOTS} morph snapshots" unless ns >= 0 && ns <= MAX_SNAPSHOTS && ns == ns.floor

          nbands, nch, nsnap = nb.to_i, nc.to_i, ns.to_i
          raise ArgumentError, 'The filter bank config has the wrong length' unless cfg.length == HEADER + nbands * (BAND + nch) + 3 * nsnap * nbands
          raise ArgumentError, 'Bad filter bank topology' unless [0, 1].include?(cfg[3])
          raise ArgumentError, 'Serial filter banks are mono, without morph tables or normalization' if cfg[3] == 1 && (nch != 1 || nsnap != 0 || cfg[4] != 0)
          raise ArgumentError, 'Bad filter bank normalization' unless [0, 1, 2].include?(cfg[4])
          raise ArgumentError, 'Width-law normalization needs morph tables' if cfg[4] == 2 && nsnap == 0
          raise ArgumentError, 'Bad filter bank pan law' unless [0, 1, 2].include?(cfg[5])
          raise ArgumentError, "The filter bank expects #{cfg[6].to_i} signals (got #{nsig})" unless cfg[6] == nsig && nsig <= MAX_SIGNALS
          raise ArgumentError, "The filter bank has #{nch} channels (got #{nouts} outputs)" unless nouts == nch
          raise ArgumentError, "The filter bank state must have #{2 * nbands + 1} values" unless stlen == 2 * nbands + 1

          slot_ok = ->(s) { s >= -1 && s < nsig && s == s.floor }
          raise ArgumentError, 'Bad filter bank signal slot' unless [8, 10, 12].all? { |k| slot_ok.(cfg[k]) }

          nbands.times do |b|
            bd = cfg[HEADER + b * (BAND + nch), BAND + nch]
            t = bd[0]
            base = t.to_i & ~Filter::SVF::MATCHED
            valid = t == t.floor && t >= 0 && (t < Filter::SVF::MATCHED ? t.to_i < Filter::SVF::FILTER_TYPES.length : Filter::SVF::MATCHED_TYPES.map { |s| Filter::SVF::FILTER_TYPE_IDS[s] }.include?(base))
            raise ArgumentError, 'Bad filter bank band type' unless valid
            if cfg[4] == 1 && !NORMALIZE_TYPES.map { |s| Filter::SVF::FILTER_TYPE_IDS[s] }.include?(base)
              raise ArgumentError, 'Normalized filter banks take bandpass bands'
            end
            raise ArgumentError, 'Bad filter bank width mode' unless [0, 1, 2].include?(bd[6])
            raise ArgumentError, 'Bad filter bank signal slot' unless [1, 3, 7, 9, 11].all? { |k| slot_ok.(bd[k]) }
            raise ArgumentError, 'Node pans need two channels' if bd[11] >= 0 && nch != 2
          end
        end
        private_class_method :check_config

        # A signal input as the kernels read it: a Float, or an Array of
        # float32 values (real parts of complex inputs).
        def self.signal_values(value, n)
          case value
          when nil then 0.0
          when Numeric then value.to_f
          when Numo::NArray
            raise ArgumentError, 'array length does not match sample buffer length' unless value.length == n

            v = value.is_a?(Numo::SComplex) || value.is_a?(Numo::DComplex) ? value.real : value
            Numo::SFloat.cast(v).to_a
          else
            raise ArgumentError, "Expected a number or NArray (got #{value.class})"
          end
        end
        private_class_method :signal_values

        private

        # One band's settings with nodes as sampler branches and widths as
        # Widths (see #initialize).
        def band_spec(b)
          raise ArgumentError, "A filter bank band is a Hash (got #{b.inspect})" unless b.is_a?(Hash)

          unknown = b.keys - %i[type response frequency ratio harmonic width gain pan gains]
          raise ArgumentError, "Unknown filter bank band settings #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

          type = b.fetch(:type, :bandpass)
          raise ArgumentError, "Unknown filter type #{type.inspect} (#{Filter::SVF::FILTER_TYPES.map(&:inspect).join(', ')})" unless Filter::SVF::FILTER_TYPE_IDS.key?(type)
          response = Filter::SVF.check_response(b.fetch(:response, :bilinear), type)
          raise ArgumentError, "First-order filters (#{type.inspect}) take no width" if Filter::SVF::FIRST_ORDER_TYPES.include?(type) && b[:width]

          freq = frequency_value(b.fetch(:frequency) { raise ArgumentError, 'Each filter bank band needs a frequency' })
          width = self.class.width_of(b[:width] || (Filter::SVF::FIRST_ORDER_TYPES.include?(type) ? Width.new(:q, Filter::SVF::FIRST_ORDER_QUALITY) : DEFAULT_WIDTH))
          gain = b.fetch(:gain, 1.0)
          gain = Decibels.gain_of(gain, 'gain', zero: true) unless gain.respond_to?(:sample)
          pan = b[:pan]
          raise ArgumentError, "Pan must be a position -1..1 or a node (got #{pan.inspect})" unless pan.nil? || pan.respond_to?(:sample) || (pan.is_a?(Numeric) && pan.real?)
          gains = b[:gains]&.map { |g| Decibels.gain_of(g, 'channel gain', zero: true).to_f }
          raise ArgumentError, 'Give a band a pan or channel gains, not both' if pan && gains
          harmonic = b.fetch(:harmonic, 0)
          raise ArgumentError, "Harmonic offsets are numbers (got #{harmonic.inspect})" unless harmonic.is_a?(Numeric) && harmonic.real?

          {
            type: type, response: response, frequency: sampled(freq), ratio: sampled(b.fetch(:ratio, 0.0)), harmonic: harmonic.to_f,
            width: width.value.is_a?(Numeric) ? width : Width.new(width.mode, sampled(width.value)),
            gain: sampled(gain), pan: pan.nil? ? nil : sampled(pan.is_a?(Numeric) ? pan.to_f : pan), gains: gains&.freeze,
          }.freeze
        end

        # A frequency argument: Hz, a node, or a Pitch (its frequency, or
        # its frequency node).
        def frequency_value(f)
          f = f.frequency if f.is_a?(Note)
          f = f.constant? ? f.frequency : f.oscillator_frequency if f.is_a?(Pitch)
          raise ArgumentError, "Filter bank frequencies are Hz, Pitches, or nodes (got #{f.inspect})" unless (f.is_a?(Numeric) && f.real?) || f.respond_to?(:sample)

          f.is_a?(Numeric) ? f.to_f : f
        end

        # A number as a Float, or a node as the sampler branch of its slot
        # (one branch per distinct node).
        def sampled(v)
          return v.to_f if v.is_a?(Numeric)
          raise ArgumentError, "Filter bank settings are numbers or nodes (got #{v.inspect})" unless v.respond_to?(:sample)

          @signals[signal_slot(v, 'setting')[0].to_i]
        end

        # [slot, constant] for a setting (see mb_filter_bank.h): a number is
        # a constant, a node a slot (the same node, or its branch, the same
        # slot).
        def signal_slot(v, name)
          return [-1.0, v.to_f] if v.is_a?(Numeric) && v.real?
          raise ArgumentError, "The #{name} must be a number or a node (got #{v.inspect})" unless v.respond_to?(:sample)

          idx = @signal_index[v]
          unless idx
            branch = v.get_sampler
            idx = @signals.length
            @signals << branch
            @signal_index[v] = idx
            @signal_index[branch] = idx
          end
          [idx.to_f, 0.0]
        end

        # Raises for settings that don't fit together.
        def check_settings(explicit, morph)
          if @serial
            raise ArgumentError, 'Serial filter banks are mono (no pans or channels)' if @channels != 1 || @bands.any? { |b| b[:pan] || b[:gains] }
            raise ArgumentError, 'Serial filter banks take no normalize:' if @normalize
            raise ArgumentError, 'Serial filter banks take no morph tables' if morph
          end
          if @normalize == true && (bad = @bands.find { |b| !NORMALIZE_TYPES.include?(b[:type]) })
            raise ArgumentError, "normalize: is for bandpass banks (a band is #{bad[:type].inspect})"
          end
          raise ArgumentError, 'normalize: :width_law is for morph tables (Formant)' if @normalize == :width_law && !morph
          if @bands.any? { |b| b[:pan] } && @channels != 2
            raise ArgumentError, "Pans are positions between two channels (#{@channels} channels: give each band gains: with one gain per channel)"
          end
          raise ArgumentError, "Bands give #{explicit} channel gains for #{@channels} channels" if explicit && explicit != @channels
          if @channels > 2 && @bands.any? { |b| b[:gains].nil? }
            raise ArgumentError, "A #{@channels}-channel bank needs gains: (one per channel) on every band (surround placement comes later)"
          end
        end

        # The config values of band +b+ (see mb_filter_bank.h).
        def band_config(b)
          slot_of = ->(v) { v.is_a?(Numeric) ? [-1.0, v.to_f] : [@signal_index.fetch(v).to_f, 0.0] }
          type_id = Filter::SVF::FILTER_TYPE_IDS.fetch(b[:type]) + (b[:response] == :matched ? Filter::SVF::MATCHED : 0)
          pan_slot = b[:pan].nil? || b[:pan].is_a?(Numeric) ? [-1.0, 0.0] : slot_of.(b[:pan])
          [
            type_id, *slot_of.(b[:frequency]), *slot_of.(b[:ratio]), b[:harmonic],
            WIDTH_MODES.fetch(b[:width].mode), *slot_of.(b[:width].value), *slot_of.(b[:gain]), *pan_slot,
            *band_gains(b, nil)
          ]
        end

        # Band +b+'s gain into each channel (zeros for a node pan, whose
        # gains the kernel computes).
        def band_gains(b, _idx)
          return b[:gains] if b[:gains]
          return [1.0] * @channels if @channels == 1
          return [0.0, 0.0] if b[:pan].respond_to?(:sample)

          self.class.pan_gains(PAN_LAWS.fetch(@pan_law), b[:pan] || 0.0)
        end

        # Band +b+'s constant frequency in Hz, or nil if it moves.
        def band_frequency(b)
          return nil unless b[:frequency].is_a?(Numeric) && b[:ratio].is_a?(Numeric)

          b[:frequency] * (1.0 + b[:ratio] * b[:harmonic])
        end

        # Output buffers for +n+ samples: one set for a mono bank (reused,
        # like most nodes' buffers), two alternating sets for more channels
        # (the last frame's buffers stay valid while another output's
        # readers hold them).
        def output_buffers(n)
          sets = (@out_sets ||= [nil, nil])
          k = @channels == 1 ? 0 : (@out_index ^= 1)
          set = sets[k]
          if set.nil? || set[0].length != n
            set = sets[k] = Array.new(@channels) { Numo::SFloat.zeros(n) }
          end
          set
        end

        # Plan layer: a multichannel bank's channels are planned through its
        # Router (see FilterBank::Router).
        class Router
          include MultiOutput
          include Nameable
          # (the bank's state: #plan_snapshot)
          node_traits memory: :short, carry: :snapshot

          # The bank whose channels this router computes.
          attr_reader :bank

          # The channel outputs (FilterBank::Output nodes).
          attr_reader :outputs

          def initialize(bank)
            @bank = bank
            @outputs = Array.new(bank.channels) { |i| Output.new(router: self, index: i) }.freeze
            @sampled = Array.new(bank.channels, false)
            @frame = nil
            @node_type_name = 'FilterBank'

            # Set by the plan layer (see MB::Sound::Plan::MultiDescribable),
            # nil here so instances keep one object shape
            @plan_bypass = nil
            @plan_installations = nil
            @plan_member = nil
            @plan_region = nil
            @plan_observed = nil
            @plan_handoff = nil
            @plan_restart = nil
            @plan_excluded = nil
          end

          # Called by the outputs: computes a new frame when output +index+
          # comes back for one, and returns its buffer (nil once ended).
          def sample_internal(count, index)
            if @sampled[index] || @frame.nil?
              if @sampled.any? && !@sampled.all?
                warn "#{@bank} output #{index} sampled again before the other outputs"
              end
              @sampled.fill(false)
              @frame = plan_frame(count) || :ended
            end

            @sampled[index] = true
            @frame == :ended ? nil : @frame[index]
          end

          # One frame of every channel: from the plan region rooted here
          # while it plans, else the bank's own kernel call.
          def plan_frame(count)
            unless @plan_bypass
              if (handoff = @plan_handoff)
                @plan_handoff = nil
                buf = handoff[0].take_handoff(handoff[1], count)
                return handoff[1].planned_frame(buf) unless buf.equal?(Plan::LaneGroup::NO_HANDOFF)
              end

              region = @plan_region
              return region.sample_outputs(count) if region && !region.unfused
            end

            @bank.frame(count)
          end

          def sources
            @bank.sources
          end

          def sample_rate
            @bank.sample_rate
          end

          def sample_rate=(rate)
            @bank.sample_rate = rate
            self
          end
          alias at_rate sample_rate=

          # Plan layer (see Plan::MultiDescribable): every channel from one
          # Plan::Op::FilterBank in a region of its own; the outputs stay
          # outside, read by other regions as boundary inputs.
          include Plan::MultiDescribable

          def plan_inputs
            @bank.plan_inputs
          end

          def plan_describe(p)
            @bank.plan_values(p)
          end

          def plan_snapshot
            @bank.plan_snapshot
          end

          def plan_restore(snapshot)
            @bank.plan_restore(snapshot)
          end

          def to_s
            @bank.to_s
          end
        end

        # One channel of a multichannel FilterBank (see Router).
        class Output
          include GraphNode
          include GraphNode::NodeOutput
          node_traits memory: :none

          # The channel index.
          attr_reader :index

          def initialize(router:, index:)
            @owner = router
            @index = index
            @node_type_name = 'FilterBank'
          end

          def sample(count)
            @owner.sample_internal(count, @index)
          end

          def sample_rate
            @owner.sample_rate
          end

          def sample_rate=(rate)
            @owner.sample_rate = rate
            self
          end

          def sources
            { owner: @owner }
          end

          def to_s
            "#{@owner} output #{@index + 1} of #{@owner.outputs.length}"
          end

          # The router, which the plan layer computes in a region of its
          # own (see MB::Sound::Plan::MultiDescribable).
          def plan_owner
            @owner
          end
        end
      end

      Kernels.register :filter_bank, c: FastFilter.method(:filter_bank), ruby: FilterBank.method(:process_ruby)
    end
  end
end
