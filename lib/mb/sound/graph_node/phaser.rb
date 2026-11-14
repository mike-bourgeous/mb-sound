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

        # The self-oscillating loop (effects-4, +oscillate:+; the kernel
        # MB::Sound::FastFilter.phaser_osc): feedback up to this magnitude
        # (the loop gain at the oscillating mode; above 1 it oscillates),
        # the mode bandpass's Q, Newton steps per sample, and the kick that
        # starts an oscillation from silence (added to the bandpass's first
        # state while |feedback| > 1 and its states sum under OSC_QUIET).
        OSC_MAX_FEEDBACK = 1.25
        OSC_Q = 4.0
        OSC_NEWTON = 3
        OSC_QUIET = 1e-9
        OSC_KICK = 1e-3

        # The lowest stage frequency in Hz (as in the kernel).
        MIN_HZ = 1.0

        # Stage counts (even: odd counts leave the chain at -90 degrees at
        # DC... and Nyquist, a tilt instead of a notch pair).  Up to 32
        # since effects-3 (the plug-in in the maintainer's .acd song reads
        # 32; the kernel takes 64).
        STAGES = (2..32).step(2).to_a.freeze

        # Named sweep directions for a barber-pole phaser (+direction:+,
        # also a signed number or node of speed; nil is the LFO's
        # back-and-forth sweep).
        DIRECTIONS = %i[up down].freeze

        # Staggered chains of a barber-pole phaser: each sweeps the range
        # one way in turn, faded in and out by a raised cosine so its jump
        # back is silent; three a third of a cycle apart sum to a steady
        # wet level (each window scaled by 2/3).
        BARBER_CHAINS = 3

        # LFO shapes.
        SHAPES = %i[sine triangle].freeze

        # The settings GraphNode#phaser takes (besides a preset name or rate).
        KEYS = %i[rate depth stages feedback mix dry wet spread center range shape phase sweep above amount direction lean oscillate].freeze

        # Feedback magnitude that amount: 1 reaches (see .amount_settings).
        AMOUNT_FEEDBACK = 0.9

        # Seconds over which +lean:+'s feedback moves between the LFO's
        # halves (a #smooth S-curve at each turn of the sweep).
        LEAN_SMOOTH = 0.05

        preset_family :phaser, kind: :effect, label: 'phaser preset', keys: KEYS,
          about: 'Phasers: sig.phaser(:swirl)',
          apply: ->(name, input, **options) { input.phaser(name, **options) },
          code: ->(e) { "sig.phaser(#{e.name.inspect})" }

        param :rate, 0.5, range: 0.01..20.0, unit: 'Hz', description: 'LFO rate (Hz, or a musical length per cycle: 1.bar)'
        param :depth, 1.0, range: 0.0..1.0, description: 'Share of the range the LFO sweeps (0 holds the center)'
        param :stages, 4, range: 2..32, description: 'Allpass stages (even): notch pairs = stages / 2'
        param :feedback, 0.0, range: -MAX_FEEDBACK..MAX_FEEDBACK, description: 'Feedback around the stages (negative inverts; resonant peaks)'
        param :mix, 0.5, range: 0.0..1.0, description: 'Dry/wet crossfade, linear (0.5 deepest notches)'
        param :spread, 0.0, range: 0.0..1.0, unit: 'cycles', description: "Right LFO's phase offset from the left (0.5 opposite); stereo out"
        param :center, 700.0, range: 20.0..10000.0, unit: 'Hz', description: 'Sweep center frequency (geometric)'
        param :range, 4.0, range: 0.0..10.0, unit: 'octaves', description: 'Sweep width in octaves at depth 1'
        param :shape, :sine, range: SHAPES, description: 'LFO shape'
        param :phase, 0.0, range: 0.0..1.0, unit: 'cycles', description: "Left LFO's starting phase"
        param :above, nil, range: 20.0..2000.0, unit: 'Hz', description: 'Keeps the lows dry below this crossover (Linkwitz-Riley, 4th order)'
        param :amount, 0.5, range: 0.0..1.0, description: 'Light (0) to extreme (1): depth, mix, feedback, and stages together (0.5 the preset)'
        param :direction, nil, range: -4.0..4.0, description: 'Barber pole: notches climbing (:up, > 0) or falling (:down, < 0) forever, the size scaling the speed'
        param :oscillate, nil, range: 0..15, description: 'Self-oscillating loop on one mode (0 the lowest notch with negative feedback); feedback past 1 whistles'
        param :lean, nil, range: -1.0..1.0, description: 'Feedback on one half of the sweep: 1 only while it rises, -1 only while it falls (a one-way whoosh)'

        preset :vintage, rate: 0.5, depth: 1.0, stages: 4, feedback: 0.0, mix: 0.5, spread: 0.0, center: 700.0, range: 4.0, shape: :sine,
          tags: %i[gentle four_stage classic], about: 'A four-stage phaser, two notches swept 175-2800 Hz at 0.5 Hz (the defaults)'
        preset :swirl, rate: 0.12, depth: 1.0, stages: 6, feedback: 0.3, mix: 0.5, spread: 0.25, center: 900.0, range: 6.0, shape: :triangle,
          tags: %i[slow wide stereo pad], about: 'A slow, wide stereo swirl: six stages over six octaves, the right LFO a quarter cycle ahead'
        preset :ripple, rate: 4.0, depth: 1.0, stages: 4, feedback: 0.2, mix: 0.5, spread: 0.0, center: 1200.0, range: 1.0, shape: :sine,
          tags: %i[fast shallow subtle], about: 'A fast, shallow shimmer: one octave around 1.2 kHz at 4 Hz'
        preset :deep12, rate: 0.2, depth: 1.0, stages: 12, feedback: 0.4, mix: 0.5, spread: 0.5, center: 800.0, range: 5.0, shape: :sine,
          tags: %i[deep twelve_stage stereo], about: 'Deep twelve-stage phasing (six notches), the sides opposite'
        preset :jet, rate: 0.08, depth: 1.0, stages: 8, feedback: 0.85, mix: 0.5, spread: 0.0, center: 1000.0, range: 6.0, shape: :triangle, above: 150.0,
          tags: %i[resonant whoosh drums], about: 'A resonant jet whoosh: eight stages, strong feedback, a slow six-octave triangle, dry below 150 Hz'
        preset :barberpole, rate: 0.1, depth: 1.0, stages: 8, feedback: 0.6, mix: 0.5, spread: 0.0, center: 1000.0, range: 6.0, shape: :sine, direction: :up,
          tags: %i[endless rising shepard], about: 'A barber pole: notches climbing forever (direction: :down falls), staggered sweeps crossfaded'

        # The default preset (GraphNode#phaser without a preset name).
        DEFAULT_PRESET = :vintage

        # The input node (a sampler branch).
        attr_reader :input

        # The number of allpass stages.
        attr_reader :stages

        # The self-oscillating loop's mode index, or nil (see #initialize).
        attr_reader :oscillate

        # Creates one channel's phaser on +input+: +stages+ allpasses at
        # center * 2 ** (range / 2 * depth * sweep) Hz, feedback around
        # them, dry * input + wet * chain as the output.  +sweep+ (the LFO,
        # -1..1), +center+ (Hz; a Pitch is its frequency), +range+
        # (octaves), +depth+, +feedback+, +dry+, and +wet+ are numbers or
        # nodes.
        #
        # +oscillate+ (effects-4): nil for the linear loop above, or a mode
        # index (0 the lowest; see .mode_frequency) for the self-oscillating
        # loop: the chain's output saturated (tanh) and bandpassed at that
        # mode in the feedback path, +feedback+ up to OSC_MAX_FEEDBACK, so
        # above 1 the phaser whistles on that one mode at a level the
        # saturator sets, with or without input.
        def initialize(input, sweep: 0, center: 700, range: 4, depth: 1, feedback: 0, dry: 0.5, wet: 0.5, stages: 4, oscillate: nil, sample_rate: nil)
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
          oscillate = GraphNode.build_setting(oscillate)
          unless oscillate.nil? || (oscillate.is_a?(Integer) && oscillate >= 0)
            raise ArgumentError, "Phaser oscillate must be nil or a mode index from 0 (got #{oscillate.inspect})"
          end
          @oscillate = oscillate
          limit = oscillate ? OSC_MAX_FEEDBACK : MAX_FEEDBACK
          if @feedback.is_a?(Float) && @feedback.abs > limit
            raise ArgumentError, "Phaser feedback must be within -#{limit}..#{limit}#{' (oscillate: up to 1.25)' unless oscillate} (got #{@feedback})"
          end

          # (and the flush grid count, see Filter::SVF::FLUSH_GRID; oscillating: the
          # bandpass's two states and the last output before it)
          @state = Numo::DFloat.zeros(stages + (oscillate ? 4 : 1))
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
          return Kernels.phaser_osc(@out, x, sw, c, r, d, fb, dg, wg, @state, @sample_rate, @oscillate) if @oscillate
          Kernels.phaser(@out, x, sw, c, r, d, fb, dg, wg, @state, @sample_rate)
        end

        # Takes over phaser +old+'s stage states (Session::Carry's adoption,
        # NodeTraits' +carry+ :adopt) when it has as many stages; a rebuild
        # with another stage count starts from silence.
        def carry_adopt(old)
          return unless old.stages == @stages && old.oscillate == @oscillate
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
          "Phaser #{@stages} stages around #{c}#{fb}#{", oscillating on mode #{@oscillate}" if @oscillate}"
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

        # The frequency in Hz of oscillation mode +mode+ (0 the lowest) of
        # +stages+ stages at +frequency+ Hz with feedback of +feedback+'s
        # sign (#phaser's +:oscillate+): negative feedback oscillates where
        # the chain's phase is an odd multiple of -180 degrees, the
        # dry-mixed phaser's notches (tan(pi f / rate) = tan(pi fc / rate)
        # tan((2 mode + 1) pi / (2 stages)), stages / 2 modes); positive
        # feedback where it is a whole number of turns, the peaks between
        # them (tan((mode + 1) pi / stages), stages / 2 - 1 modes).  A mode
        # past the last is the last.  The kernel's bandpass stops at rate *
        # Filter::FourPole::MAX_CUTOFF_RATIO.
        def self.mode_frequency(stages, frequency, mode: 0, feedback: -1, sample_rate: 48000)
          Math.atan(Math.tan(Math::PI * frequency / sample_rate) * mode_tangent(stages, mode, feedback)) * sample_rate / Math::PI
        end

        # The phaser frequency (+center:+, or a sweep end) at which mode
        # +mode+ oscillates at +hz+ (the inverse of .mode_frequency), for
        # fitting a phaser to a measured whistle: `range: lo..hi` with
        # lo = .mode_center(stages, 250) and hi = .mode_center(stages, 2110).
        def self.mode_center(stages, hz, mode: 0, feedback: -1, sample_rate: 48000)
          Math.atan(Math.tan(Math::PI * hz / sample_rate) / mode_tangent(stages, mode, feedback)) * sample_rate / Math::PI
        end

        # tan of the chain phase step of mode +mode+ (see .mode_frequency).
        def self.mode_tangent(stages, mode, feedback)
          if feedback < 0
            m = MB::M.min(mode, stages / 2 - 1)
            Math.tan((2.0 * m + 1.0) * Math::PI / (2.0 * stages))
          else
            count = stages / 2 - 1
            return 1.0 if count <= 0
            Math.tan((MB::M.min(mode, count - 1) + 1.0) * Math::PI / stages)
          end
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

        # The exact Ruby mirror of MB::Sound::FastFilter.phaser_osc (the
        # self-oscillating loop: see ruby_phaser_osc in ext/mb/sound/
        # fast_filter and OSC_MAX_FEEDBACK): the same double operations in
        # the same order, inputs read as float32 values.  +state+ holds
        # stages + 4 values; +mode+ is the oscillation mode (0 the lowest).
        def self.process_osc_ruby(out, x, sweep, center, range, depth, feedback, dry, wet, state, sample_rate, mode)
          rate = sample_rate.to_f
          raise ArgumentError, 'Sample rate must be positive and finite' unless rate > 0 && rate.finite?
          unless state.is_a?(Numo::DFloat) && state.length >= 6 && state.length <= 68
            raise ArgumentError, 'The oscillating phaser state must be a contiguous DFloat of 6 to 68 values (one per stage, two bandpass states, the last output, and the flush grid count)'
          end
          mode = Integer(mode)
          raise ArgumentError, 'The oscillation mode must be at least 0' if mode < 0

          n = out.length
          xs = signal_values(x, n)
          sws = signal_values(sweep, n)
          cs = signal_values(center, n)
          rs = signal_values(range, n)
          ds = signal_values(depth, n)
          fs = signal_values(feedback, n)
          drs = signal_values(dry, n)
          ws = signal_values(wet, n)

          stages = state.length - 4
          st = state.to_a
          pi_over_rate = Math::PI / rate
          fc_max = rate * Filter::FourPole::MAX_CUTOFF_RATIO
          half_ln2 = 0.5 * Math.log(2.0)
          g2_max = Filter::FourPole.tan(fc_max * pi_over_rate)
          r2 = 1.0 / OSC_Q
          flush = Filter::SVF::FLUSH

          neg_count = stages / 2
          pos_count = stages / 2 - 1
          mn = mode < neg_count ? mode : neg_count - 1
          tan_neg = Math.tan((2.0 * mn + 1.0) * Math::PI / (2.0 * stages))
          tan_pos = 1.0
          if pos_count > 0
            mp = mode < pos_count ? mode : pos_count - 1
            tan_pos = Math.tan((mp + 1.0) * Math::PI / stages)
          end

          s1 = st[stages]
          s2 = st[stages + 1]
          yl = st[stages + 2]
          fk = st[stages + 3]
          fk = fk >= 0 && fk < Filter::SVF::FLUSH_GRID ? fk.to_i : 0
          fl = ->(v) { !v.finite? || v.abs < flush ? 0.0 : v }

          last_fc = Float::NAN
          g = gg = alpha = beta = a_all = 0.0
          n.times do |i|
            fc = at(cs, i) * Math.exp(half_ln2 * at(rs, i) * at(ds, i) * at(sws, i))
            if !(fc >= MIN_HZ)
              fc = MIN_HZ
            elsif fc > fc_max
              fc = fc_max
            end
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
            if !(k >= -OSC_MAX_FEEDBACK)
              k = k.nan? ? 0.0 : -OSC_MAX_FEEDBACK
            elsif k > OSC_MAX_FEEDBACK
              k = OSC_MAX_FEEDBACK
            end

            xd = at(xs, i)
            xi = xd
            s1 = s1 + OSC_KICK if k.abs > 1.0 && s1.abs + s2.abs < OSC_QUIET

            g2 = g * (k < 0.0 ? tan_neg : tan_pos)
            g2 = g2_max if g2 > g2_max
            dd = 1.0 + r2 * g2 + g2 * g2
            p = r2 * g2 / dd
            q0 = r2 * (s1 - g2 * ((r2 + g2) * s1 + s2) / dd)

            b = 0.0
            j = 0
            while j < stages
              b = alpha * b + beta * st[j]
              j += 1
            end
            c1 = a_all * (xi + k * q0) + b
            c2 = a_all * k * p
            y = yl
            OSC_NEWTON.times do
              t = Math.tanh(y)
              f = y - c2 * t - c1
              fp = 1.0 - c2 * (1.0 - t * t)
              y = y - f / fp
            end
            sat = Math.tanh(y)
            w = p * sat + q0

            u = xi + k * w
            j = 0
            while j < stages
              sv = st[j]
              v = (u - sv) * gg
              lp = v + sv
              st[j] = lp + v
              u = 2.0 * lp - u
              j += 1
            end

            hp = (sat - (r2 + g2) * s1 - s2) / dd
            v1 = g2 * hp
            bp = v1 + s1
            s1 = bp + v1
            v2 = g2 * bp
            lpo = v2 + s2
            s2 = lpo + v2
            yl = u

            out[i] = at(drs, i) * xd + at(ws, i) * u

            fk += 1
            if fk >= Filter::SVF::FLUSH_GRID
              fk = 0
              stages.times { |jj| st[jj] = fl.(st[jj]) }
              s1 = fl.(s1)
              s2 = fl.(s2)
              yl = fl.(yl)
            end
          end

          stages.times { |jj| state[jj] = st[jj] }
          state[stages] = s1
          state[stages + 1] = s2
          state[stages + 2] = yl
          state[stages + 3] = fk.to_f
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
      Kernels.register :phaser_osc, c: FastFilter.method(:phaser_osc), ruby: Phaser.method(:process_osc_ruby)

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
          preset_s = preset_settings(preset)

          # (given, or the preset's: :jet keeps its lows dry since effects-4;
          # above: nil turns that off)
          above = options.key?(:above) ? options[:above] : preset_s[:above]
          if above
            # (the lows split off and kept dry; the phaser on the highs)
            return crossover(input, above, preset, options.merge(above: nil))
          end

          s = { dry: 1, wet: 1, phase: 0.0, sweep: nil, above: nil, amount: nil, direction: nil, lean: nil, oscillate: nil }.merge(preset_s)
          s.delete(:center) if options[:range].is_a?(Range)
          s.merge!(options)
          amount_settings(s) unless s[:amount].nil?

          center, octaves = sweep_band(s[:center], s[:range], options.key?(:center))
          shape = s[:shape]
          raise ArgumentError, "phaser shape: is #{SHAPES.map(&:inspect).join(' or ')} (got #{shape.inspect})" unless SHAPES.include?(shape)
          oscillate = GraphNode.build_setting(s[:oscillate])
          oscillate = 0 if oscillate == true
          oscillate = nil if oscillate == false
          unless oscillate.nil? || (oscillate.is_a?(Integer) && oscillate >= 0)
            raise ArgumentError, "phaser oscillate: is true (mode 0) or a mode index from 0 (0 the lowest; got #{oscillate.inspect})"
          end
          feedback = s[:feedback]
          limit = oscillate ? OSC_MAX_FEEDBACK : MAX_FEEDBACK
          if feedback.is_a?(Numeric) && !(feedback.real? && feedback.abs <= limit)
            raise ArgumentError, "phaser feedback: is within -#{limit}..#{limit}#{' (past +-1 with oscillate:)' unless oscillate} (got #{feedback.inspect})"
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
          direction = barber_speed(s[:direction])
          lean = s[:lean]
          lean = GraphNode.build_setting(lean) unless lean.respond_to?(:sample)
          lean = nil if lean.is_a?(Numeric) && lean == 0
          unless lean.nil? || lean.respond_to?(:sample) || (lean.is_a?(Numeric) && lean.real? && lean.abs <= 1)
            raise ArgumentError, "phaser lean: is from -1 (feedback only while the sweep falls) to 1 (only while it rises), or a node (got #{lean.inspect})"
          end
          raise ArgumentError, 'phaser lean: follows the built-in LFO; give it or sweep:, not both' if lean && sweep
          raise ArgumentError, 'phaser lean: is for a back-and-forth sweep; a barber pole (direction:) only moves one way' if lean && !direction.nil?
          raise ArgumentError, 'phaser oscillate: is for one chain; a barber pole (direction:) crossfades three' if oscillate && !direction.nil?
          # (a node's |lean| once for both sides: a .tee of the node per side
          # trips the shared-buffer check, see design/notes/phaser.md)
          lean = [lean, lean.aabs] if lean.respond_to?(:sample)
          raise ArgumentError, 'phaser: direction: makes its own sweeps; give it or sweep:, not both' if !direction.nil? && sweep

          l, r = StereoDelayMethods.sides(input, 'phaser')
          stereo = !l.equal?(r) || input.is_a?(Channels) && input.channel_count == 2 || spread != 0
          sample_rate = input.sample_rate
          make = ->(side, offset) {
            unless direction.nil?
              next barber(side, s, direction, phase + offset, center, octaves, feedback, dry, wet, sample_rate)
            end
            sw = sweep || ModulationLfo.tone(s[:rate], shape: shape, phase: phase + offset, sample_rate: sample_rate, what: 'phaser')
            fb = lean ? lean_feedback(feedback, lean, s[:rate], phase + offset, sample_rate) : feedback
            new(side, sweep: sw, center: center, range: octaves, depth: s[:depth], feedback: fb, dry: dry, wet: wet,
              stages: s[:stages], oscillate: oscillate, sample_rate: sample_rate)
          }

          return make.(l, 0.0) unless stereo
          Channels.new([make.(l, 0.0), make.(r, spread.to_f)])
        end

        # A barber-pole phaser on +side+ at signed speed +direction+ (a
        # number or a node; see .barber_speed): BARBER_CHAINS phasers, each
        # swept once across the range per LFO cycle by a ramp (exact: an
        # aliased saw, below audio rates), a third of a cycle apart, each
        # chain's wet faded by a raised cosine that is silent where its ramp
        # jumps back, so the notches seem to climb (or fall) forever, like a
        # Shepard-Risset tone.  The windows sum to 1 (2/3 each at three
        # chains); the dry signal once.  Ramps and windows read one phase
        # per chain, so a speed node that changes sign turns the notches
        # around where they are (no jump, no crossfade needed), and 0 holds
        # them still.
        def self.barber(side, s, direction, phase, center, octaves, feedback, dry, wet, sample_rate)
          side = side.get_sampler
          n = BARBER_CHAINS
          numeric = direction.is_a?(Numeric)
          rate = barber_rate(s[:rate], numeric ? direction.abs : direction, sample_rate)
          chains = Array.new(n) { |i|
            offset = phase + i / n.to_f
            ramp = ModulationLfo.rate_tone(rate, sample_rate: sample_rate, what: 'phaser').asaw
            ramp.with_phase(offset % 1) unless offset % 1 == 0
            # (the ramp is at its middle at phase 0 and jumps at 0.5; the
            # window peaks at its middle and is 0 at the jump)
            win = ModulationLfo.tone(rate, shape: :sine, phase: offset + 0.25, sample_rate: sample_rate, what: 'phaser')
            win = win * (1.0 / n) + (1.0 / n)
            # (a node speed runs the phase itself backward when negative)
            sw = numeric && direction < 0 ? ramp * -1 : ramp
            new(side, sweep: sw, center: center, range: octaves, depth: s[:depth], feedback: feedback, dry: 0, wet: Chorus.scale(win, wet) || win * 0,
              stages: s[:stages], sample_rate: sample_rate)
          }
          d = Chorus.scale(side, dry)
          Mixer.new(d ? [d, *chains] : chains, sample_rate: sample_rate, stop_early: false)
        end

        # Feedback +feedback+ (a number or node) leaning to one half of the
        # LFO's cycle by +lean+ (-1..1 or a node; effects-4, the
        # maintainer's hypothesis "setting the feedback high on the
        # descending half of the LFO phase and low on the ascending phase
        # ... will give exactly the descending-only or ascending-only
        # sound"): the full feedback while the sweep moves the leaning way
        # (rising for a positive lean), feedback x (1 - |lean|) while it
        # moves back, moving between them over LEAN_SMOOTH at each turn.
        # The LFO (sine or triangle, middle rising at phase 0) rises from
        # phase -0.25 to 0.25: a square a quarter cycle ahead at +rate+
        # and +phase+ marks it (+1 rising), locked to the LFO.
        def self.lean_feedback(feedback, lean, rate, phase, sample_rate)
          return feedback if feedback.is_a?(Numeric) && feedback == 0
          rising = ModulationLfo.rate_tone(rate, sample_rate: sample_rate, what: 'phaser').asquare
          rising.with_phase((phase + 0.25) % 1) unless (phase + 0.25) % 1 == 0
          rising = rising.smooth(LEAN_SMOOTH)
          # scale = 1 - (|lean| - lean x rising) / 2; a node lean comes as
          # [lean, |lean|] (built once by .build for both sides, each reader
          # taking its own branch)
          scale = if lean.is_a?(Numeric)
                    rising * (0.5 * lean) + (1 - 0.5 * lean.abs)
                  else
                    lean, lean_abs = lean.is_a?(Array) ? lean : [lean, lean.aabs]
                    lean_abs * -0.5 + lean * rising * 0.5 + 1
                  end
          feedback.is_a?(Numeric) ? scale * feedback.to_f : scale * feedback
        end

        # The barber pole's signed speed for the +direction:+ setting: nil
        # (no barber pole), :up (1.0), :down (-1.0), a number, or a node.
        # The sign is the way the notches move, the magnitude scales the
        # sweep rate (1 the preset's rate, 2 twice as fast, 0 held still).
        def self.barber_speed(direction)
          direction = GraphNode.build_setting(direction) unless direction.respond_to?(:sample)
          case direction
          when nil then nil
          when :up then 1.0
          when :down then -1.0
          when Numeric
            unless direction.real? && direction.finite?
              raise ArgumentError, "phaser direction: is a finite number (got #{direction.inspect})"
            end
            direction.to_f
          else
            return direction if direction.respond_to?(:sample)
            raise ArgumentError, "phaser direction: is #{DIRECTIONS.map(&:inspect).join(' or ')}, a number (its sign the way the notches " \
              "move, its size the speed; 1 the preset's rate), or a node, for a barber pole; or nil (got #{direction.inspect})"
          end
        end

        # The rate of a barber pole's ramps for the phaser +rate+ setting at
        # +speed+: a number at least 0 (the rate itself at 1; a musical
        # length shortened, so it stays locked to the timeline) or a node
        # (signed: a node of Hz, the rate times the speed, its phase free of
        # the timeline).
        def self.barber_rate(rate, speed, sample_rate)
          rate = GraphNode.build_setting(rate) unless rate.respond_to?(:sample)
          if speed.is_a?(Numeric)
            return rate if speed == 1
            return 0.0 if speed == 0
            return rate / speed if rate.is_a?(Sequence::Duration)
          end

          hz = case rate
               when Sequence::Duration, Sequence::NodeDuration then rate.hz.oscillator_frequency
               when Pitch then rate.oscillator_frequency
               when Numeric then rate.to_f
               when Length then 1.0 / rate.to_seconds(sample_rate: sample_rate)
               else
                 raise ArgumentError, "phaser rate: is Hz, a Pitch, a musical length, a Length, or a node of Hz (got #{rate.inspect})" unless rate.respond_to?(:sample)
                 rate
               end
          return hz * speed if hz.is_a?(Numeric) && speed.is_a?(Numeric)
          hz.is_a?(Numeric) ? speed * hz : hz * speed
        end

        # Phaser +rate+ (a preset name or rate, as for .build) with +options+ on the highs of +input+ above
        # +frequency+ (Hz or a Pitch), the lows kept dry: a 4th-order
        # Linkwitz-Riley split (#bands), so the two sum flat (an allpass) where
        # the phaser leaves the highs alone.  A mono input with spread comes
        # back stereo, the low band in both sides.
        def self.crossover(input, frequency, rate, options)
          frequency = GraphNode.build_setting(frequency)
          frequency = frequency.oscillator_frequency if frequency.is_a?(MB::Sound::Pitch)
          unless frequency.is_a?(Numeric) && frequency.real? && frequency > 0 && frequency < input.sample_rate / 2
            raise ArgumentError, "phaser above: is a crossover frequency in Hz below Nyquist (got #{frequency.inspect})"
          end
          lo, hi = input.bands(frequency.to_f)
          wet = build(hi, rate, **options)
          lows = lo.outputs
          outs = wet.outputs.each_with_index.map { |w, i|
            Mixer.new([lows.length == 1 ? lows[0] : lows[i], w], sample_rate: input.sample_rate, stop_early: false)
          }
          outs.length == 1 ? outs[0] : Channels.new(outs)
        end

        # Applies the +:amount+ macro to settings +s+ (in place): 0.5 leaves
        # them as they are; toward 0 depth falls to a quarter, the mix to
        # 0.3 of itself, and feedback to 0; toward 1 depth rises to 1, the mix
        # to 0.5 (the deepest notches), feedback to +-AMOUNT_FEEDBACK (the
        # preset's sign), and a numeric amount doubles the stages (up to
        # 32; halves them toward 0, at least 2).  A node amount moves depth,
        # mix, and feedback live (stages stay).  Settings given as nodes
        # stay as given.
        def self.amount_settings(s)
          a = GraphNode.build_setting(s[:amount])
          if a.is_a?(Numeric)
            raise ArgumentError, "phaser amount: is from 0 (light) to 1 (extreme; got #{a.inspect})" unless a.real? && a >= 0 && a <= 1
            a = a.to_f
            t = MB::M.min(a * 2, 1.0)
            u = MB::M.max(a * 2 - 1, 0.0)
            st = GraphNode.build_setting(s[:stages])
            if st.is_a?(Integer)
              scaled = st * 2.0**(u - (1 - t))
              s[:stages] = ((scaled / 2).round * 2).clamp(STAGES.first, STAGES.last)
            end
          elsif a.respond_to?(:sample)
            a = a.get_sampler
            a2 = a.aclip(0, 1).tee(2)
            t = (a2[0] * 2).aclip(0, 1)
            u = (a2[1] * 2 - 1).aclip(0, 1)
          else
            raise ArgumentError, "phaser amount: is a number from 0 (light) to 1 (extreme) or a node (got #{a.inspect})"
          end

          ts = t.respond_to?(:sample) ? t.tee(3) : [t, t, t]
          us = u.respond_to?(:sample) ? u.tee(3) : [u, u, u]
          # (numbers: v (1 - k (1 - t)) + (top - v) u, exactly v at 0.5)
          depth = GraphNode.build_setting(s[:depth])
          s[:depth] = amount_curve(depth, 0.75, 1.0, ts[0], us[0]) if depth.is_a?(Numeric)
          mix = GraphNode.build_setting(s[:mix])
          s[:mix] = amount_curve(mix, 0.7, MB::M.max(mix, 0.5), ts[1], us[1]) if mix.is_a?(Numeric)
          fb = GraphNode.build_setting(s[:feedback])
          s[:feedback] = amount_curve(fb, 1.0, (fb < 0 ? -1 : 1) * AMOUNT_FEEDBACK, ts[2], us[2]) if fb.is_a?(Numeric)
          s
        end

        # Setting +v+ under the amount macro: v (1 - +k+ (1 - t)) on the way
        # up to 0.5 (t 0..1), then on toward +top+ (u 0..1); t and u numbers
        # or nodes.
        def self.amount_curve(v, k, top, t, u)
          v = v.to_f
          return v * (1 - k * (1 - t)) + (top - v) * u if t.is_a?(Numeric)
          t * (k * v) + (v * (1 - k)) + u * (top - v)
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
      end
    end
  end
end
