module MB
  module Sound
    module GraphNode
      # A phaser (phaser-1): a chain of first-order allpass stages, all at one
      # frequency swept by an LFO, mixed with the dry signal.  Each stage
      # turns the phase from 0 at DC through -90 degrees at its frequency to
      # -180 at Nyquist, so the chain of +stages+ (2-12, even) passes
      # through every odd multiple of -180 degrees stages / 2 times; there
      # the wet signal cancels the dry and the mix has a notch.  Notches of
      # four identical stages at fc sit at fc tan(pi/8) = 0.414 fc and
      # fc tan(3 pi/8) = 2.414 fc (see .notch_frequencies; exact for the
      # bilinear stages with prewarped frequencies), unequally spaced, unlike
      # a flanger's comb.  Feedback around the chain (signed, at most
      # MAX_FEEDBACK) sharpens the notches' neighbors into resonant peaks
      # (positive feedback peaks where the chain's phase is a whole number
      # of turns, negative ones halfway between).
      #
      # This node is one channel's chain; GraphNode#phaser (PhaserMethods)
      # builds the LFOs (Tone LFOs: sine or triangle, Hz or tempo-synced
      # lengths), stereo pairs, and presets (the :phaser family of the
      # library, `L.fx.phaser.jet`).  The stages' frequency is
      # center * 2 ** (range / 2 * depth * sweep), so a sweep of -1..1 and
      # depth 1 moves it +range+ octaves around +center+ (geometric).
      #
      # The kernel is MB::Sound::FastFilter.phaser (exact Ruby mirror
      # .process_ruby): topology-preserving one-pole allpasses with the
      # feedback loop solved in closed form (zero-delay feedback), so the
      # notches sit where the analysis says at any feedback; parameters
      # may move every sample, and the output is the same at any buffer
      # size.  Ends when the input or any parameter node ends.  A plan
      # boundary (one C call per buffer; see design/notes/phaser.md).
      class Phaser
        include GraphNode
        include SampleRateHelper
        # (its stages' state moves to a rebuilt phaser of the same stage
        # count: #carry_adopt)
        node_traits memory: :short, carry: :adopt

        extend MB::Sound::Presettable

        # The largest feedback magnitude (as in the kernel): peaks up to
        # 1 / (1 - 0.95) = +26 dB over the wet level.
        MAX_FEEDBACK = 0.95

        # The lowest stage frequency in Hz (as in the kernel).
        MIN_HZ = 1.0

        # Stage counts (even: odd counts leave the chain at -90 degrees at
        # DC... and Nyquist, a tilt instead of a notch pair).
        STAGES = (2..12).step(2).to_a.freeze

        # LFO shapes.
        SHAPES = %i[sine triangle].freeze

        # The settings GraphNode#phaser takes (besides a preset name or rate).
        KEYS = %i[rate depth stages feedback mix dry wet spread center range shape phase sweep].freeze

        preset_family :phaser, kind: :effect, label: 'phaser preset', keys: KEYS,
          about: 'Phasers: sig.phaser(:swirl)',
          apply: ->(name, input, **options) { input.phaser(name, **options) },
          code: ->(e) { "sig.phaser(#{e.name.inspect})" }

        param :rate, 0.5, range: 0.01..20.0, unit: 'Hz', description: 'LFO rate (Hz, or a musical length per cycle: 1.bar)'
        param :depth, 1.0, range: 0.0..1.0, description: 'Share of the range the LFO sweeps (0 holds the center)'
        param :stages, 4, range: 2..12, description: 'Allpass stages (even): notch pairs = stages / 2'
        param :feedback, 0.0, range: -MAX_FEEDBACK..MAX_FEEDBACK, description: 'Feedback around the stages (negative inverts; resonant peaks)'
        param :mix, 0.5, range: 0.0..1.0, description: 'Dry/wet crossfade, linear (0.5 deepest notches)'
        param :spread, 0.0, range: 0.0..1.0, unit: 'cycles', description: "Right LFO's phase offset from the left (0.5 opposite); stereo out"
        param :center, 700.0, range: 20.0..10000.0, unit: 'Hz', description: 'Sweep center frequency (geometric)'
        param :range, 4.0, range: 0.0..10.0, unit: 'octaves', description: 'Sweep width in octaves at depth 1'
        param :shape, :sine, range: SHAPES, description: 'LFO shape'
        param :phase, 0.0, range: 0.0..1.0, unit: 'cycles', description: "Left LFO's starting phase"

        preset :vintage, rate: 0.5, depth: 1.0, stages: 4, feedback: 0.0, mix: 0.5, spread: 0.0, center: 700.0, range: 4.0, shape: :sine,
          tags: %i[gentle four_stage classic], about: 'A four-stage phaser, two notches swept 175-2800 Hz at 0.5 Hz (the defaults)'
        preset :swirl, rate: 0.12, depth: 1.0, stages: 6, feedback: 0.3, mix: 0.5, spread: 0.25, center: 900.0, range: 6.0, shape: :triangle,
          tags: %i[slow wide stereo pad], about: 'A slow, wide stereo swirl: six stages over six octaves, the right LFO a quarter cycle ahead'
        preset :ripple, rate: 4.0, depth: 1.0, stages: 4, feedback: 0.2, mix: 0.5, spread: 0.0, center: 1200.0, range: 1.0, shape: :sine,
          tags: %i[fast shallow subtle], about: 'A fast, shallow shimmer: one octave around 1.2 kHz at 4 Hz'
        preset :deep12, rate: 0.2, depth: 1.0, stages: 12, feedback: 0.4, mix: 0.5, spread: 0.5, center: 800.0, range: 5.0, shape: :sine,
          tags: %i[deep twelve_stage stereo], about: 'Deep twelve-stage phasing (six notches), the sides opposite'
        preset :jet, rate: 0.08, depth: 1.0, stages: 8, feedback: 0.85, mix: 0.5, spread: 0.0, center: 1000.0, range: 6.0, shape: :triangle,
          tags: %i[resonant whoosh drums], about: 'A resonant jet whoosh: eight stages, strong feedback, a slow six-octave triangle'

        # The default preset (GraphNode#phaser without a preset name).
        DEFAULT_PRESET = :vintage

        # The input node (a sampler branch).
        attr_reader :input

        # The number of allpass stages.
        attr_reader :stages

        # Creates one channel's phaser on +input+: +stages+ allpasses at
        # center * 2 ** (range / 2 * depth * sweep) Hz, feedback around
        # them, dry * input + wet * chain as the output.  +sweep+ (the LFO,
        # -1..1), +center+ (Hz; a Pitch is its frequency), +range+
        # (octaves), +depth+, +feedback+, +dry+, and +wet+ are numbers or
        # nodes.
        def initialize(input, sweep: 0, center: 700, range: 4, depth: 1, feedback: 0, dry: 0.5, wet: 0.5, stages: 4, sample_rate: nil)
          raise ArgumentError, "Phaser input must be a graph node (got #{input.inspect})" unless input.respond_to?(:sample)
          stages = GraphNode.build_setting(stages)
          unless stages.is_a?(Integer) && STAGES.include?(stages)
            raise ArgumentError, "Phaser stages must be an even Integer from #{STAGES.first} to #{STAGES.last} (got #{stages.inspect})"
          end

          @input = input.get_sampler
          @sample_rate = (sample_rate || input.sample_rate).to_f
          @stages = stages
          center = center.oscillator_frequency if center.is_a?(MB::Sound::Pitch)
          @sweep = setting(sweep, 'sweep')
          @center = setting(center, 'center')
          @range = setting(range, 'range')
          @depth = setting(depth, 'depth')
          @feedback = setting(feedback, 'feedback')
          @dry = setting(dry, 'dry')
          @wet = setting(wet, 'wet')
          raise ArgumentError, "Phaser center must be positive (got #{@center})" if @center.is_a?(Float) && !(@center > 0)
          if @feedback.is_a?(Float) && @feedback.abs > MAX_FEEDBACK
            raise ArgumentError, "Phaser feedback must be within -#{MAX_FEEDBACK}..#{MAX_FEEDBACK} (got #{@feedback})"
          end

          @state = Numo::DFloat.zeros(stages + 1) # (and the flush grid count; see Filter::SVF::FLUSH_GRID)
          @out = nil
          @node_type_name = 'Phaser'
        end

        def sample(count)
          x = @input.sample(count)
          return nil if x.nil? || x.empty?
          n = x.length

          sw = @sweep.is_a?(Float) ? @sweep : @sweep.sample(n)
          c = @center.is_a?(Float) ? @center : @center.sample(n)
          r = @range.is_a?(Float) ? @range : @range.sample(n)
          d = @depth.is_a?(Float) ? @depth : @depth.sample(n)
          fb = @feedback.is_a?(Float) ? @feedback : @feedback.sample(n)
          dg = @dry.is_a?(Float) ? @dry : @dry.sample(n)
          wg = @wet.is_a?(Float) ? @wet : @wet.sample(n)
          # (no Arrays, no return from a block: every buffer; dropouts-2)
          return nil if ended_input?(sw) || ended_input?(c) || ended_input?(r) || ended_input?(d) || ended_input?(fb) || ended_input?(dg) || ended_input?(wg)
          n = shortest_length(n, sw)
          n = shortest_length(n, c)
          n = shortest_length(n, r)
          n = shortest_length(n, d)
          n = shortest_length(n, fb)
          n = shortest_length(n, dg)
          n = shortest_length(n, wg)
          x = x[0...n] if x.length > n
          sw = trimmed(sw, n)
          c = trimmed(c, n)
          r = trimmed(r, n)
          d = trimmed(d, n)
          fb = trimmed(fb, n)
          dg = trimmed(dg, n)
          wg = trimmed(wg, n)

          @out = Numo::SFloat.zeros(n) if @out.nil? || @out.length != n
          Kernels.phaser(@out, x, sw, c, r, d, fb, dg, wg, @state, @sample_rate)
        end

        # Takes over phaser +old+'s stage states (Session::Carry's adoption,
        # NodeTraits' +carry+ :adopt) when it has as many stages; a rebuild
        # with another stage count starts from silence.
        def carry_adopt(old)
          return unless old.stages == @stages
          NodeTraits.swap_ivars(self, old, ADOPT_IVARS)
        end

        ADOPT_IVARS = %i[@state].freeze

        def sources
          s = { input: @input }
          s[:sweep] = @sweep unless @sweep.is_a?(Float)
          s[:center] = @center unless @center.is_a?(Float)
          s[:range] = @range unless @range.is_a?(Float)
          s[:depth] = @depth unless @depth.is_a?(Float)
          s[:feedback] = @feedback unless @feedback.is_a?(Float)
          s[:dry] = @dry unless @dry.is_a?(Float)
          s[:wet] = @wet unless @wet.is_a?(Float)
          s
        end

        # Clears the stages' states.
        def reset
          @state.fill(0)
          self
        end

        def to_s
          c = @center.is_a?(Float) ? "#{MB::M.sigfigs(@center, 4)} Hz" : 'node Hz'
          fb = @feedback.is_a?(Float) ? (@feedback == 0 ? '' : ", feedback #{MB::M.sigfigs(@feedback, 3)}") : ', feedback node'
          "Phaser #{@stages} stages around #{c}#{fb}"
        end

        # The notch frequencies in Hz of +stages+ identical allpass stages at
        # +frequency+ Hz mixed equally with the dry signal, without feedback:
        # where the chain's phase is an odd multiple of -180 degrees.  Each
        # bilinear stage's phase is -2 atan(tan(pi f / rate) / tan(pi fc /
        # rate)), so tan(pi f / rate) = tan(pi fc / rate) tan((2k + 1) pi /
        # (2 stages)) for k = 0 ... stages / 2 - 1 (notches above Nyquist
        # left out).
        def self.notch_frequencies(stages, frequency, sample_rate: 48000)
          t = Math.tan(Math::PI * frequency / sample_rate)
          (0...(stages / 2)).filter_map { |k|
            a = (2 * k + 1) * Math::PI / (2 * stages)
            next nil if a >= Math::PI / 2
            Math.atan(t * Math.tan(a)) * sample_rate / Math::PI
          }
        end

        # The steady response (complex, a DComplex) at +freqs+ Hz of a
        # phaser with +stages+ stages at +frequency+ Hz, +feedback+, and
        # +dry+/+wet+ gains, at +sample_rate+: dry + wet H / (1 - k H), H
        # the chain's response, each stage the analog allpass
        # (wc - s) / (wc + s) through the prewarped bilinear map (s =
        # j tan(pi f / rate), wc = tan(pi fc / rate)).  For specs and plots
        # (the kernel's tan, MB::Sound::Filter::FourPole.tan, is within 4e-7
        # of Math.tan).
        def self.response(freqs, stages:, frequency:, feedback: 0, dry: 0.5, wet: 0.5, sample_rate: 48000)
          w = Numo::DFloat.cast(freqs) * (Math::PI / sample_rate)
          t = Math.tan(Math::PI * frequency / sample_rate)
          # Analog H(s) = (wc - s) / (wc + s) with s = j tan(w) and wc = t
          s = Numo::DComplex.cast(Numo::NMath.tan(w)) * Complex(0, 1)
          h = ((t - s) / (t + s)) ** stages
          h * wet / (1 - h * feedback) + dry
        end

        # The exact Ruby mirror of MB::Sound::FastFilter.phaser (same
        # arguments; see ruby_phaser in ext/mb/sound/fast_filter): the same
        # double operations in the same order, inputs read as float32
        # values, so specs compare the two for equality.
        def self.process_ruby(out, x, sweep, center, range, depth, feedback, dry, wet, state, sample_rate)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?
          unless state.is_a?(Numo::DFloat) && state.length >= 2 && state.length <= 65
            raise ArgumentError, 'The phaser state must be a contiguous DFloat of 2 to 65 values (one per stage and the flush grid count)'
          end

          n = out.length
          xs = signal_values(x, n)
          sws = signal_values(sweep, n)
          cs = signal_values(center, n)
          rs = signal_values(range, n)
          ds = signal_values(depth, n)
          fs = signal_values(feedback, n)
          drs = signal_values(dry, n)
          ws = signal_values(wet, n)

          stages = state.length - 1
          st = state.to_a
          fk = st[stages]
          fk = fk >= 0 && fk < Filter::SVF::FLUSH_GRID ? fk.to_i : 0
          pi_over_rate = Math::PI / rate
          fc_max = rate * Filter::FourPole::MAX_CUTOFF_RATIO
          half_ln2 = 0.5 * Math.log(2.0)
          flush = Filter::SVF::FLUSH

          last_fc = Float::NAN
          gg = alpha = beta = a_all = 0.0
          n.times do |i|
            fc = at(cs, i) * Math.exp(half_ln2 * at(rs, i) * at(ds, i) * at(sws, i))
            if !(fc >= MIN_HZ)
              fc = MIN_HZ
            elsif fc > fc_max
              fc = fc_max
            end
            # (NaN != NaN, as in C)
            if fc != last_fc
              last_fc = fc
              g = Filter::FourPole.tan(fc * pi_over_rate)
              gg = g / (1.0 + g)
              alpha = 2.0 * gg - 1.0
              beta = 2.0 * (1.0 - gg)
              a_all = 1.0
              stages.times { a_all = a_all * alpha }
            end

            k = at(fs, i)
            if !(k >= -MAX_FEEDBACK)
              k = k.nan? ? 0.0 : -MAX_FEEDBACK
            elsif k > MAX_FEEDBACK
              k = MAX_FEEDBACK
            end

            xi = at(xs, i)
            b = 0.0
            j = 0
            while j < stages
              b = alpha * b + beta * st[j]
              j += 1
            end
            u = (xi + k * b) / (1.0 - k * a_all)
            j = 0
            while j < stages
              s = st[j]
              v = (u - s) * gg
              lp = v + s
              st[j] = lp + v
              u = 2.0 * lp - u
              j += 1
            end
            out[i] = at(drs, i) * xi + at(ws, i) * u

            fk += 1
            if fk >= Filter::SVF::FLUSH_GRID
              fk = 0
              stages.times { |jj| v = st[jj]; st[jj] = 0.0 if !v.finite? || v.abs < flush }
            end
          end

          stages.times { |jj| state[jj] = st[jj] }
          state[stages] = fk.to_f
          out
        end

        # Value +i+ of a signal read by .signal_values.
        def self.at(values, i)
          values.is_a?(Array) ? values[i] : values
        end
        private_class_method :at

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

        def setting(value, name)
          value = Decibels.gain_of(value, "phaser #{name}", zero: true, above_one: true) if value.is_a?(Decibels)
          return value.to_f if value.is_a?(Numeric) && !value.is_a?(Complex)
          return value.get_sampler if value.respond_to?(:sample)
          raise ArgumentError, "Phaser #{name} must be a number or a node (got #{value.inspect})"
        end

        def ended_input?(v)
          !v.is_a?(Float) && (v.nil? || v.empty?)
        end

        def shortest_length(n, v)
          !v.is_a?(Float) && v.length < n ? v.length : n
        end

        def trimmed(v, n)
          v.is_a?(Float) || v.length == n ? v : v[0...n]
        end
      end

      Kernels.register :phaser, c: FastFilter.method(:phaser), ruby: Phaser.method(:process_ruby)

      class Phaser
        # Builds a phaser on +input+ (see PhaserMethods#phaser): +rate+ is a
        # preset name (Symbol) or the LFO rate, +options+ override the
        # preset's settings.  Returns a Phaser node for a mono input without
        # spread, else a stereo Channels bundle of two.
        def self.build(input, rate = nil, **options)
          bad = options.keys - KEYS
          unless bad.empty?
            guess = DidYouMean::SpellChecker.new(dictionary: KEYS).correct(bad[0]).first
            raise ArgumentError, "phaser: unknown option#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')}#{guess ? " (did you mean #{guess.inspect}?)" : ''}"
          end

          if rate.is_a?(Symbol) || rate.is_a?(String)
            preset = rate.to_sym
          else
            preset = DEFAULT_PRESET
            raise ArgumentError, 'phaser: give the rate once (positional or rate:)' if !rate.nil? && options.key?(:rate)
            options = options.merge(rate: rate) unless rate.nil?
          end
          s = { dry: 1, wet: 1, phase: 0.0, sweep: nil }.merge(preset_settings(preset))
          s.delete(:center) if options[:range].is_a?(Range)
          s.merge!(options)

          center, octaves = sweep_band(s[:center], s[:range], options.key?(:center))
          shape = s[:shape]
          raise ArgumentError, "phaser shape: is #{SHAPES.map(&:inspect).join(' or ')} (got #{shape.inspect})" unless SHAPES.include?(shape)
          feedback = s[:feedback]
          if feedback.is_a?(Numeric) && !(feedback.real? && feedback.abs <= MAX_FEEDBACK)
            raise ArgumentError, "phaser feedback: is within -#{MAX_FEEDBACK}..#{MAX_FEEDBACK} (got #{feedback.inspect})"
          end

          mix = s[:mix]
          mix = BlendMethods.amount(mix) unless mix.nil?
          dry, wet = level(s[:dry], 'dry'), level(s[:wet], 'wet')
          if mix
            dg, wg = BlendMethods.gains(mix, :linear)
            dry = StereoDelayMethods.level_product(dry, dg)
            wet = StereoDelayMethods.level_product(wet, wg)
          end

          spread = GraphNode.build_setting(s[:spread])
          phase = GraphNode.build_setting(s[:phase])
          spread = Phase.cycles(spread) if spread.is_a?(Phase)
          phase = Phase.cycles(phase) if phase.is_a?(Phase)
          raise ArgumentError, "phaser spread: is a number of cycles (got #{spread.inspect})" unless spread.is_a?(Numeric) && spread.real?
          raise ArgumentError, "phaser phase: is a number of cycles (got #{phase.inspect})" unless phase.is_a?(Numeric) && phase.real?

          sweep = s[:sweep]
          if sweep && spread != 0
            raise ArgumentError, 'phaser: a sweep: node drives both sides alike; spread: needs the built-in LFO'
          end
          raise ArgumentError, "phaser sweep: is a node (-1..1; got #{sweep.inspect})" if sweep && !sweep.respond_to?(:sample)

          l, r = StereoDelayMethods.sides(input, 'phaser')
          stereo = !l.equal?(r) || input.is_a?(Channels) && input.channel_count == 2 || spread != 0
          sample_rate = input.sample_rate
          make = ->(side, offset) {
            sw = sweep || lfo(s[:rate], shape, phase + offset, sample_rate)
            new(side, sweep: sw, center: center, range: octaves, depth: s[:depth], feedback: feedback, dry: dry, wet: wet,
              stages: s[:stages], sample_rate: sample_rate)
          }

          return make.(l, 0.0) unless stereo
          Channels.new([make.(l, 0.0), make.(r, spread.to_f)])
        end

        # [center Hz, octaves] for the +center+ and +range+ settings: a
        # Range of frequencies (Hz or Pitches) is the sweep's ends (its
        # geometric middle the center; +center_given+ raises), a number
        # or node the octaves around +center+.
        def self.sweep_band(center, range, center_given)
          center = center.oscillator_frequency if center.is_a?(MB::Sound::Pitch)
          if range.is_a?(Range)
            raise ArgumentError, 'phaser: give center: with a range: in octaves, or a range: of frequencies (lo..hi) alone' if center_given
            lo, hi = [range.begin, range.end].map { |f| f.is_a?(MB::Sound::Pitch) ? f.oscillator_frequency : f }
            unless lo.is_a?(Numeric) && hi.is_a?(Numeric) && lo > 0 && hi >= lo
              raise ArgumentError, "phaser range: of frequencies goes up from a positive frequency (got #{range.inspect})"
            end
            return [Math.sqrt(lo.to_f * hi.to_f), Math.log2(hi.to_f / lo.to_f)]
          end

          range = GraphNode.build_setting(range) unless range.respond_to?(:sample)
          unless range.respond_to?(:sample) || (range.is_a?(Numeric) && range.real? && range >= 0)
            raise ArgumentError, "phaser range: is octaves (a number or node) or a Range of frequencies (got #{range.inspect})"
          end
          unless center.respond_to?(:sample) || (center.is_a?(Numeric) && center.real? && center > 0)
            raise ArgumentError, "phaser center: is a positive frequency (Hz, a Pitch, or a node; got #{center.inspect})"
          end
          [center, range]
        end

        # A dry or wet level: Decibels, a number (negative inverts the
        # polarity, as wet and feedback phase switches do), or a node.
        def self.level(value, name)
          return Decibels.gain_of(value, "phaser #{name}", zero: true, above_one: true) if value.is_a?(Decibels)
          return value if value.respond_to?(:sample) || (value.is_a?(Numeric) && value.real?)
          raise ArgumentError, "phaser #{name}: is a level (a number, Decibels, or a node; got #{value.inspect})"
        end

        # The sweep LFO, a Tone of +shape+ starting at +phase+ cycles: +rate+
        # in Hz (a number, a Pitch, or a node of Hz), a musical length per
        # cycle (`1.bar`, `knob.bars`; follows the tempo and the timeline),
        # or a Length per cycle (`2.seconds`).
        def self.lfo(rate, shape, phase, sample_rate)
          rate = GraphNode.build_setting(rate) unless rate.respond_to?(:sample)
          tone = case rate
                 when Numeric
                   raise ArgumentError, "phaser rate: must not be negative (got #{rate})" unless rate.real? && rate >= 0
                   rate.to_f.hz.lfo
                 when Length then (1.0 / rate.to_seconds(sample_rate: sample_rate)).hz.lfo
                 when GraphNode then rate.tone.lfo
                 else
                   unless rate.respond_to?(:lfo)
                     raise ArgumentError, "phaser rate: is Hz, a Pitch, a musical length (1.bar), a Length, or a node of Hz (got #{rate.inspect})"
                   end
                   rate.lfo
                 end
          tone = shape == :triangle ? tone.triangle : tone.sine
          tone = tone.with_phase(phase) unless phase == 0
          tone.at_rate(sample_rate)
          tone
        end
      end
    end
  end
end
