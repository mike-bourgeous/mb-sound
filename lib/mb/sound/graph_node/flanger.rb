module MB
  module Sound
    module GraphNode
      # A flanger (effects-2): the input plus a copy through a short delay
      # swept by an LFO, with feedback around the delay.  Mixed equally,
      # the two cancel wherever the delay is an odd number of half
      # periods, a comb of notches at (2k + 1) / (2 t) Hz (and peaks at
      # k / t); sweeping t moves the whole comb, the jet-plane whoosh.
      # Positive feedback sharpens the peaks at k / t, negative feedback
      # moves them to the old notches ((2k + 1) / (2 t), a hollow,
      # metallic sound an octave up).
      #
      # Built from the library's delay pieces, no delay engine of its own:
      # #delay with a node time (DelayLine, sinc reads) and its feedback
      # loop (FeedbackLoop), one per side, the sweep a Tone LFO
      # (ModulationLfo).  The delay is +delay+ * 2 ** (+range+ / 2 *
      # +depth+ * sweep): the sweep moves it +range+ octaves around
      # +delay+ (so the notches move evenly in pitch), or with `law:
      # :linear` straight between the ends.  +through_zero:+ delays the dry
      # signal by +delay+ too, so the wet passes through it twice a cycle
      # (tape flanging: the notches run off to infinity and come back).
      #
      # Presets are the :flanger family of the library (`L.fx.flanger.jet`,
      # `find 'metal'`); use them with GraphNode#flanger
      # (FlangerMethods#flanger).  The settings share their names and
      # meanings with GraphNode#phaser (rate, depth, feedback, mix, spread,
      # shape, phase, sweep).
      module Flanger
        extend MB::Sound::Presettable

        # The largest feedback magnitude: peaks up to 1 / (1 - 0.95) =
        # +26 dB over the wet level (as GraphNode#phaser's limit).
        MAX_FEEDBACK = 0.95

        # Sweep laws: :octaves (the delay moves evenly in pitch, so the
        # notches do too) or :linear (the delay moves evenly in time).
        LAWS = %i[octaves linear].freeze

        # The settings GraphNode#flanger takes (besides a preset name or
        # rate).
        KEYS = %i[rate depth delay range feedback mix dry wet spread shape phase sweep law through_zero interpolation].freeze

        preset_family :flanger, kind: :effect, label: 'flanger preset', keys: KEYS,
          about: 'Flangers: sig.flanger(:jet)',
          apply: ->(name, input, **options) { input.flanger(name, **options) },
          code: ->(e) { "sig.flanger(#{e.name.inspect})" }

        param :rate, 0.2, range: 0.01..20.0, unit: 'Hz', description: 'LFO rate (Hz, or a musical length per cycle: 2.bars)'
        param :depth, 1.0, range: 0.0..1.0, description: 'Share of the range the LFO sweeps (0 holds the delay)'
        param :delay, 0.002, range: 0.0001..0.03, unit: 's', description: 'Sweep center delay (seconds or a length: 2.ms)'
        param :range, 4.0, range: 0.0..8.0, unit: 'octaves', description: 'Sweep width in octaves of delay at depth 1'
        param :feedback, 0.5, range: -MAX_FEEDBACK..MAX_FEEDBACK, description: 'Feedback around the delay (negative: hollow, metallic)'
        param :mix, 0.5, range: 0.0..1.0, description: 'Dry/wet crossfade, linear (0.5 deepest notches)'
        param :spread, 0.0, range: 0.0..1.0, unit: 'cycles', description: "Right LFO's phase offset from the left (0.5 opposite); stereo out"
        param :shape, :triangle, range: ModulationLfo::SHAPES, description: 'LFO shape'
        param :phase, 0.0, range: 0.0..1.0, unit: 'cycles', description: "Left LFO's starting phase"
        param :law, :octaves, range: LAWS, description: 'Sweep law: :octaves (even in pitch) or :linear (even in time)'

        preset :sweep, rate: 0.2, depth: 1.0, delay: 0.002, range: 4.0, feedback: 0.5, mix: 0.5, spread: 0.0, shape: :triangle,
          tags: %i[classic medium], about: 'A classic flanger: 0.5-8 ms swept by a slow triangle, medium feedback (the defaults)'
        preset :jet, rate: 0.08, depth: 1.0, delay: 0.0025, range: 5.0, feedback: 0.85, mix: 0.5, spread: 0.0, shape: :triangle,
          tags: %i[resonant whoosh drums], about: 'A resonant jet-plane whoosh: strong feedback, a slow five-octave sweep'
        preset :sheen, rate: 0.35, depth: 1.0, delay: 0.004, range: 1.5, feedback: 0.2, mix: 0.35, spread: 0.25, shape: :sine,
          tags: %i[gentle subtle stereo], about: 'A gentle stereo shimmer: a narrow sweep around 4 ms, light feedback, mostly dry'
        preset :steel, rate: 0.15, depth: 1.0, delay: 0.001, range: 3.0, feedback: -0.85, mix: 0.5, spread: 0.0, shape: :triangle,
          tags: %i[metal hollow negative], about: 'Hollow, metallic ringing from strong negative feedback over 0.35-2.8 ms'
        preset :orbit, rate: 0.25, depth: 1.0, delay: 0.003, range: 3.0, feedback: 0.4, mix: 0.5, spread: 0.5, shape: :sine,
          tags: %i[stereo wide pad], about: 'A wide stereo flanger: the two sides sweep in opposite directions'
        preset :tape_flange, rate: 0.12, depth: 1.0, delay: 0.003, range: 2.0, feedback: 0.0, mix: 0.5, spread: 0.0, shape: :sine, through_zero: true,
          tags: %i[tape through_zero], about: 'Through-zero tape flanging: the delay passes the dry signal, notches running off to infinity'

        # The default preset (GraphNode#flanger without a preset name).
        DEFAULT_PRESET = :sweep

        # Builds a flanger on +input+ (see FlangerMethods#flanger): +rate+
        # is a preset name (Symbol) or the LFO rate, +options+ override the
        # preset's settings.  Returns one node for a mono input without
        # spread, else a stereo Channels bundle.
        def self.build(input, rate = nil, **options)
          bad = options.keys - KEYS
          unless bad.empty?
            guess = DidYouMean::SpellChecker.new(dictionary: KEYS).correct(bad[0]).first
            raise ArgumentError, "flanger: unknown option#{'s' if bad.length > 1} #{bad.map(&:inspect).join(', ')}#{guess ? " (did you mean #{guess.inspect}?)" : ''}"
          end

          if rate.is_a?(Symbol) || rate.is_a?(String)
            preset = rate.to_sym
          else
            preset = DEFAULT_PRESET
            raise ArgumentError, 'flanger: give the rate once (positional or rate:)' if !rate.nil? && options.key?(:rate)
            options = options.merge(rate: rate) unless rate.nil?
          end
          s = { dry: 1, wet: 1, phase: 0.0, sweep: nil, law: :octaves, through_zero: false,
                interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION }.merge(preset_settings(preset))
          s.delete(:delay) if options[:range].is_a?(Range)
          s.merge!(options)

          sample_rate = input.sample_rate
          law = s[:law]
          raise ArgumentError, "flanger law: is #{LAWS.map(&:inspect).join(' or ')} (got #{law.inspect})" unless LAWS.include?(law)
          center, octaves = sweep_band(s[:delay], s[:range], options.key?(:delay), sample_rate)
          feedback = GraphNode.build_setting(s[:feedback])
          if feedback.is_a?(Numeric) && !(feedback.real? && feedback.abs <= MAX_FEEDBACK)
            raise ArgumentError, "flanger feedback: is within -#{MAX_FEEDBACK}..#{MAX_FEEDBACK} (got #{feedback.inspect})"
          end
          feedback = feedback.to_f if feedback.is_a?(Numeric)

          mix = s[:mix]
          mix = BlendMethods.amount(GraphNode.build_setting(mix)) unless mix.nil?
          dry, wet = level(s[:dry], 'dry'), level(s[:wet], 'wet')
          if mix
            dg, wg = BlendMethods.gains(mix, :linear)
            dry = StereoDelayMethods.level_product(dry, dg)
            wet = StereoDelayMethods.level_product(wet, wg)
          end

          spread = ModulationLfo.cycles(s[:spread], 'flanger', 'spread')
          phase = ModulationLfo.cycles(s[:phase], 'flanger', 'phase')
          sweep = s[:sweep]
          if sweep && spread != 0
            raise ArgumentError, 'flanger: a sweep: node drives both sides alike; spread: needs the built-in LFO'
          end
          raise ArgumentError, "flanger sweep: is a node (-1..1; got #{sweep.inspect})" if sweep && !sweep.respond_to?(:sample)
          tz = GraphNode.build_flag?(s[:through_zero], default: false)

          l, r = StereoDelayMethods.sides(input, 'flanger')
          stereo = !l.equal?(r) || input.is_a?(Channels) && input.channel_count == 2 || spread != 0
          make = ->(side, offset) {
            sw = sweep || ModulationLfo.tone(s[:rate], shape: s[:shape], phase: phase + offset, sample_rate: sample_rate, what: 'flanger')
            time = delay_time(sw, center, octaves, s[:depth], law)
            side_out(side, time, center, feedback, dry, wet, tz, s[:interpolation], sample_rate)
          }

          return make.(l, 0.0) unless stereo
          Channels.new([make.(l, 0.0), make.(r, spread)])
        end

        # One side: +side+ through the swept delay (+time+, seconds) with
        # +feedback+, mixed with the dry signal (delayed by +center+ for
        # +through_zero+).
        def self.side_out(side, time, center, feedback, dry, wet, through_zero, interpolation, sample_rate)
          fb = feedback.is_a?(Numeric) && feedback == 0 ? false : feedback
          return side.delay(time, feedback: fb, dry: dry, wet: wet, smooth: false, interpolation: interpolation) unless through_zero

          # The dry signal waits for the sweep's center (whole samples for
          # a fixed center, read directly), so the wet passes it
          ref = center.is_a?(Numeric) ? (center * sample_rate).round.samples : center
          d = Chorus.scale(side.delay(ref, smooth: false), dry)
          w = Chorus.scale(side.delay(time, feedback: fb, wet: 1, smooth: false, interpolation: interpolation), wet)
          return w || side * 0 if d.nil?
          return d if w.nil?
          DelayMethods.ring_sum(w, d)
        end

        # The delay time in seconds for the sweep +sweep+ (-1..1): +center+
        # * 2 ** (+octaves+ / 2 * +depth+ * sweep) (:octaves), or straight
        # between the same ends (:linear); numbers or nodes (:linear wants a
        # fixed center and range).
        def self.delay_time(sweep, center, octaves, depth, law)
          depth = GraphNode.build_setting(depth)
          raise ArgumentError, "flanger depth: is a number or a node (got #{depth.inspect})" unless depth.respond_to?(:sample) || (depth.is_a?(Numeric) && depth.real?)

          if law == :linear
            unless center.is_a?(Numeric) && octaves.is_a?(Numeric)
              raise ArgumentError, 'flanger law: :linear wants a fixed delay: and range: (numbers); :octaves takes nodes'
            end
            lo = center * 2.0 ** (-octaves / 2.0)
            hi = center * 2.0 ** (octaves / 2.0)
            mid = (lo + hi) / 2.0
            half = (hi - lo) / 2.0
            return mid if depth.is_a?(Numeric) && (depth == 0 || half == 0)
            return sweep * (half * depth) + mid if depth.is_a?(Numeric)
            return sweep * depth * half + mid
          end

          k = octaves * depth * 0.5
          return center if k.is_a?(Numeric) && k == 0
          (2 ** (sweep * k)) * center
        end

        # [center seconds, octaves] for the +delay+ and +range+ settings: a
        # Range of delay times (seconds or Lengths) is the sweep's ends (its
        # geometric middle the center; +delay_given+ raises), a number or
        # node the octaves around +delay+.
        def self.sweep_band(delay, range, delay_given, sample_rate)
          if range.is_a?(Range)
            raise ArgumentError, 'flanger: give delay: with a range: in octaves, or a range: of delay times (lo..hi) alone' if delay_given
            lo, hi = [range.begin, range.end].map { |t| seconds(t, sample_rate) }
            unless lo.is_a?(Numeric) && hi.is_a?(Numeric) && lo > 0 && hi >= lo
              raise ArgumentError, "flanger range: of delay times goes up from a positive time (got #{range.inspect})"
            end
            return [Math.sqrt(lo * hi), Math.log2(hi / lo)]
          end

          range = GraphNode.build_setting(range) unless range.respond_to?(:sample)
          unless range.respond_to?(:sample) || (range.is_a?(Numeric) && range.real? && range >= 0)
            raise ArgumentError, "flanger range: is octaves (a number or node) or a Range of delay times (got #{range.inspect})"
          end
          range = range.to_f if range.is_a?(Numeric)
          delay = seconds(delay, sample_rate)
          unless delay.respond_to?(:sample) || (delay.is_a?(Numeric) && delay > 0)
            raise ArgumentError, "flanger delay: is a positive time (seconds, a Length, or a node of seconds; got #{delay.inspect})"
          end
          [delay, range]
        end

        # +t+ in seconds: a number, a Length, or a node (as is).
        def self.seconds(t, sample_rate)
          t = GraphNode.build_setting(t) unless t.respond_to?(:sample)
          return t.to_seconds(sample_rate: sample_rate).to_f if t.is_a?(Length)
          return t.to_f if t.is_a?(Numeric) && t.real?
          t
        end

        # A dry or wet level: Decibels, a number (negative inverts the
        # polarity), or a node.
        def self.level(value, name)
          value = GraphNode.build_setting(value) unless value.respond_to?(:sample)
          return Decibels.gain_of(value, "flanger #{name}", zero: true, above_one: true) if value.is_a?(Decibels)
          return value if value.respond_to?(:sample) || (value.is_a?(Numeric) && value.real?)
          raise ArgumentError, "flanger #{name}: is a level (a number, Decibels, or a node; got #{value.inspect})"
        end
      end
    end
  end
end
