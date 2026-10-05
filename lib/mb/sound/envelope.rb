module MB
  module Sound
    # An attack-decay-sustain-release envelope generator with curved segments,
    # run by a state machine in C (MB::Sound::FastEnvelope, with an exact
    # Ruby mirror in .process_ruby).  Usually made by the presets in
    # EnvelopeMethods (MB::Sound.adsr, env, amp_env, fm_env, filter_env) or
    # GraphNode#adsr.
    #
    # Stages: idle, attack (to the peak), decay (to the sustain level, a
    # fraction of the peak), sustain, release (to 0), and choke (a 3 ms
    # release); a one-shot that has finished is ended.  Every time, the
    # sustain level, and the curves may be a number (seconds for times), any
    # length (`250.ms`, `96.samples`, or a Duration like `1.n8`, which follows
    # the tempo), or a graph node read every sample.  When a value changes
    # during a segment, the rest of the segment is re-planned from the
    # current level, so the output stays continuous.
    #
    # Curves are signed dB (see CURVES): positive values move fast first (an
    # analog-style attack, a ringing decay), 0 is linear, and negative values
    # move slowly first (a swell).  The curve of a segment with curve d is
    # p(x) = (1 - e^(cx)) / (1 - e^c) with c = -d ln(10) / 20 (SuperCollider's
    # curvature), so +60 decays like a 60 dB exponential that lands exactly
    # on its target: every segment ends exactly at its time, with no endless
    # tail.  Equivalences: +60 is the analog "r = 0.001" of EarLevel's
    # envelope (and the old ADSREnvelope#db(60)); +30 the old `.db(30)` for
    # decays and releases (its attack was about -30); an analog attack with
    # r = 0.3 is about +12.7; r = 0.1 about +21.
    #
    # Inputs (graph nodes or numbers, all optional):
    # - +:gate+: a rising edge (0 to nonzero) starts the attack from the
    #   current level; a falling edge starts the release.
    # - +:trigger+: a rising edge (a sample > 0 after one <= 0; negative
    #   values are ignored, reserved for bipolar triggers) (re)starts the
    #   attack.  Without a gate, a triggered note releases +:hold+ seconds
    #   after it starts.
    # - +:velocity+: read on the sample of each note start (0..1), scaled to
    #   the note's peak by +:sensitivity+ and +:velocity_scale+.
    # - +:choke+: a nonzero sample releases to 0 over CHOKE_TIME.
    # - +:lift+: release velocity (0..1), read on the sample each release
    #   starts, scaling the release time by 2 ** ((0.5 - lift) * 2): 0.5
    #   (MIDI 64, the usual default) leaves it alone, a slow lift (0)
    #   doubles it, a fast lift (1) halves it.  Exponential so equal steps of
    #   lift are equal ratios of time, like the octave steps of a pitch.
    #   Without +:lift+ the release time is unchanged.
    #
    # Retriggers (+:retrigger+, or #retrigger): a note that starts while the
    # envelope is still sounding attacks from the current level.  With
    # :restart (the default) it attacks to its own velocity's peak, even if
    # that is lower than the current level (a ringing note struck softly
    # drops to the softer note's peak).  With :add it attacks to the energy
    # sum sqrt(level² + peak²) (strikes adding with unrelated phases), but
    # no higher than sqrt(2) × its own peak (ADD_LIMIT, +3 dB) or the
    # loudest velocity's peak, and never lower than the current level; the
    # decay continues from there.  So soft re-strikes of a ringing note lift
    # it a little and never drop it, and however many strikes come (a roll,
    # a trill, a file hammering one key) the level stays within +3 dB of
    # one strike: a roll of equal strikes levels off at the second strike,
    # as a struck string or bar can't ring much harder than one blow of
    # the same force drives it.  From silence both modes are the same.  (Synth voices reused for a repeated
    # note also reset key-synced oscillators' phases; ringing patches that
    # use :add usually want `.free` oscillators.)
    #
    # With no gate and no trigger, the envelope is a one-shot: it starts on
    # its first sample, releases +:hold+ seconds later (from wherever it is,
    # so a hold shorter than the attack and decay cuts them short), and
    # then #sample returns nil once the release ends.  Gated and triggered envelopes never end;
    # #idle? tells when they are silent.
    #
    # Example:
    #     play 220.hz.ramp * adsr(0.01, 0.3, 0.5, 1, curve: :snappy)
    #     play 110.hz.ramp.filter(:lowpass, cutoff: 200.constant * filter_env(0.01, 0.4, depth: 4), quality: 4)
    #     play 200.hz.fm(400.hz.at(800) * fm_env(0, 1)) * amp_env(0.001, 1, 0, 0.5)
    #
    # See bin/plot_envelope.rb to plot envelopes and curves.
    class Envelope
      include GraphNode
      include GraphNode::SampleRateHelper

      # Seconds a choke takes to release to 0 (linearly).
      CHOKE_TIME = 0.003

      # Multiplies a curve in dB to give the curvature c (see the class
      # description).  Passed to the C kernel so both kernels use this exact
      # value.
      CURVE_SCALE = -Math.log(10) / 20.0

      # The segment names, in order.  The sustain level is the decay's
      # target, and the release starts at the RELEASE_NODE segment.
      SEGMENTS = [:attack, :decay, :release].freeze
      RELEASE_NODE = 2

      # Keys for the last values of curve nodes (see #fit).
      CURVE_KEYS = SEGMENTS.map { |s| [s, :"#{s}_curve"] }.to_h.freeze

      # Curve presets in dB: [attack, decay, release].
      CURVES = {
        linear: [0, 0, 0].freeze,
        analog: [12, 60, 60].freeze,
        snappy: [24, 90, 60].freeze,
        gentle: [6, 21, 21].freeze,
        swell: [-24, 21, 21].freeze,
        dx: [-30, 30, 30].freeze,
      }.freeze

      # Default times and sustain level (see PRESETS for per-preset changes).
      DEFAULT_ATTACK = 0.005
      DEFAULT_DECAY = 0.2
      DEFAULT_SUSTAIN = 0.7
      DEFAULT_RELEASE = 0.3

      # The shortest default hold time (see #hold).
      MIN_HOLD = 0.1

      # Settings for the constructors in EnvelopeMethods (see .preset).
      PRESETS = {
        adsr: { curve: :analog, sensitivity: 0..1 }.freeze,
        env: { curve: :analog, sensitivity: 0.5..1 }.freeze,
        amp_env: { curve: [12, 60, 40].freeze, sensitivity: -18.db..0.db, velocity_scale: :db }.freeze,
        fm_env: { curve: :dx, sustain: 0, sensitivity: -18.db..0.db, velocity_scale: :db }.freeze,
        filter_env: { curve: :analog, sustain: 0, sensitivity: 0.5..1, octaves: 2 }.freeze,
      }.freeze

      # Kernel stages (the C enum env_stage).
      STAGE_IDLE = 0
      STAGE_SEGMENT = 1
      STAGE_SUSTAIN = 2
      STAGE_ENDED = 3
      STAGE_CHOKE = 4
      STAGE_PENDING = 5

      # Indices into the kernel state (the C enum env_state_index).
      STATE_STAGE = 0
      STATE_SEGMENT = 1
      STATE_POSITION = 2
      STATE_LEVEL = 3
      STATE_PEAK = 4
      STATE_GATE = 5
      STATE_PLANNED = 6
      STATE_PLAN_LENGTH = 7
      STATE_PLAN_CURVE = 8
      STATE_PLAN_TARGET = 9
      STATE_ANCHOR_POSITION = 10
      STATE_ANCHOR_LEVEL = 11
      STATE_SCALE = 12
      STATE_W = 13
      STATE_G = 14
      STATE_LINEAR = 15
      STATE_TRIGGER = 16
      STATE_NOTE_POSITION = 17
      STATE_RELEASE_SCALE = 18
      STATE_SIZE = 19

      # Kernel flags.
      FLAG_GATE = 1
      FLAG_TRIGGER = 2
      FLAG_ONE_SHOT = 4
      FLAG_LEGATO = 8
      FLAG_OCTAVES = 16
      FLAG_LIFT = 32
      FLAG_ADD = 64

      # Retrigger modes (see #retrigger): :restart attacks from the current
      # level to the new note's velocity peak; :add attacks to the energy
      # sum of the current level and that peak.
      RETRIGGER_MODES = [:restart, :add].freeze

      # How far an :add retrigger may rise above its own velocity peak
      # (sqrt(2): two equal strikes summed in energy, +3 dB; the C
      # ENV_ADD_LIMIT).
      ADD_LIMIT = 1.4142135623730951

      # Remaining curvature below which a segment is planned as a line (the
      # C ENV_LINEAR_LIMIT).
      LINEAR_LIMIT = 1e-9

      # Creates an envelope from the preset +name+ in PRESETS (:adsr, :env,
      # :amp_env, :fm_env, or :filter_env), with optional positional times
      # and sustain level, and any #initialize options (which override the
      # preset).  +:depth+ is an alias for +:octaves+.
      def self.preset(name, attack = nil, decay = nil, sustain = nil, release = nil, **options)
        settings = PRESETS.fetch(name) { raise ArgumentError, "Unknown envelope preset #{name.inspect} (#{PRESETS.keys.join(', ')})" }

        if options.key?(:auto_release) || options.key?(:log)
          raise ArgumentError, 'Envelopes take hold: (seconds from the start to the release) instead of auto_release:, and curve: (dB) instead of log:'
        end

        if options.key?(:depth)
          raise ArgumentError, 'Give depth: or octaves:, not both' if options.key?(:octaves)
          options[:octaves] = options.delete(:depth)
        end

        positional = { attack: attack, decay: decay, sustain: sustain, release: release }.compact
        both = positional.keys & options.keys
        raise ArgumentError, "#{both.join(', ')} given twice" unless both.empty?

        new(**settings, **positional, **options)
      end

      # Returns a Hash of curves for each segment (see SEGMENTS) from any
      # curve specification: a preset Symbol (see CURVES), a number or graph
      # node for every segment, an Array of [attack, decay, release], or a
      # Hash of some segments (the rest come from +current+).
      def self.curve_values(curve, current = SEGMENTS.zip(CURVES[:analog]).to_h)
        values = case curve
                 when Symbol
                   SEGMENTS.zip(CURVES.fetch(curve) { raise ArgumentError, "Unknown curve preset #{curve.inspect} (#{CURVES.keys.join(', ')})" }).to_h

                 when Array
                   raise ArgumentError, "Curve arrays need #{SEGMENTS.length} values (#{SEGMENTS.join(', ')})" unless curve.length == SEGMENTS.length
                   SEGMENTS.zip(curve).to_h

                 when Hash
                   extra = curve.keys - SEGMENTS
                   raise ArgumentError, "Unknown curve segments #{extra.inspect} (#{SEGMENTS.join(', ')})" unless extra.empty?
                   current.merge(curve)

                 else
                   SEGMENTS.map { |s| [s, curve] }.to_h
                 end

        values.transform_values { |v|
          case v
          when Numeric then v.to_f
          else
            raise ArgumentError, "Curves must be numbers (dB) or graph nodes (got #{v.inspect})" unless v.respond_to?(:sample)
            v
          end
        }
      end

      # Velocity gains for velocity 0 and 1 (see #initialize).
      attr_reader :velocity_low, :velocity_high

      # :linear or :db (see #initialize).
      attr_reader :velocity_scale

      # The output's exponent scale for a cutoff multiplier (2 ** (level *
      # octaves)), or nil for plain output (see EnvelopeMethods#filter_env).
      attr_reader :octaves

      # The input nodes (or numbers), or nil.
      attr_reader :gate, :trigger, :velocity, :choke, :lift

      # Creates an envelope (usually through EnvelopeMethods or .preset).
      #
      # +:attack+, +:decay+, +:release+ - Times: seconds, a Length (e.g.
      #                                    `250.ms`, `96.samples`, `1.n8`),
      #                                    or a graph node (seconds).
      # +:sustain+ - The sustain level relative to the peak (number or node).
      # +:curve+ - Curves in dB (see .curve_values and CURVES).
      # +:hold+ - Seconds (or a length) from the start of a one-shot or a
      #           gateless trigger to its release (like the old
      #           auto_release); false holds forever.  Defaults to twice the
      #           attack plus decay time, at least MIN_HOLD (like the old
      #           smoothstep ADSREnvelope's default auto release).
      # +:gate+, +:trigger+, +:velocity+, +:choke+, +:lift+ - Inputs (see
      #                                                       the class
      #                                                       description).
      # +:sensitivity+ (alias +:velocity_range+) - A Range of peak levels for
      #                                            velocity 0..1, or 0 or nil
      #                                            to ignore velocity.
      # +:velocity_scale+ - :linear interpolates the sensitivity range in
      #                     amplitude, :db in decibels (give the range as
      #                     gains, e.g. -18.db..0.db).
      # +:legato+ - If true, triggers while the gate is held keep the current
      #             stage (see #legato).
      # +:retrigger+ - :restart (default) or :add (see the class
      #                description and #retrigger).
      # +:octaves+ - If not nil or 0, the output is 2 ** (level * octaves), a
      #              cutoff multiplier (a number of octaves, anything with
      #              #to_octaves such as an Interval, or a graph node read
      #              every sample, e.g. the mod wheel).
      def initialize(
        attack: DEFAULT_ATTACK, decay: DEFAULT_DECAY, sustain: DEFAULT_SUSTAIN, release: DEFAULT_RELEASE,
        curve: :analog, hold: nil,
        gate: nil, trigger: nil, velocity: nil, choke: nil, lift: nil,
        sensitivity: 0..1, velocity_range: nil, velocity_scale: :linear, legato: false, octaves: nil,
        retrigger: :restart, sample_rate: 48000
      )
        @sample_rate = sample_rate.to_f
        raise ArgumentError, "Sample rate must be positive (got #{sample_rate.inspect})" unless @sample_rate > 0

        @times = {}
        self.attack = attack
        self.decay = decay
        self.release = release
        self.sustain = sustain
        self.hold = hold

        @curves = nil
        self.curve(curve)

        if velocity.is_a?(Range)
          raise ArgumentError, "velocity: is the velocity input (a node or number); give the velocity range as sensitivity: #{velocity.inspect}"
        end

        @gate = input(gate, :gate)
        @trigger = input(trigger, :trigger)
        @velocity = input(velocity, :velocity)
        @choke = input(choke, :choke)
        @lift = input(lift, :lift)

        unless velocity_range.nil?
          raise ArgumentError, 'Give sensitivity: or velocity_range:, not both' unless sensitivity == (0..1)
          sensitivity = velocity_range
        end
        set_sensitivity(sensitivity, velocity_scale)

        @legato = !!legato
        self.retrigger = retrigger
        self.octaves = octaves

        @last = {}
        @fitted = {}
        @quiet = {}
        @buf = nil
        @state = Numo::DFloat.zeros(STATE_SIZE)
        reset
      end

      # Times as given (seconds, lengths, or graph nodes).
      def attack
        @times[:attack].length
      end

      def decay
        @times[:decay].length
      end

      def release
        @times[:release].length
      end

      # Times in seconds (lengths converted at the current tempo), or nil for
      # times from graph nodes.
      def attack_time
        seconds(@times[:attack])
      end

      def decay_time
        seconds(@times[:decay])
      end

      def release_time
        seconds(@times[:release])
      end

      # The sustain level (a number or graph node), relative to the peak.
      attr_reader :sustain
      alias sustain_level sustain

      # Changes the attack time (seconds, a length, or a graph node).
      def attack=(time)
        @times[:attack] = Length::Source.new(time)
        @default_hold = nil
        changed!
      end
      alias attack_time= attack=

      # Changes the decay time (seconds, a length, or a graph node).
      def decay=(time)
        @times[:decay] = Length::Source.new(time)
        @default_hold = nil
        changed!
      end
      alias decay_time= decay=

      # Changes the release time (seconds, a length, or a graph node).
      def release=(time)
        @times[:release] = Length::Source.new(time)
        changed!
      end
      alias release_time= release=

      # Changes the sustain level (a number or graph node, relative to the
      # peak).
      def sustain=(level)
        @sustain = param(level, 'Sustain')
        changed!
      end
      alias sustain_level= sustain=

      # The hold time as given, the default (see #initialize), or false to
      # hold forever.
      def hold
        return false if @hold == false
        @hold ? @hold.length : default_hold.length
      end

      # Changes the time from the start of a one-shot or gateless trigger to
      # its release (seconds, a length, a graph node, nil for the default, or
      # false or infinity for forever).
      def hold=(time)
        time = false if time.is_a?(Numeric) && time.infinite?
        @hold = time.nil? || time == false ? time : Length::Source.new(time)
        changed!
      end

      # Sets curves for any segments (see .curve_values) and returns self, or
      # returns the curves (a Hash of segment => dB or node) without
      # arguments.  Accepts the same arguments as +:curve+ in #initialize, or
      # three values for attack, decay, and release.
      #
      # Example:
      #     adsr(0.01, 0.5, 0.3, 1).curve(:snappy)
      #     adsr(0.01, 0.5, 0.3, 1).curve(release: 30)
      #     adsr(0.01, 0.5, 0.3, 1).curve(0, 60, 60)
      def curve(*args)
        return @curves.dup if args.empty?

        spec = args.length == 1 ? args.first : args
        values = self.class.curve_values(spec, @curves || SEGMENTS.zip(CURVES[:analog]).to_h)
        @curves = values.transform_values { |v| v.is_a?(Numeric) ? v : v.get_sampler }
        changed!
        self
      end
      alias curves curve

      # Makes triggers while the gate is held keep the current stage (or
      # restart the attack again if +enabled+ is false).  Returns self.
      def legato(enabled = true)
        @legato = !!enabled
        changed!
        self
      end

      # True if triggers while the gate is held are ignored (see #legato).
      def legato?
        @legato
      end

      # Sets the retrigger mode (:restart or :add; see the class description)
      # and returns self, or returns the mode without an argument.
      #
      # Example:
      #     v.amp_env(0.001, 6, 0, 5).retrigger(:add)
      def retrigger(mode = nil)
        return @retrigger if mode.nil?
        self.retrigger = mode
        self
      end

      # Sets the retrigger mode (:restart or :add; see the class
      # description).
      def retrigger=(mode)
        unless RETRIGGER_MODES.include?(mode)
          raise ArgumentError, "Retrigger mode must be one of #{RETRIGGER_MODES} (got #{mode.inspect})"
        end
        @retrigger = mode
        changed!
      end

      # The peak level a note with +velocity+ (0..1) reaches, starting from
      # silence: the velocity mapped through #sensitivity.  See
      # #retrigger_peak for a note that starts while sounding.
      def velocity_peak(velocity)
        self.class.velocity_peak(velocity.to_f, @velocity_low, @velocity_high, @velocity_scale == :db)
      end

      # The peak level a note with +velocity+ would attack to if it started
      # now (from the current #level), following the #retrigger mode.
      def retrigger_peak(velocity)
        peak = velocity_peak(velocity)
        @retrigger == :add ? self.class.add_peak(level, peak, @velocity_low, @velocity_high) : peak
      end

      # Sets the velocity +range+ of peak levels (a Range, or 0 or nil for
      # none) and +:scale+ (:linear or :db).
      def set_sensitivity(range, scale = @velocity_scale)
        raise ArgumentError, "Velocity scale must be :linear or :db (got #{scale.inspect})" unless [:linear, :db].include?(scale)

        case range
        when nil, 0
          low = high = 1.0

        when Range
          raise ArgumentError, "Sensitivity range needs both ends (got #{range.inspect})" if range.begin.nil? || range.end.nil?
          low = range.begin.to_f
          high = range.end.to_f

        else
          raise ArgumentError, "Sensitivity must be a Range of levels, 0, or nil (got #{range.inspect})"
        end

        if scale == :db && !(low > 0 && high > 0)
          raise ArgumentError, "dB velocity scaling needs positive gains (e.g. -18.db..0.db; got #{range.inspect})"
        end

        @velocity_low = low
        @velocity_high = high
        @velocity_scale = scale
        changed!
        self
      end

      # The velocity range given to #set_sensitivity (nil if velocity is
      # ignored).
      def sensitivity
        @velocity_low == @velocity_high && @velocity_low == 1.0 ? nil : @velocity_low..@velocity_high
      end

      # Sets the octaves of a cutoff multiplier envelope (see #initialize).
      def octaves=(depth)
        depth = depth.to_octaves if depth.respond_to?(:to_octaves) # TODO: Interval (branch interval)
        depth = nil if depth == 0
        @octaves = depth.respond_to?(:sample) ? depth.get_sampler : depth&.to_f
        changed!
      end

      # The current stage: :idle, :attack, :decay, :sustain, :release, :choke,
      # or :ended (or :pending for a one-shot that hasn't started).
      def stage
        case @state[STATE_STAGE].to_i
        when STAGE_IDLE then :idle
        when STAGE_SEGMENT then SEGMENTS[@state[STATE_SEGMENT].to_i]
        when STAGE_SUSTAIN then :sustain
        when STAGE_ENDED then :ended
        when STAGE_CHOKE then :choke
        when STAGE_PENDING then :pending
        end
      end

      # The most recent output level (before the octaves transform).
      def level
        @state[STATE_LEVEL]
      end

      # True when the envelope is idle at exactly 0 (e.g. for voice
      # allocation).
      def idle?
        @state[STATE_STAGE] == STAGE_IDLE && @state[STATE_LEVEL] == 0
      end

      # True when a one-shot has finished (see the class description).
      def ended?
        @state[STATE_STAGE] == STAGE_ENDED
      end

      # True if this envelope runs once by itself (no gate or trigger).
      def one_shot?
        @gate.nil? && @trigger.nil?
      end

      # Returns the envelope to its starting state (idle, or a one-shot that
      # starts on the next sample).  Will click if used on audio.
      def reset
        @state.fill(0)
        @state[STATE_STAGE] = one_shot? ? STAGE_PENDING : STAGE_IDLE
        @state[STATE_PEAK] = 1
        @state[STATE_W] = 1
        @state[STATE_G] = 1
        @state[STATE_RELEASE_SCALE] = 1
        self
      end

      # Returns +count+ samples of the envelope (an SFloat reused between
      # calls), or nil after a one-shot has ended.
      def sample(count)
        run(count.round, :c)
      end

      # Like #sample, using the Ruby mirror of the C kernel (for testing).
      def sample_ruby(count)
        run(count.round, :ruby)
      end

      def sources
        s = {}
        @times.each { |name, src| s[name] = src.node if src.node? }
        s[:hold] = @hold.node if @hold && @hold.node?
        s[:sustain] = @sustain if @sustain.respond_to?(:sample)
        @curves.each { |name, c| s[:"#{name}_curve"] = c if c.respond_to?(:sample) }
        s[:gate] = @gate if @gate.respond_to?(:sample)
        s[:trigger] = @trigger if @trigger.respond_to?(:sample)
        s[:velocity] = @velocity if @velocity.respond_to?(:sample)
        s[:choke] = @choke if @choke.respond_to?(:sample)
        s[:lift] = @lift if @lift.respond_to?(:sample)
        s[:octaves] = @octaves if @octaves.respond_to?(:sample)
        s
      end

      # Changes the sample rate (times in seconds keep their length in
      # seconds; the current segment is re-planned).
      def sample_rate=(new_rate)
        old_rate = @sample_rate
        super
        if @sample_rate != old_rate
          @state[STATE_POSITION] = (@state[STATE_POSITION] * @sample_rate / old_rate).round
          @state[STATE_NOTE_POSITION] = (@state[STATE_NOTE_POSITION] * @sample_rate / old_rate).round
          @state[STATE_PLANNED] = 0
        end
        changed!
        self
      end
      alias at_rate sample_rate=

      def to_s
        times = [@times[:attack], @times[:decay], @sustain, @times[:release]].map { |t|
          t.is_a?(Numeric) ? MB::M.sigfigs(t, 4) : t.to_s
        }
        curves = CURVES.key(@curves.values) || @curves.values.map { |c| c.is_a?(Numeric) ? MB::M.sigfigs(c, 4) : c.to_s }.join('/')
        "#{super} -- adsr(#{times.join(', ')}) curve #{curves}#{' retrigger add' if @retrigger == :add}"
      end

      # The config Array for the kernels (see FastEnvelope.process).
      def kernel_config
        flags = 0
        flags |= FLAG_GATE if @gate
        flags |= FLAG_TRIGGER if @trigger
        flags |= FLAG_ONE_SHOT if one_shot?
        flags |= FLAG_LEGATO if @legato
        flags |= FLAG_OCTAVES if @octaves
        flags |= FLAG_LIFT if @lift
        flags |= FLAG_ADD if @retrigger == :add

        [
          flags,
          RELEASE_NODE,
          @velocity_low,
          @velocity_high,
          @velocity_scale == :db ? 1 : 0,
          CHOKE_TIME * @sample_rate,
          CURVE_SCALE,
        ]
      end

      # The Ruby mirror of MB::Sound::FastEnvelope.process (see
      # ext/mb/sound/fast_envelope/fast_envelope.c for the arguments and
      # algorithm).  Uses exactly the same operations, so the output and
      # state are identical.
      def self.process_ruby(out, state, times, curves, levels, hold, inputs, config)
        n = out.length
        nseg = times.length
        flags, release_node, velocity_low, velocity_high, velocity_db, choke_samples, curve_scale = config
        flags = Integer(flags)
        release_node = Integer(release_node)
        velocity_low = velocity_low.to_f
        velocity_high = velocity_high.to_f
        velocity_db = velocity_db.to_i != 0
        choke_samples = length_samples(choke_samples.to_f)
        curve_scale = curve_scale.to_f

        raise ArgumentError, 'Release node out of range' unless release_node >= 1 && release_node < nseg

        has_gate = flags & FLAG_GATE != 0
        has_trigger = flags & FLAG_TRIGGER != 0
        one_shot = flags & FLAG_ONE_SHOT != 0
        legato = flags & FLAG_LEGATO != 0
        use_octaves = flags & FLAG_OCTAVES != 0
        has_lift = flags & FLAG_LIFT != 0
        add = flags & FLAG_ADD != 0

        seg_times = times.map { |v| signal(v, n, 0.0) }
        seg_curves = curves.map { |v| signal(v, n, 0.0) }
        seg_levels = levels.map { |v| signal(v, n, 0.0) }
        hold_sig = signal(hold, n, 0.0)
        raise ArgumentError, 'Inputs must be [gate, trigger, velocity, choke, lift, octaves]' unless inputs.length == 6
        gate_sig, trigger_sig, velocity_sig, choke_sig, lift_sig, octaves_sig = inputs.each_with_index.map { |v, idx|
          signal(v, n, [0.0, 0.0, 1.0, 0.0, 0.5, 0.0][idx])
        }

        st = state.to_a
        stage = st[STATE_STAGE].to_i
        seg = st[STATE_SEGMENT].to_i
        e = st[STATE_POSITION]
        y = st[STATE_LEVEL]
        peak = st[STATE_PEAK]
        gate_prev = st[STATE_GATE] != 0
        planned = st[STATE_PLANNED] != 0
        plan_length = st[STATE_PLAN_LENGTH]
        plan_curve = st[STATE_PLAN_CURVE]
        plan_target = st[STATE_PLAN_TARGET]
        e0 = st[STATE_ANCHOR_POSITION]
        y0 = st[STATE_ANCHOR_LEVEL]
        scale = st[STATE_SCALE]
        w = st[STATE_W]
        g = st[STATE_G]
        linear = st[STATE_LINEAR] != 0
        trigger_prev = st[STATE_TRIGGER] != 0
        note_position = st[STATE_NOTE_POSITION]
        release_scale = st[STATE_RELEASE_SCALE]

        result = Array.new(n)

        n.times do |i|
          gate_now = has_gate && at(gate_sig, i) != 0
          start = stage == STAGE_PENDING

          if at(choke_sig, i) != 0 && (stage == STAGE_SEGMENT || stage == STAGE_SUSTAIN)
            stage = STAGE_CHOKE
            e = 0.0
            planned = false
          end

          if has_gate
            if gate_now && !gate_prev
              start = true
            elsif !gate_now && gate_prev && ((stage == STAGE_SEGMENT && seg < release_node) || stage == STAGE_SUSTAIN)
              stage = STAGE_SEGMENT
              seg = release_node
              e = 0.0
              planned = false
              release_scale = has_lift ? lift_scale(at(lift_sig, i)) : 1.0
            end
          end

          trigger_now = has_trigger && at(trigger_sig, i) > 0
          if trigger_now && !trigger_prev && !(legato && gate_prev && gate_now)
            start = true
          end
          trigger_prev = trigger_now

          if start
            peak = velocity_peak(at(velocity_sig, i), velocity_low, velocity_high, velocity_db)
            peak = add_peak(y, peak, velocity_low, velocity_high) if add
            stage = STAGE_SEGMENT
            seg = 0
            e = 0.0
            planned = false
            note_position = 0.0
            release_scale = 1.0
          end

          gate_prev = gate_now

          loop do
            if !has_gate && ((stage == STAGE_SEGMENT && seg < release_node) || stage == STAGE_SUSTAIN) &&
                note_position >= length_samples(at(hold_sig, i))
              stage = STAGE_SEGMENT
              seg = release_node
              e = 0.0
              planned = false
              release_scale = has_lift ? lift_scale(at(lift_sig, i)) : 1.0
              next
            end

            if stage == STAGE_SEGMENT || stage == STAGE_CHOKE
              if stage == STAGE_CHOKE
                length = choke_samples
                curve = 0.0
                target = 0.0
              else
                t = at(seg_times[seg], i)
                length = length_samples(seg >= release_node ? t * release_scale : t)
                curve = at(seg_curves[seg], i)
                target = at(seg_levels[seg], i) * peak
              end
              curve = 0.0 unless curve.finite?

              if e >= length
                y = target
                e = 0.0
                planned = false

                if stage == STAGE_CHOKE || seg == nseg - 1
                  stage = one_shot ? STAGE_ENDED : STAGE_IDLE
                elsif seg == release_node - 1
                  stage = STAGE_SUSTAIN
                else
                  seg += 1
                end

                next
              end

              if !planned || length != plan_length || curve != plan_curve || target != plan_target
                planned = true
                plan_length = length
                plan_curve = curve
                plan_target = target
                e0 = e > 0 ? e - 1 : 0.0
                y0 = y

                rem = length - e0
                if length.infinite?
                  linear = true
                  scale = 0.0
                else
                  k = curve * curve_scale / length
                  if (k * rem).abs < LINEAR_LIMIT
                    linear = true
                    scale = (target - y0) / rem
                  else
                    linear = false
                    scale = (target - y0) / (1.0 - Math.exp(k * rem))
                    w = 1.0
                    g = Math.exp(k)
                  end
                end
              end

              if linear
                y = y0 + scale * (e - e0)
              else
                w *= g if e > e0
                y = y0 + scale * (1.0 - w)
              end

              e += 1
              break
            end

            if stage == STAGE_SUSTAIN
              if has_gate && !gate_now
                stage = STAGE_SEGMENT
                seg = release_node
                e = 0.0
                planned = false
                release_scale = has_lift ? lift_scale(at(lift_sig, i)) : 1.0
                next
              end

              y = at(seg_levels[release_node - 1], i) * peak
              e += 1
              break
            end

            y = 0.0
            break
          end

          note_position += 1
          result[i] = use_octaves ? 2.0 ** (y * at(octaves_sig, i)) : y
        end

        out[0..] = result unless n == 0

        state[0..] = [
          stage, seg, e, y, peak, gate_prev ? 1 : 0, planned ? 1 : 0, plan_length, plan_curve, plan_target,
          e0, y0, scale, w, g, linear ? 1 : 0, trigger_prev ? 1 : 0, note_position, release_scale
        ]

        out
      end

      # Mirror of the C env_length: whole samples, 0 for negative or NaN.
      def self.length_samples(t)
        return 0.0 unless t > 0
        return t if t.infinite?
        t.round.to_f
      end

      # Mirror of the C env_lift_scale: the release time multiplier for
      # release velocity +lift+ (see #initialize).
      def self.lift_scale(lift)
        lift = 0.0 unless lift >= 0
        lift = 1.0 if lift > 1
        2.0 ** ((0.5 - lift) * 2.0)
      end

      # Mirror of the C env_peak.
      def self.velocity_peak(v, low, high, db)
        v = 0.0 unless v >= 0
        v = 1.0 if v > 1
        db ? low * (high / low) ** v : low + (high - low) * v
      end

      # Mirror of the C env_add_peak: the peak of a note that starts at
      # level +y+ with velocity peak +p+ in :add retrigger mode (see the
      # class description).
      def self.add_peak(y, p, low, high)
        a = y.abs
        sum = Math.sqrt(a * a + p * p)
        vmax = low.abs > high.abs ? low.abs : high.abs
        cap = p * ADD_LIMIT
        cap = vmax if cap > vmax
        cap = a if a > cap
        sum > cap ? cap : sum
      end

      # A kernel signal for .process_ruby: a Float or an Array of Floats.
      def self.signal(v, n, nil_value)
        case v
        when nil then nil_value
        when Numo::NArray
          raise ArgumentError, 'Signals must be 1D' unless v.ndim == 1
          raise ArgumentError, "Signal length #{v.length} does not match the output length #{n}" unless v.length == n
          v = Numo::DFloat.cast(v) unless v.is_a?(Numo::SFloat) || v.is_a?(Numo::DFloat)
          v.to_a
        else
          Float(v)
        end
      end

      def self.at(signal, i)
        signal.is_a?(Array) ? signal[i] : signal
      end

      private_class_method :signal, :at

      private

      # Runs the C or Ruby kernel for +count+ samples.
      def run(count, kernel)
        return nil if ended?

        @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count

        # Constant arguments are computed once (see #changed!); nodes are
        # read into the same Arrays every buffer.
        args = @args ||= kernel_args
        times, curves, levels, inputs, config = args
        SEGMENTS.each_with_index do |s, i|
          times[i] = read_length(s, @times[s], count) if @times[s].node?
          curves[i] = read_param(CURVE_KEYS[s], @curves[s], count) unless @curves[s].is_a?(Numeric)
        end
        levels[1] = read_param(:sustain, @sustain, count) unless @sustain.is_a?(Numeric)
        hold = args[5]
        hold = read_length(:hold, @hold || default_hold, count) if hold.nil?
        inputs[0] = read_input(:gate, @gate, count, 0.0) if @gate.respond_to?(:sample)
        inputs[1] = read_input(:trigger, @trigger, count, 0.0) if @trigger.respond_to?(:sample)
        inputs[2] = read_input(:velocity, @velocity, count, nil) if @velocity.respond_to?(:sample)
        inputs[3] = read_input(:choke, @choke, count, 0.0) if @choke.respond_to?(:sample)
        inputs[4] = read_input(:lift, @lift, count, nil) if @lift.respond_to?(:sample)
        inputs[5] = read_param(:octaves, @octaves, count) if @octaves.respond_to?(:sample)

        if kernel == :ruby
          self.class.process_ruby(@buf, @state, times, curves, levels, hold, inputs, config)
        elsif quiet_idle?(inputs, config)
          return idle_buffer(count)
        else
          MB::Sound::FastEnvelope.process(@buf, @state, times, curves, levels, hold, inputs, config)
        end

        @buf
      end

      # True if the envelope is idle and stays idle for this buffer: no gate
      # was high at the end of the last buffer, and the gate and trigger
      # inputs are absent, zero, or frozen buffers already found quiet (see
      # #quiet?).  Updates the state as the kernel would (the level stays
      # 0, the trigger edge detector resets, and the note position
      # advances), so #run can skip the kernel.  Not with octaves (the
      # output would be 2 ** (0 * octaves)).
      def quiet_idle?(inputs, config)
        return false unless @state[STATE_STAGE] == STAGE_IDLE && @state[STATE_GATE] == 0
        return false if config[0] & FLAG_OCTAVES != 0
        return false unless quiet?(:gate, inputs[0]) && quiet?(:trigger, inputs[1])

        @state[STATE_LEVEL] = 0
        @state[STATE_TRIGGER] = 0
        @state[STATE_NOTE_POSITION] += @buf.length
        true
      end

      # True if a gate (+key+ :gate; every sample 0) or trigger (:trigger;
      # no sample above 0) input can't start a note: nil, a number, or a
      # frozen buffer (remembered by identity, since frozen buffers don't
      # change).
      def quiet?(key, value)
        return true if value.nil?
        return key == :gate ? value == 0 : value <= 0 if value.is_a?(Numeric)
        return true if value.equal?(@quiet[key])
        return false unless value.frozen?

        quiet = key == :gate ? value.max == 0 && value.min == 0 : value.max <= 0
        @quiet[key] = value if quiet
        quiet
      end

      # A frozen buffer of zeros for an idle envelope (see #quiet_idle?).
      def idle_buffer(count)
        @idle_buf = Numo::SFloat.zeros(count).freeze if @idle_buf.nil? || @idle_buf.length != count
        @idle_buf
      end

      # Forgets the cached kernel arguments after a parameter change.
      def changed!
        @args = nil
      end

      # Kernel arguments with constants filled in (nil for nodes): [times,
      # curves, levels, inputs, config, hold].
      def kernel_args
        times = SEGMENTS.map { |s| @times[s].node? ? nil : @times[s].constant_samples(@sample_rate) }
        curves = SEGMENTS.map { |s| @curves[s].is_a?(Numeric) ? @curves[s] : nil }
        levels = [1.0, @sustain.is_a?(Numeric) ? @sustain : nil, 0.0]
        inputs = [@gate, @trigger, @velocity, @choke, @lift, @octaves].map { |v| v.respond_to?(:sample) ? nil : v }

        hold_source = @hold == false ? nil : (@hold || default_hold)
        hold = hold_source.nil? ? Float::INFINITY : (hold_source.node? ? nil : hold_source.constant_samples(@sample_rate))

        [times, curves, levels, inputs, kernel_config, hold]
      end

      # Reads a length source in samples (a number or NArray).  Lengths from
      # nodes that ended keep their last value.
      def read_length(key, source, count)
        fit(key, source.samples(count, @sample_rate), count)
      end

      # Reads a parameter (a number or a node's buffer).  Nodes that ended
      # keep their last value.
      def read_param(key, value, count)
        return value unless value.respond_to?(:sample)
        fit(key, value.sample(count), count)
      end

      # Reads an input (nil, a number, or a node's buffer).  Inputs that end
      # read as +ended_value+ (0 for gates, triggers, and chokes; the last
      # velocity for velocity).
      def read_input(key, value, count, ended_value)
        return value unless value.respond_to?(:sample)

        data = value.sample(count)
        if data.nil?
          return ended_value.nil? ? @last.fetch(key, key == :lift ? 0.5 : 1.0) : ended_value
        end

        fit(key, data, count, pad: ended_value)
      end

      # Returns +data+ fitted to +count+ samples (padded with +:pad+, or the
      # last value if +:pad+ is nil), remembering its last value for when its
      # node ends.  Numbers are returned unchanged; nil gives the last value.
      #
      # A frozen buffer of +count+ samples seen last time for +key+ (e.g. a
      # Notes node's constant buffer) is returned at once: it holds the same
      # values, so its last value is already remembered.
      def fit(key, data, count, pad: nil)
        return @last.fetch(key, 0.0) if data.nil?
        return data if data.is_a?(Numeric)
        return data if data.equal?(@fitted[key]) && data.length == count

        @fitted[key] = data.frozen? && (data.is_a?(Numo::SFloat) || data.is_a?(Numo::DFloat)) ? data : nil

        data = data.real if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
        @last[key] = data[-1] unless data.empty?

        if data.length > count
          data = data[0...count]
        elsif data.length < count
          padded = Numo::SFloat.new(count).fill(pad || @last.fetch(key, 0.0))
          padded[0...data.length] = data
          data = padded
        end

        data
      end

      # The default hold (see #initialize) as a length source.
      def default_hold
        @default_hold ||= Length::Source.new([2.0 * (fixed_seconds(@times[:attack]) + fixed_seconds(@times[:decay])), MIN_HOLD].max)
      end

      # A time in seconds for defaults (0 for graph nodes).
      def fixed_seconds(source)
        seconds(source) || 0.0
      end

      # A length source in seconds (Durations at the current tempo), or nil
      # if it comes from a graph node.
      def seconds(source)
        return nil if source.node? && source.tempo_node.nil?
        Length.seconds(source.length, sample_rate: @sample_rate).to_f
      end

      # Checks a level parameter: a number or graph node (a sampler branch).
      def param(value, name)
        return value.to_f if value.is_a?(Numeric)
        raise ArgumentError, "#{name} must be a number or graph node (got #{value.inspect})" unless value.respond_to?(:sample)
        value.get_sampler
      end

      # Checks an input: nil, a number, or a graph node (a sampler branch).
      def input(value, name)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)
        raise ArgumentError, "#{name} must be a graph node or number (got #{value.inspect})" unless value.respond_to?(:sample)
        value.get_sampler
      end
    end
  end
end
