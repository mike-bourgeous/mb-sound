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
    # Shapes (+:shape+, or #shape): each segment is :exp (the curve above;
    # the default) or :s, an S-curve: a smoothstep of the same curve, so
    # it starts and ends with zero slope and joins its neighbors without a
    # corner (the old smoothstep ADSREnvelope's shape, at 0 dB).  The curve
    # skews the S: negative dB swells, positive moves fast first.  When
    # something changes mid-segment (a release, a retrigger, a time,
    # level, or curve node), an S segment keeps its phase, re-plans the
    # rest from the current level, and carries the old slope for up to 2
    # ms (moving at most 1% of the step) so neither the level nor its
    # slope jumps.  Presets :smooth and :pad set S on every segment.
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
    # the same force drives it.  With :zero every note starts from 0, like
    # the SQ-80's ENV restart mode (an audible restart, by design, if the
    # envelope was sounding).  From silence all modes are the same.  (Synth voices reused for a repeated
    # note also reset key-synced oscillators' phases; ringing patches that
    # use :add usually want `.free` oscillators.)
    #
    # With no gate and no trigger, the envelope is a one-shot: it starts on
    # its first sample, releases +:hold+ seconds later (from wherever it is,
    # so a hold shorter than the attack and decay cuts them short), and
    # then #sample returns nil once the release ends.  Gated and triggered envelopes never end;
    # #idle? tells when they are silent.
    #
    # Multi-segment envelopes: every constructor (adsr, env, amp_env,
    # fm_env, filter_env, and the Notes versions) also takes a segment list
    # of [level, time, curve, shape] (curve and shape optional), named :t1,
    # :t2, ...: each segment moves from wherever the envelope is to its
    # level (relative to the velocity peak; negative levels are fine) over
    # its time.  +release_at:+ is the index (or name) of the first release
    # segment (default: the last); the level of the segment before it is
    # the sustain level.  +loop:+ (an index, a name, or true for 0) makes
    # the segment before the release jump back to that segment instead of
    # sustaining, until the release; a loop at the release index runs
    # straight into the release (the SQ-80's CYC mode, with a trigger and
    # no gate).  Curves and shapes not given per segment come from the
    # preset by role: the first segment is the attack, the others before
    # the release decays, the rest releases (curve Hashes may name roles
    # or segments).  ADSR is the list [[1, a], [s, d], [0, r]], sample for
    # sample.  See also EnvelopeMethods#sq80_env and MB::Sound::SQ80.
    #
    #     play 220.hz.ramp * env([[1, 0.01], [0.3, 0.2], [0.8, 1.5], [0, 0.5]], release_at: 3, hold: 3)
    #     wobble = env([[1, 0.005], [0, 0.1, 0], [1, 0.1, 0], [0, 0.2]], release_at: 3, loop: 1, gate: g)
    #
    # Example:
    #     play 220.hz.ramp * adsr(0.01, 0.3, 0.5, 1, curve: :snappy)
    #     play 110.hz.ramp.filter(:lowpass, cutoff: 200.constant * filter_env(0.01, 0.4, depth: 4), quality: 4)
    #     play 200.hz.fm(400.hz.at(800) * fm_env(0, 1)) * amp_env(0.001, 1, 0, 0.5)
    #     play 110.hz.ramp * adsr(1, 0.5, 0.6, 1, curve: :smooth, hold: 2)
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
        smooth: [0, 0, 0].freeze,
        pad: [0, 12, 12].freeze,
      }.freeze

      # Segment shapes for the CURVES presets that set them (the rest set
      # :exp on every segment): :smooth is plain smoothstep S-curves (the
      # old smoothstep ADSREnvelope, without its corners), :pad S-curves
      # whose decay and release move a little faster first (see SHAPES).
      CURVE_SHAPES = {
        smooth: :s,
        pad: :s,
      }.freeze

      # Segment shapes (the C enum env_shape), see #shape:
      # - :exp (alias :exponential): the curve in dB (see CURVES); the
      #   default.
      # - :s (alias :scurve): a smoothstep of the same curve, starting and
      #   ending with zero slope, so joints between S segments have no
      #   corner.  The curve in dB skews the S: 0 is plain smoothstep,
      #   negative values swell (slow first), positive values move fast
      #   first.  Changes mid-segment keep the slope at a 2 ms scale (see
      #   S_SLOPE_TIME).
      SHAPES = { exp: 0, s: 1 }.freeze
      SHAPE_ALIASES = { exponential: :exp, scurve: :s }.freeze
      SHAPE_EXP = 0
      SHAPE_S = 1

      # The longest time (seconds) an S segment carries the old slope after
      # a change mid-segment (a release, a retrigger, or a parameter node
      # moving), fading it out so the level and its slope stay continuous
      # (see the C kernel's description).
      S_SLOPE_TIME = 0.002

      # The largest bump that slope correction may add, relative to the
      # segment's step (the correction gets shorter to stay within it).
      S_OVERSHOOT = 0.01

      # The smallest step the overshoot bound uses (the C ENV_MIN_STEP).
      MIN_STEP = 1e-3

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
        fm_env: { curve: :dx, sustain: 0, sensitivity: -12.db..0.db, velocity_scale: :db }.freeze,
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
      STATE_PREV_LEVEL = 19
      STATE_PLAN_SHAPE = 20
      STATE_PHASE = 21
      STATE_RATE = 22
      STATE_S_ANCHOR = 23
      STATE_WARP_INV = 24
      STATE_WARP_LINEAR = 25
      STATE_CORR_SLOPE = 26
      STATE_CORR_TIME = 27
      STATE_CORR_POSITION = 28
      STATE_SIZE = 29

      # Kernel flags.
      FLAG_GATE = 1
      FLAG_TRIGGER = 2
      FLAG_ONE_SHOT = 4
      FLAG_LEGATO = 8
      FLAG_OCTAVES = 16
      FLAG_LIFT = 32
      FLAG_ADD = 64
      FLAG_ZERO = 128

      # Retrigger modes (see #retrigger): :restart attacks from the current
      # level to the new note's velocity peak; :add attacks to the energy
      # sum of the current level and that peak; :zero drops to 0 and
      # attacks from there (the SQ-80's ENV restart; clicks if sounding).
      RETRIGGER_MODES = [:restart, :add, :zero].freeze

      # How far an :add retrigger may rise above its own velocity peak
      # (sqrt(2): two equal strikes summed in energy, +3 dB; the C
      # ENV_ADD_LIMIT).
      ADD_LIMIT = 1.4142135623730951

      # The most segments an envelope may have (the C ENV_MAX_SEGMENTS).
      MAX_SEGMENTS = 16

      # The most loop jumps on one sample (the C ENV_MAX_LOOP_JUMPS): a loop
      # of zero-length segments sustains instead of spinning forever.
      MAX_LOOP_JUMPS = MAX_SEGMENTS

      # Remaining curvature below which a segment is planned as a line (the
      # C ENV_LINEAR_LIMIT).
      LINEAR_LIMIT = 1e-9

      # Creates an envelope from the preset +name+ in PRESETS (:adsr, :env,
      # :amp_env, :fm_env, or :filter_env), with optional positional times
      # and sustain level, and any #initialize options (which override the
      # preset).  +:depth+ is an alias for +:octaves+.
      #
      # A segment list (an Array; see .segments) in place of +attack+ makes a
      # multi-segment envelope with the preset's curves (by segment role),
      # velocity settings, and octaves; +decay+, +sustain+, and +release+
      # must then be left out.
      #
      #     Envelope.preset(:amp_env, [[1, 0.01], [0.5, 0.4], [0.8, 1], [0, 0.5]], release_at: 3)
      def self.preset(name, attack = nil, decay = nil, sustain = nil, release = nil, **options)
        settings = PRESETS.fetch(name) { raise ArgumentError, "Unknown envelope preset #{name.inspect} (#{PRESETS.keys.join(', ')})" }

        if attack.is_a?(Array)
          raise ArgumentError, 'Give a segment list or ADSR times, not both' unless [decay, sustain, release].all?(&:nil?)
          raise ArgumentError, 'Give the segment list once' if options.key?(:segments)
          options[:segments] = attack
          attack = nil
        end

        if options.key?(:segments)
          settings = settings.except(:sustain)
          settings = settings.merge(curve: SEGMENTS.zip(settings[:curve]).to_h) if settings[:curve].is_a?(Array)
        end

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
      # node for every segment, an Array of one value per segment ([attack,
      # decay, release] for ADSR), or a Hash of some segments (the rest come
      # from +current+).
      #
      # For multi-segment envelopes (see .segments), +:names+ lists the
      # segment names and +:release_node+ the first release segment; preset
      # curves then apply by role (the first segment takes the preset's
      # attack curve, the others before the release its decay curve, the
      # release segments its release curve; see .segment_role), Hash keys
      # may be segment names or roles (:attack, :decay, :release), and a
      # three-value Array applies by role when there aren't three segments.
      def self.curve_values(curve, current = nil, names: SEGMENTS, release_node: RELEASE_NODE)
        current ||= role_values(CURVES[:analog], names, release_node)
        values = case curve
                 when Symbol
                   role_values(CURVES.fetch(curve) { raise ArgumentError, "Unknown curve preset #{curve.inspect} (#{CURVES.keys.join(', ')})" }, names, release_node)

                 when Array
                   by_position(curve, names, release_node, 'Curve')

                 when Hash
                   by_key(curve, current, names, release_node, 'curve')

                 else
                   names.map { |s| [s, curve] }.to_h
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

      # Returns a Hash of shapes (:exp or :s) for each segment (see SEGMENTS)
      # from any shape specification: a Symbol for every segment (see
      # SHAPES), an Array of one per segment ([attack, decay, release] for
      # ADSR), or a Hash of some segments (the rest come from +current+).
      # +:names+ and +:release_node+ are as for .curve_values.
      def self.shape_values(shape, current = nil, names: SEGMENTS, release_node: RELEASE_NODE)
        current ||= names.map { |s| [s, :exp] }.to_h
        values = case shape
                 when Array
                   by_position(shape, names, release_node, 'Shape')

                 when Hash
                   by_key(shape, current, names, release_node, 'shape')

                 else
                   names.map { |s| [s, shape] }.to_h
                 end

        values.transform_values { |v|
          v = SHAPE_ALIASES.fetch(v, v)
          unless SHAPES.key?(v)
            raise ArgumentError, "Unknown segment shape #{v.inspect} (#{(SHAPES.keys + SHAPE_ALIASES.keys).join(', ')})"
          end
          v
        }
      end

      # The role of segment +index+ for presets and GM time scaling: the
      # first segment is the :attack, the others before +release_node+ are
      # :decay, and the rest are :release.
      def self.segment_role(index, release_node)
        return :attack if index == 0
        index < release_node ? :decay : :release
      end

      # A Hash of segment name to the value for its role from an [attack,
      # decay, release] triple (see .segment_role).
      def self.role_values(triple, names, release_node)
        roles = SEGMENTS.zip(triple).to_h
        names.each_with_index.map { |n, i| [n, roles[segment_role(i, release_node)]] }.to_h
      end

      # Values by position (one per segment, or an [attack, decay, release]
      # triple by role for multi-segment envelopes).
      def self.by_position(list, names, release_node, what)
        return names.zip(list).to_h if list.length == names.length
        return role_values(list, names, release_node) if list.length == SEGMENTS.length

        raise ArgumentError, "#{what} arrays need #{names.length} values (#{names.join(', ')})"
      end

      # Values from a Hash of segment names or roles merged over +current+
      # (roles first, so a segment name wins over its role).
      def self.by_key(hash, current, names, release_node, what)
        roles = names.each_with_index.map { |n, i| [n, segment_role(i, release_node)] }.to_h
        extra = hash.keys - names - SEGMENTS
        raise ArgumentError, "Unknown #{what} segments #{extra.inspect} (#{(names | SEGMENTS).join(', ')})" unless extra.empty?

        values = current.dup
        if names != SEGMENTS
          hash.each { |k, v| names.each { |n| values[n] = v if roles[n] == k } if SEGMENTS.include?(k) && !names.include?(k) }
        end
        hash.each { |k, v| values[k] = v if names.include?(k) }
        values
      end

      private_class_method :role_values, :by_position, :by_key

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
      # +:curve+ - Curves in dB (see .curve_values and CURVES).  A preset
      #           name also sets the shapes (see CURVE_SHAPES).
      # +:shape+ - Segment shapes: :exp or :s for every segment, or per
      #           segment (see .shape_values, SHAPES, and #shape); applied
      #           after +:curve+.
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
      # +:retrigger+ - :restart (default), :add, or :zero (see the class
      #                description and #retrigger).
      # +:octaves+ - If not nil or 0, the output is 2 ** (level * octaves), a
      #              cutoff multiplier (a number of octaves, anything with
      #              #to_octaves such as an Interval, or a graph node read
      #              every sample, e.g. the mod wheel).
      #
      # Multi-segment envelopes (see .segments) take +:segments+ (a list of
      # [level, time, curve, shape] entries, curve and shape optional), with
      # +:release_at+ (the index or name of the first release segment;
      # default the last segment) and +:loop+ (nil, or the index or name of
      # the segment to jump back to from the segment before the release, or
      # true for 0), instead of +:attack+, +:decay+, +:sustain+, and
      # +:release+.  Per-segment curves and shapes in the list override
      # +:curve+ and +:shape+.
      def initialize(
        attack: nil, decay: nil, sustain: nil, release: nil,
        segments: nil, release_at: nil, loop: nil,
        curve: :analog, shape: nil, hold: nil,
        gate: nil, trigger: nil, velocity: nil, choke: nil, lift: nil,
        sensitivity: 0..1, velocity_range: nil, velocity_scale: :linear, legato: false, octaves: nil,
        retrigger: :restart, sample_rate: 48000
      )
        @sample_rate = sample_rate.to_f
        raise ArgumentError, "Sample rate must be positive (got #{sample_rate.inspect})" unless @sample_rate > 0

        @times = {}
        @levels = {}
        if segments.nil?
          raise ArgumentError, 'release_at: and loop: need a segment list (segments:)' unless release_at.nil? && (loop.nil? || loop == false)

          @names = SEGMENTS
          @release_node = RELEASE_NODE
          @loop_node = nil
          @levels[:attack] = 1.0
          @levels[:release] = 0.0
          self.attack = attack.nil? ? DEFAULT_ATTACK : attack
          self.decay = decay.nil? ? DEFAULT_DECAY : decay
          self.release = release.nil? ? DEFAULT_RELEASE : release
          self.sustain = sustain.nil? ? DEFAULT_SUSTAIN : sustain
          list = nil
        else
          unless [attack, decay, sustain, release].all?(&:nil?)
            raise ArgumentError, 'Give segments: or attack:/decay:/sustain:/release:, not both'
          end
          list = setup_segments(segments, release_at, loop)
        end
        self.hold = hold

        @curves = nil
        @shapes = nil
        self.curve(curve)
        self.shape(shape) unless shape.nil?
        apply_segment_styles(list) if list

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

      # The segment names in order: [:attack, :decay, :release] for ADSR
      # envelopes, :t1, :t2, ... for multi-segment envelopes (see
      # .segments).
      attr_reader :names
      alias segment_names names

      # The index of the first release segment (see .segments).
      attr_reader :release_node

      # The index of the segment that the segment before the release jumps
      # back to (see .segments), or nil.
      attr_reader :loop_node

      # True for a multi-segment envelope (see .segments).
      def multi?
        !@names.equal?(SEGMENTS)
      end

      # The segments as an Array of Hashes with :name, :level (relative to
      # the peak), :time (as given), :curve (dB), and :shape.
      def segments
        @names.map { |n| { name: n, level: @levels[n], time: @times[n].length, curve: @curves[n], shape: @shapes[n] } }
      end

      # Times as given (seconds, lengths, or graph nodes): the first
      # segment's, the second's, and the first release segment's.
      def attack
        @times[@names[0]].length
      end

      def decay
        @times[@names[1]].length
      end

      def release
        @times[@names[@release_node]].length
      end

      # Times in seconds (lengths converted at the current tempo), or nil for
      # times from graph nodes.
      def attack_time
        seconds(@times[@names[0]])
      end

      def decay_time
        seconds(@times[@names[1]])
      end

      def release_time
        seconds(@times[@names[@release_node]])
      end

      # The time of segment +name+ (a name or index) as given.
      def time(name)
        @times[segment_name(name)].length
      end

      # The level of segment +name+ (a name or index; a number or node).
      def level_of(name)
        @levels[segment_name(name)]
      end

      # The sustain level (a number or graph node), relative to the peak:
      # the level of the segment before the release.
      def sustain
        @levels[@names[@release_node - 1]]
      end
      alias sustain_level sustain

      # Changes the attack time (seconds, a length, or a graph node).
      def attack=(time)
        set_time(@names[0], time)
      end
      alias attack_time= attack=

      # Changes the decay time (seconds, a length, or a graph node).
      def decay=(time)
        set_time(@names[1], time)
      end
      alias decay_time= decay=

      # Changes the release time (seconds, a length, or a graph node).
      def release=(time)
        set_time(@names[@release_node], time)
      end
      alias release_time= release=

      # Changes the time of segment +name+ (a name or index; seconds, a
      # length, or a graph node).
      def set_time(name, time)
        name = segment_name(name)
        @times[name] = Length::Source.new(time)
        @default_hold = nil if @names.index(name) < @release_node
        changed!
        self
      end

      # Changes the level of segment +name+ (a name or index; a number or
      # graph node, relative to the peak).
      def set_level(name, level)
        name = segment_name(name)
        @levels[name] = param(level, name == @names[@release_node - 1] ? 'Sustain' : 'Level')
        changed!
        self
      end

      # Changes the sustain level (a number or graph node, relative to the
      # peak): the level of the segment before the release.
      def sustain=(level)
        set_level(@names[@release_node - 1], level)
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
      # three values for attack, decay, and release.  A preset name (see
      # CURVES) also sets every segment's shape (:exp, or the preset's
      # CURVE_SHAPES entry).
      #
      # Example:
      #     adsr(0.01, 0.5, 0.3, 1).curve(:snappy)
      #     adsr(0.01, 0.5, 0.3, 1).curve(release: 30)
      #     adsr(0.01, 0.5, 0.3, 1).curve(0, 60, 60)
      #     adsr(1, 0.5, 0.6, 1).curve(:smooth)   # S-curves (see #shape)
      def curve(*args)
        return @curves.dup if args.empty?

        spec = args.length == 1 ? args.first : args
        values = self.class.curve_values(spec, @curves, names: @names, release_node: @release_node)
        @curves = values.transform_values { |v| v.is_a?(Numeric) ? v : v.get_sampler }
        @shapes = self.class.shape_values(CURVE_SHAPES.fetch(spec, :exp), names: @names, release_node: @release_node) if spec.is_a?(Symbol) || @shapes.nil?
        changed!
        self
      end
      alias curves curve

      # Sets segment shapes (see SHAPES and .shape_values) and returns self,
      # or returns the shapes (a Hash of segment => :exp or :s) without
      # arguments.  Accepts a shape for every segment, a Hash of some
      # segments, an Array, or three values for attack, decay, and release.
      # The curves in dB (see #curve) keep their meaning: for :s segments
      # they skew the S (0 is plain smoothstep, negative swells, positive
      # moves fast first).
      #
      # Example:
      #     adsr(1, 0.5, 0.6, 1).shape(:s)          # the old smoothstep feel
      #     amp_env(2, 1, 0.5, 2).shape(attack: :s).curve(attack: -6)
      #     adsr(1, 0.5, 0.6, 1).shape(:s).curve(attack: 12.hz.lfo.at(12))
      def shape(*args)
        return @shapes.dup if args.empty?

        spec = args.length == 1 ? args.first : args
        @shapes = self.class.shape_values(spec, @shapes, names: @names, release_node: @release_node)
        changed!
        self
      end
      alias shapes shape

      # Sets segment shapes (see #shape).
      def shape=(spec)
        shape(spec)
      end

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

      # Sets the retrigger mode (:restart, :add, or :zero; see the class description)
      # and returns self, or returns the mode without an argument.
      #
      # Example:
      #     v.amp_env(0.001, 6, 0, 5).retrigger(:add)
      def retrigger(mode = nil)
        return @retrigger if mode.nil?
        self.retrigger = mode
        self
      end

      # Sets the retrigger mode (:restart, :add, or :zero; see the class
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
        when STAGE_SEGMENT then @names[@state[STATE_SEGMENT].to_i]
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
        @levels.each { |name, l| s[level_key(name)] = l if l.respond_to?(:sample) }
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
        return "#{super} -- #{multi_to_s}" if multi?

        times = [@times[:attack], @times[:decay], sustain, @times[:release]].map { |t|
          t.is_a?(Numeric) ? MB::M.sigfigs(t, 4) : t.to_s
        }
        preset_shapes = ->(k) { self.class.shape_values(CURVE_SHAPES.fetch(k, :exp)) }
        names = CURVES.select { |_, v| v == @curves.values }.keys
        preset = names.find { |k| preset_shapes.(k) == @shapes } || names.first
        curves = preset || @curves.values.map { |c| c.is_a?(Numeric) ? MB::M.sigfigs(c, 4) : c.to_s }.join('/')
        shapes = " shape #{@shapes.values.join('/')}" unless preset_shapes.(preset) == @shapes
        "#{super} -- adsr(#{times.join(', ')}) curve #{curves}#{shapes}#{' retrigger add' if @retrigger == :add}"
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
        flags |= FLAG_ZERO if @retrigger == :zero

        [
          flags,
          @release_node,
          @velocity_low,
          @velocity_high,
          @velocity_scale == :db ? 1 : 0,
          CHOKE_TIME * @sample_rate,
          CURVE_SCALE,
          S_SLOPE_TIME * @sample_rate,
          S_OVERSHOOT,
          *(@loop_node ? [@loop_node] : []),
        ]
      end

      # The Ruby mirror of MB::Sound::FastEnvelope.process (see
      # ext/mb/sound/fast_envelope/fast_envelope.c for the arguments and
      # algorithm).  Uses exactly the same operations, so the output and
      # state are identical.
      def self.process_ruby(out, state, times, curves, levels, hold, inputs, config, shapes)
        n = out.length
        nseg = times.length
        raise ArgumentError, 'Config must have 9 or 10 values' unless config.length == 9 || config.length == 10
        flags, release_node, velocity_low, velocity_high, velocity_db, choke_samples, curve_scale, slope_samples, overshoot, loop_node = config
        flags = Integer(flags)
        release_node = Integer(release_node)
        velocity_low = velocity_low.to_f
        velocity_high = velocity_high.to_f
        velocity_db = velocity_db.to_i != 0
        choke_samples = length_samples(choke_samples.to_f)
        curve_scale = curve_scale.to_f
        slope_samples = slope_samples.to_f
        overshoot = overshoot.to_f
        seg_shapes = shapes.map { |v| Integer(v) }
        raise ArgumentError, 'Times, curves, levels, and shapes must have the same number of segments' unless seg_shapes.length == nseg
        raise ArgumentError, "Unknown segment shape in #{shapes}" unless seg_shapes.all? { |v| v == SHAPE_EXP || v == SHAPE_S }

        raise ArgumentError, 'Release node out of range' unless release_node >= 1 && release_node < nseg
        loop_node = loop_node.nil? ? -1 : Integer(loop_node)
        raise ArgumentError, 'Loop node out of range' unless loop_node >= -1 && loop_node <= release_node

        has_gate = flags & FLAG_GATE != 0
        has_trigger = flags & FLAG_TRIGGER != 0
        one_shot = flags & FLAG_ONE_SHOT != 0
        legato = flags & FLAG_LEGATO != 0
        use_octaves = flags & FLAG_OCTAVES != 0
        has_lift = flags & FLAG_LIFT != 0
        add = flags & FLAG_ADD != 0
        zero = flags & FLAG_ZERO != 0

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
        y_prev = st[STATE_PREV_LEVEL]
        plan_shape = st[STATE_PLAN_SHAPE].to_i
        u = st[STATE_PHASE]
        rate = st[STATE_RATE]
        s_anchor = st[STATE_S_ANCHOR]
        warp_inv = st[STATE_WARP_INV]
        warp_linear = st[STATE_WARP_LINEAR] != 0
        corr_slope = st[STATE_CORR_SLOPE]
        corr_time = st[STATE_CORR_TIME]
        corr_position = st[STATE_CORR_POSITION]
        # The S planner's own anchor, scale, and warp recursion (the C struct
        # env_s_plan), saved instead of the exp planner's while it plans
        s_e0, s_y0, s_scale, s_w, s_g = e0, y0, scale, w, g

        result = Array.new(n)

        n.times do |i|
          gate_now = has_gate && at(gate_sig, i) != 0
          start = stage == STAGE_PENDING
          landed = false
          loop_jumps = 0
          y_last = y

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
            if zero
              y = 0.0
              y_prev = 0.0
              y_last = 0.0
            end
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
                landed = true

                if stage == STAGE_CHOKE || seg == nseg - 1
                  stage = one_shot ? STAGE_ENDED : STAGE_IDLE
                elsif seg == release_node - 1
                  if loop_node >= 0 && loop_jumps < MAX_LOOP_JUMPS
                    seg = loop_node
                    loop_jumps += 1
                  else
                    stage = STAGE_SUSTAIN
                  end
                else
                  seg += 1
                end

                next
              end

              shape = stage == STAGE_CHOKE ? SHAPE_EXP : seg_shapes[seg]

              if shape == SHAPE_S
                if !planned || length != plan_length || curve != plan_curve || target != plan_target || plan_shape != SHAPE_S
                  full = !planned || e == 0 || plan_shape != SHAPE_S || curve != plan_curve
                  timing = full || length != plan_length
                  c = curve * curve_scale

                  s_e0 = e > 0 ? e - 1 : 0.0
                  s_y0 = y
                  if e == 0
                    u = 0.0
                  elsif plan_shape != SHAPE_S
                    u = s_e0 / length
                  end

                  if full
                    warp_linear = c.abs < LINEAR_LIMIT
                    unless warp_linear
                      warp_inv = 1.0 / (1.0 - Math.exp(c))
                      s_w = Math.exp(c * u)
                    end
                  end
                  if timing
                    rate = (1.0 - u) / (length - s_e0)
                    s_g = Math.exp(c * rate) unless warp_linear
                  end

                  p = warp_linear ? u : (1.0 - s_w) * warp_inv
                  s_anchor = p * p * (3.0 - 2.0 * p)
                  span = 1.0 - s_anchor
                  s_scale = span > 0 ? (target - s_y0) / span : 0.0

                  corr_position = 0.0
                  corr_time = 0.0
                  corr_slope = 0.0
                  unless landed
                    dp = warp_linear ? 1.0 : -c * s_w * warp_inv
                    corr_slope = (y - y_prev) - s_scale * (6.0 * p * (1.0 - p)) * dp * rate
                    if corr_slope != 0
                      step = (target - s_y0).abs
                      step = MIN_STEP if step < MIN_STEP
                      limit = 27.0 * overshoot * step / (4.0 * corr_slope.abs)
                      corr_time = length - s_e0
                      corr_time = slope_samples if slope_samples < corr_time
                      corr_time = limit if limit < corr_time
                      corr_time = 1.0 if corr_time < 1
                    end
                  end

                  planned = true
                  plan_length = length
                  plan_curve = curve
                  plan_target = target
                  plan_shape = SHAPE_S
                end

                if e > s_e0
                  u += rate
                  s_w *= s_g unless warp_linear
                end
                corr_position += 1

                p = warp_linear ? u : (1.0 - s_w) * warp_inv
                y = s_y0 + s_scale * (p * p * (3.0 - 2.0 * p) - s_anchor)
                if corr_position < corr_time
                  x = corr_position / corr_time
                  h = 1.0 - x
                  y += corr_slope * corr_time * (x * h * h)
                end

                e += 1
                break
              end

              if !planned || length != plan_length || curve != plan_curve || target != plan_target || plan_shape != SHAPE_EXP
                planned = true
                plan_length = length
                plan_curve = curve
                plan_target = target
                plan_shape = SHAPE_EXP
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

          y_prev = y_last
          note_position += 1
          result[i] = use_octaves ? 2.0 ** (y * at(octaves_sig, i)) : y
        end

        out[0..] = result unless n == 0

        e0, y0, scale, w, g = s_e0, s_y0, s_scale, s_w, s_g if plan_shape == SHAPE_S

        state[0..] = [
          stage, seg, e, y, peak, gate_prev ? 1 : 0, planned ? 1 : 0, plan_length, plan_curve, plan_target,
          e0, y0, scale, w, g, linear ? 1 : 0, trigger_prev ? 1 : 0, note_position, release_scale,
          y_prev, plan_shape, u, rate, s_anchor, warp_inv, warp_linear ? 1 : 0, corr_slope, corr_time, corr_position
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
        times, curves, levels, inputs, config, _hold, shapes = args
        @names.each_with_index do |s, i|
          times[i] = read_length(s, @times[s], count) if @times[s].node?
          curves[i] = read_param(curve_key(s), @curves[s], count) unless @curves[s].is_a?(Numeric)
          levels[i] = read_param(level_key(s), @levels[s], count) unless @levels[s].is_a?(Numeric)
        end
        hold = args[5]
        hold = read_length(:hold, @hold || default_hold, count) if hold.nil?
        inputs[0] = read_input(:gate, @gate, count, 0.0) if @gate.respond_to?(:sample)
        inputs[1] = read_input(:trigger, @trigger, count, 0.0) if @trigger.respond_to?(:sample)
        inputs[2] = read_input(:velocity, @velocity, count, nil) if @velocity.respond_to?(:sample)
        inputs[3] = read_input(:choke, @choke, count, 0.0) if @choke.respond_to?(:sample)
        inputs[4] = read_input(:lift, @lift, count, nil) if @lift.respond_to?(:sample)
        inputs[5] = read_param(:octaves, @octaves, count) if @octaves.respond_to?(:sample)

        if kernel == :ruby
          self.class.process_ruby(@buf, @state, times, curves, levels, hold, inputs, config, shapes)
        elsif quiet_idle?(inputs, config)
          return idle_buffer(count)
        else
          MB::Sound::FastEnvelope.process(@buf, @state, times, curves, levels, hold, inputs, config, shapes)
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
        @state[STATE_PREV_LEVEL] = 0
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
      # curves, levels, inputs, config, hold, shapes].
      def kernel_args
        times = @names.map { |s| @times[s].node? ? nil : @times[s].constant_samples(@sample_rate) }
        curves = @names.map { |s| @curves[s].is_a?(Numeric) ? @curves[s] : nil }
        levels = @names.map { |s| @levels[s].is_a?(Numeric) ? @levels[s] : nil }
        inputs = [@gate, @trigger, @velocity, @choke, @lift, @octaves].map { |v| v.respond_to?(:sample) ? nil : v }

        hold_source = @hold == false ? nil : (@hold || default_hold)
        hold = hold_source.nil? ? Float::INFINITY : (hold_source.node? ? nil : hold_source.constant_samples(@sample_rate))

        shapes = @names.map { |s| SHAPES.fetch(@shapes[s]) }

        [times, curves, levels, inputs, kernel_config, hold, shapes]
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
        @default_hold ||= Length::Source.new([2.0 * @names[0...@release_node].map { |n| fixed_seconds(@times[n]) }.inject(:+), MIN_HOLD].max)
      end

      # The key for the last values of segment +name+'s curve node (see
      # #fit).
      def curve_key(name)
        CURVE_KEYS[name] || :"#{name}_curve"
      end

      # The key for segment +name+'s level node in #sources and #fit
      # (:sustain for ADSR envelopes, as before multi-segment envelopes).
      def level_key(name)
        multi? ? :"#{name}_level" : :sustain
      end

      # The segment name for a name or 0-based index.
      def segment_name(name)
        return @names.fetch(name) { raise ArgumentError, "No segment #{name} (#{@names.length} segments)" } if name.is_a?(Integer)
        raise ArgumentError, "Unknown segment #{name.inspect} (#{@names.join(', ')})" unless @names.include?(name)
        name
      end

      # Sets up the segments of a multi-segment envelope from +list+ (see
      # #initialize) and returns the normalized list of [level, time, curve,
      # shape].
      def setup_segments(list, release_at, loop)
        raise ArgumentError, "A segment list must be an Array (got #{list.inspect})" unless list.is_a?(Array)
        unless list.length.between?(2, MAX_SEGMENTS)
          raise ArgumentError, "Envelopes need 2 to #{MAX_SEGMENTS} segments (got #{list.length})"
        end

        list = list.map { |seg| normalize_segment(seg) }
        @names = list.length.times.map { |i| :"t#{i + 1}" }.freeze
        @release_node = segment_index(release_at.nil? ? list.length - 1 : release_at, 'release_at')
        raise ArgumentError, "release_at: must be from 1 to #{list.length - 1} (got #{release_at.inspect})" unless @release_node.between?(1, list.length - 1)

        @loop_node = case loop
                     when nil, false then nil
                     when true then 0
                     else segment_index(loop, 'loop')
                     end
        if @loop_node && !@loop_node.between?(0, @release_node)
          raise ArgumentError, "loop: must be a segment from 0 to the release segment #{@release_node} (got #{loop.inspect})"
        end

        list.each_with_index do |(level, time, _, _), i|
          set_level(@names[i], level)
          set_time(@names[i], time)
        end

        list
      end

      # A segment as [level, time, curve, shape] from an Array or a Hash with
      # :level, :time, :curve, :shape.
      def normalize_segment(seg)
        case seg
        when Array
          raise ArgumentError, "Segments are [level, time, curve, shape] (got #{seg.inspect})" unless seg.length.between?(2, 4)
          seg.values_at(0, 1, 2, 3)
        when Hash
          extra = seg.keys - [:level, :time, :curve, :shape]
          raise ArgumentError, "Unknown segment keys #{extra.inspect}" unless extra.empty?
          raise ArgumentError, "Segments need a level and a time (got #{seg.inspect})" unless seg.key?(:level) && seg.key?(:time)
          seg.values_at(:level, :time, :curve, :shape)
        else
          raise ArgumentError, "Segments are [level, time, curve, shape] Arrays or Hashes (got #{seg.inspect})"
        end
      end

      # The 0-based index for a segment index or name (:t1 is 0).
      def segment_index(value, what)
        case value
        when Integer then value
        when Symbol
          idx = @names.index(value)
          raise ArgumentError, "Unknown segment #{value.inspect} for #{what}: (#{@names.join(', ')})" unless idx
          idx
        else
          raise ArgumentError, "#{what}: must be a segment index or name (got #{value.inspect})"
        end
      end

      # Applies the curves and shapes given in a segment list.
      def apply_segment_styles(list)
        curves = @names.zip(list).filter_map { |n, seg| [n, seg[2]] unless seg[2].nil? }.to_h
        shapes = @names.zip(list).filter_map { |n, seg| [n, seg[3]] unless seg[3].nil? }.to_h
        curve(curves) unless curves.empty?
        shape(shapes) unless shapes.empty?
      end

      # #to_s for multi-segment envelopes.
      def multi_to_s
        num = ->(v) { v.is_a?(Numeric) ? MB::M.sigfigs(v, 4) : v.to_s }
        segs = @names.each_with_index.map { |n, i|
          mark = i == @release_node ? '| ' : ''
          mark += '@' if i == @loop_node
          "#{mark}#{num.(@levels[n])}/#{num.(@times[n].length)}"
        }
        "env(#{segs.join(', ')}) curve #{@curves.values.map(&num).join('/')}#{' retrigger add' if @retrigger == :add}"
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
