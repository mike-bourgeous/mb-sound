module MB
  module Sound
    module GraphNode
      # A named value that a performer turns (contract K6 in
      # design/notes/arrangement.md): `knob :cut, (100.hz..8000.hz).at(800.hz)`
      # in the console, then `knob(:cut)` wherever a graph
      # takes a number or a node, and `turn :cut, 3000, over: 2.bars` to move
      # it.  One object everywhere: its Spec is ControlSpec-shaped (name,
      # default, range, curve, unit, cc, takeover), plans read it as a param
      # (Plan::Op::Param, a fill while it holds still, so planned graphs keep
      # fusing), MIDI controllers can move it (#listen, #learn), and
      # MIDI::ControlMap lists it.
      #
      # A knob's value is a function of the session frame: a list of
      # segments, each starting on an exact frame (a held value, a ramp over
      # a number of frames shaped by an MB::Sound::Curve, or a node it
      # follows).  So changes land on their exact sample and ramps have the
      # same values at any buffer size (ramps and holds are computed from
      # the frame alone; a followed node gives what it gives at that buffer
      # size).
      #
      # Every consumer gets its own Reader (#get_sampler), and readers never
      # advance the knob: a Session advances each of its knobs once per
      # buffer (Session::Knobs), and readers return that buffer's values, so
      # one knob can drive any number of graphs, including players that are
      # muted and asleep.  A knob outside a Session advances as its readers
      # read it (each reader counts its own frames).
      #
      # Ramps start from the value on the frame before they land (a ramp
      # interrupting another ramp, or a node being followed, carries on from
      # where it was), and move in the knob's own scale: linearly for
      # +curve: :linear+ knobs, in octaves (log) for +curve: :exp+ ones.
      #
      #     cut = GraphNode::Knob.new(:cut, 800, range: 100..8000, curve: :exp)
      #     play 110.hz.saw.lp4(cut)
      #     cut.ramp_to(3000, frames: 96000, frame: cut.next_frame)   # (Session#turn does this)
      class Knob
        include GraphNode
        node_traits memory: :none

        # How a knob's value relates to a 0..1 position (its scale for
        # ramps, MIDI controllers, and snapshot crossfades): MB::Sound::Param's
        # curve names (canonical :linear and :exp; :lin, :exponential, :log,
        # and :db are aliases).
        CURVES = MB::Sound::Param::CURVES.reject { |_, c| c == :switch }.freeze

        # How a MIDI controller takes over: :pickup waits until the
        # controller passes the knob's position (no jumps), :jump moves the
        # knob right away.
        TAKEOVERS = [:pickup, :jump].freeze

        # The knob's description, built from an MB::Sound::Param (+param+,
        # the declaration: typed values, names-table ranges, checks) and
        # shaped like MIDI::ControlSpec (contract K6): +name+ (a Symbol),
        # +default+ (the starting value as a plain number in the param's
        # base unit: Hz for 2400.hz, seconds, the gain of -12.db), +range+
        # (a Range of Floats in that unit; 0..1 when the declaration has
        # none), +curve+ (:linear or :exp), +unit+ (a String for display,
        # or nil), +cc+ (a MIDI controller number, or nil), +takeover+
        # (:pickup or :jump), and +smooth+ (seconds over which a turn
        # without +over:+ glides, a declick; 0 for exact jumps).
        # +description:+ goes into the Param (rack knobs and document knob
        # lines have one).  +clamp: false+ lets the knob's default, turns,
        # follows, and modulation leave its range (the range still scales
        # controllers and the TUI; "sometimes going out of bounds is
        # interesting").
        #
        # The default may be a typed value or a ranged default:
        # `Spec.new(name: :cut, default: (150.hz..8000.hz).at(2400.hz))`.
        class Spec < Data.define(:name, :default, :unit, :cc, :takeover, :smooth, :param)
          def initialize(name:, default: nil, range: nil, curve: nil, unit: nil, cc: nil, takeover: :pickup, smooth: Session::Fades::DECLICK_SECONDS, description: nil, clamp: true, param: nil)
            raise ArgumentError, "Knob names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
            if curve && !CURVES.key?(curve)
              raise ArgumentError, "Unknown knob curve #{curve.inspect} (#{CURVES.keys.map(&:inspect).join(', ')})"
            end
            param ||= MB::Sound::Param.new(name: name, default: default, range: range, curve: curve, unit: unit, cc: cc, description: description, clamp: clamp)
            raise ArgumentError, "Knob #{name.inspect} holds numbers, not #{MB::Sound::Param.describe_type(param.type)}" unless param.numeric? || (param.default.nil? && param.range.nil?)
            raise ArgumentError, "Knob #{name.inspect} needs a range with two ends (got #{param.range.inspect})" if param.range && !param.bounded?
            raise ArgumentError, "Takeover must be #{TAKEOVERS.map(&:inspect).join(' or ')} (got #{takeover.inspect})" unless TAKEOVERS.include?(takeover)

            r = param.magnitude_range || (0.0..1.0)
            lo = r.begin
            hi = r.end
            raise ArgumentError, "Range must go up (got #{param.range.inspect})" unless hi > lo
            c = param.curve
            c = :linear if c == :switch # (a pedal's declaration as a knob: turned through its range)

            default = param.default.nil? ? lo : MB::Sound::Param.magnitude(param.default)
            raise ArgumentError, "Default must be a number (got #{default.inspect})" unless default.is_a?(Numeric) && default.real?
            if param.range.nil? && param.clamp && !default.to_f.between?(lo, hi)
              # (ux-1 item 30: `knob(:drive, 10)` was silently 1)
              MB::Sound.live_error(ArgumentError.new(
                "Knob #{name.inspect} starts at #{Knob.number(default)}, outside the default range 0..1, so it would be limited to " \
                "#{Knob.number(default.to_f.clamp(lo, hi))}; give it a range: knob #{name.inspect}, #{Knob.number(default)}, range: #{Spec.suggest_range(default)}"
              ))
            end
            default = param.clamp ? default.to_f.clamp(lo, hi) : default.to_f
            smooth = MB::Sound::Length.seconds(smooth).to_f
            raise ArgumentError, "smooth: must be 0 or more seconds (got #{smooth})" unless smooth >= 0

            unit = param.unit || (MB::Sound::Param::TYPE_UNITS[param.type] if param.type != :number)
            @scale = MB::Sound::Param::Scale.new(lo: lo, hi: hi, curve: c)
            @range = (lo..hi).freeze
            super(name: name, default: default, unit: unit&.to_s&.freeze, cc: param.cc, takeover: takeover, smooth: smooth, param: param)
          end

          # The knob's MB::Sound::Param::Scale (#range along #curve): the one
          # range mapping its positions, ramps, crossfades, controller moves,
          # and #mod read.
          attr_reader :scale

          # The range in the param's base unit (a Range of Floats; 0..1 when
          # the declaration has none): the #scale's span.
          attr_reader :range

          # :exp or :linear (a :switch declaration turns linearly): the
          # #scale's curve.
          def curve
            @scale.curve
          end

          # True when the declaration was a typed value (2400.hz rather
          # than 2400.0): #to_ruby prints it typed.
          def typed?
            v = param.default.nil? ? param.range&.begin : param.default
            !v.nil? && !(v.is_a?(Numeric) && !v.is_a?(MB::Sound::Decibels))
          end

          # The same Spec with +changes+ (the knob's options: default:,
          # range:, curve:, unit:, cc:, takeover:, smooth:): a new
          # declaration when any of the param's fields change.
          def respec(**changes)
            keep = changes.slice(:takeover, :smooth)
            decl = changes.except(:takeover, :smooth)
            return Spec.new(**to_h.merge(keep)) if decl.empty?
            fields = {
              default: param.typed(default), range: param.implied ? nil : param.range, curve: param.curve == param.default_curve ? nil : param.curve,
              unit: param.unit, cc: cc, description: param.description, clamp: param.clamp,
            }
            if decl.key?(:range) && !decl.key?(:default) && decl[:range].is_a?(Range) &&
               MB::Sound::Param.type_of(decl[:range].begin || decl[:range].end) != MB::Sound::Param.type_of(fields[:default])
              fields[:default] = default # (a plain range for a typed knob: its plain value)
              fields[:unit] = unit unless decl.key?(:unit)
            end
            if decl.key?(:default) && !decl.key?(:range) && MB::Sound::Param.type_of(decl[:default]) == :number && typed?
              decl = decl.merge(default: param.typed(decl[:default])) # (a plain number for a typed knob: in its base unit)
            end
            Spec.new(name: name, takeover: takeover, smooth: smooth, **fields.merge(decl))
          end

          # The 0..1 position of +value+ (a number or a Numo::DFloat) in the
          # range (beyond 0..1 outside it; Param::Scale.position).
          def position(value)
            MB::Sound::Param::Scale.position(value, range.begin, range.end, curve)
          end

          # The value at position +pos+ (a Float or a Numo::DFloat;
          # Param::Scale.value).
          def value(pos)
            MB::Sound::Param::Scale.value(pos, range.begin, range.end, curve)
          end

          # A range holding +value+ (for the hint when a default or a turn
          # is out of range): 0 to a round number above it, or from a
          # round number below it to 0.
          def self.suggest_range(value)
            v = value.to_f
            mag = 10**Math.log10([v.abs, 1e-9].max).ceil
            mag *= 10 if mag <= v.abs
            v >= 0 ? "0..#{Knob.number(mag)}" : "#{Knob.number(-mag)}..0"
          end

          # +value+ limited to the range (as a Float as it is, for a knob
          # declared with clamp: false).
          def clamp(value)
            param.clamp ? value.to_f.clamp(range.begin, range.end) : value.to_f
          end

          # True unless the knob was declared with clamp: false.
          def clamp?
            param.clamp
          end

          # A MIDI::ControlSpec for this knob's controller +number+ (its
          # +cc+ by default; for MIDI::ControlMap and ACID XML), or nil
          # without one.
          def to_control_spec(number = cc)
            return nil if number.nil?
            MIDI::ControlSpec.from_param(
              param, number: number, range: range, default_value: default, name: name.to_s,
              description: "Knob #{name.inspect}#{unit ? " (#{unit})" : ''}"
            )
          end

          # The arguments that declare this knob at +value+ (its default
          # unless given; a base-unit number), as text (+literal+ prints
          # values; Param.literal unless given): Param#declaration_args with
          # the name (+name+ unless nil), +cc+ (the knob's controller,
          # learned or declared), the knob's takeover: and smooth: when they
          # aren't the defaults, and the description when +description+.
          # The same spelling for the console, recipes, and graph documents
          # (format 5).
          def call_args(value: default, cc: self.cc, literal: nil, name: self.name, description: false)
            lit = literal || MB::Sound::Param.method(:literal)
            options = []
            options << "takeover: #{takeover.inspect}" unless takeover == :pickup
            options << "smooth: #{lit.(smooth)}" unless smooth == Session::Fades::DECLICK_SECONDS
            parts = param.declaration_args(value: param.typed(value), literal: lit, cc: cc, description: description, options: options)
            parts[0] = name.to_sym.inspect
            parts
          end

          # The console line that defines this knob (`knob :cut,
          # (150.hz..8000.hz).at(2400.hz)`; see #call_args).
          def to_ruby
            "knob #{call_args.join(', ')}"
          end

          def to_s
            "#{name.inspect} #{MB::M.sigfigs(range.begin, 4)}..#{MB::M.sigfigs(range.end, 4)}#{unit}" \
              "#{curve == :exp ? ' exp' : ''}#{cc ? " cc#{cc}" : ''}"
          end
        end

        # A value held from frame +start+ on.
        Hold = Struct.new(:start, :value)

        # A ramp from frame +start+ over +length+ frames to +to+ (the value
        # on frame start + length - 1 and after), shaped by +curve+ (an
        # MB::Sound::Curve or nil for linear).  +from+ is the value on the
        # frame before +start+, filled in when the ramp begins (unless
        # given).
        # +terms+ are the ramp's Param::Scale#ramp_terms, filled in when it
        # first renders.
        Ramp = Struct.new(:start, :length, :to, :curve, :from, :terms)

        # Follows +source+ (a sampler) from frame +start+ on.  +map+ (a
        # Proc given each buffer as a Numo::DFloat) turns its output into
        # values, or nil to clamp it to the range.  +timeline_nodes+ are
        # Sequence::TimelineNodes in the source's graph (see #follow), and
        # +time+ the landing position in whole notes.  +label+ describes
        # it.
        Follow = Struct.new(:start, :source, :map, :timeline_nodes, :label, :time)

        # A MIDI controller move landing on frame +start+: +position+ (0..1)
        # from controller +cc+.
        Move = Struct.new(:start, :position, :cc)

        # Reads a knob for one consumer (see Knob#get_sampler): the values of
        # the buffer its Session is rendering, or (outside a Session) the
        # next frames by its own count.
        class Reader
          include GraphNode
          node_traits memory: :none

          # The Knob read.
          attr_reader :knob

          def initialize(knob)
            @knob = knob
            @frame = nil
            @node_type_name = 'Knob'
          end

          def sample(count)
            return nil if count == 0
            v = @knob.read(next_frame_for(count), count)
            v.is_a?(Numo::NArray) ? v : @knob.steady_buffer(count, v)
          end

          # Moves past +count+ samples without reading them (a Synth lane
          # skipped while idle), returning self.
          def advance(count)
            next_frame_for(count)
            self
          end

          def sample_rate
            @knob.sample_rate
          end

          # Port type of the output (see GraphNode::Traversable#port_type).
          def port_type
            :control
          end

          def sources
            { knob: @knob }
          end

          def name
            @knob.name.to_s
          end

          def to_s
            "Knob #{@knob.name.inspect} (#{@knob.value_string})"
          end

          # MIDI controllers this knob listens to (see MIDI::ControlMap).
          def control_specs
            @knob.control_specs
          end

          # The knob's value at a timeline position (see Knob::ValueAt), so
          # a reader works as a MIDI::Param too.
          def value_at(pos = nil, frame: nil, transport: nil, stream: nil)
            @knob.value_at(pos, frame: frame)
          end

          # See Knob::ValueAt#choose.
          def choose(*choices)
            @knob.choose(*choices)
          end

          # Plan layer: a param read every block (Plan::Op::Param), a fill
          # while the knob holds still.
          include Plan::Describable

          def plan_describe(p)
            p.param(self, complex: false)
          end

          def plan_inputs
            []
          end

          # This block's value (a Float while the knob holds still over the
          # block) or its buffer.
          def plan_param(count)
            @knob.read(next_frame_for(count), count)
          end

          def plan_complex?
            false
          end

          def value_string
            @knob.value_string
          end

          def plan_snapshot
            [@frame, @clock]
          end

          def plan_restore(snapshot)
            @frame, @clock = snapshot
          end

          # Reads +knob+ from now on instead (a graph document's knob
          # joining a Session knob of the same name; see
          # Session::Knobs#adopt_knobs).
          def rebind(knob)
            raise ArgumentError, "Readers read Knobs (got #{knob.class})" unless knob.is_a?(Knob)
            @knob = knob
            @frame = nil
            @clock = nil
            self
          end

          private

          # The first frame of the block this read covers: the first frame
          # the Session is rendering for this reader's player (see
          # Knob#clock_frame), then on from there for further reads in the
          # same buffer (a graph read in pieces, e.g. a Synth's lanes split
          # where they fall asleep), or this reader's own count outside a
          # Session.
          def next_frame_for(count)
            c = @knob.clock_frame
            f = if c.nil?
                  @frame || @knob.block_frame
                elsif c == @clock && @frame && @frame > c
                  @frame
                else
                  c
                end
            @clock = c
            @frame = f + count
            f
          end
        end

        # The knob's Spec.
        attr_reader :spec

        # The Session that advances this knob every buffer (nil outside
        # one).
        attr_reader :session

        # The sample rate frames are counted at.
        attr_reader :sample_rate

        # The value on the last frame rendered (the default before any).
        attr_reader :value

        # The value a graph building now reads (GraphNode.build_value): the
        # value a turn of a build knob is heading to (#build_value=, set by
        # Session#turn before the rebuild it causes, which may build before
        # the turn lands), else #value.
        def build_value
          @build_value.nil? ? @value : @build_value
        end

        # See #build_value (nil: #value).
        attr_writer :build_value

        # The next frame to render.
        attr_reader :next_frame

        # The first frame of the last block computed (where a new reader
        # outside a Session starts, so readers created for one graph read in
        # step), or the next frame before any.
        def block_frame
          @span_frame || @next_frame
        end

        # The MIDI controller learned or given (overrides the Spec's +cc+),
        # or nil.
        attr_reader :cc

        # For a rack's knob (MB::Sound::RackMethods#rack_knob), its
        # Rack::KnobInfo (the rack, the knob's own name, the application
        # that made it, share:, follow:); nil for other knobs.
        attr_reader :rack_knob

        # The Session knob this standalone knob's readers were moved to
        # when it joined one of the same name (see #redirect), or nil.
        attr_reader :joined

        # Creates a knob named +name+ starting at +default+ (see Spec for
        # the options).  +session+ is the Session that advances it (see
        # Session::Knobs; Session#knob makes knobs), and +frame+ the first
        # frame it renders (the Session's frame counter).
        #
        # +initial+ starts the knob at another value than its Spec's
        # default (a rack instance's saved knob value; see Rack#using).
        def initialize(name, default = nil, session: nil, sample_rate: 48000, frame: 0, rack_knob: nil, initial: nil, **spec)
          @spec = Spec.new(name: name, default: default, **spec)
          @rack_knob = rack_knob
          @joined = nil
          @session = session
          @sample_rate = sample_rate.to_f
          @value = initial.nil? ? @spec.default : @spec.clamp(initial)
          @segment = Hold.new(frame, @value)
          @pending = []
          @next_frame = frame
          @span_frame = nil
          @span_count = 0
          @span_out = nil
          @steady = nil
          @steady_value = nil
          # Reused render buffers (two, alternating), their frozen views,
          # and scratch for ramps and follows (see #render; dropouts-2)
          @render_bufs = [nil, nil]
          @render_flip = 0
          @render_views = FrozenView.new
          @ramp_t = nil
          @ramp_scratch = nil
          @follow_buf = nil
          @follow_range = nil
          @cc = @spec.cc
          @midi = nil
          @learning = nil
          @picked_up = false
          @cc_position = nil
          @lock = Mutex.new
          @node_type_name = 'Knob'
          @self_reader = nil
          @decisions = {} # timeline position => value decided there (see ValueAt)
          @stepped = nil # read through #choose (see #stepped?)
          @implicit = false
          @build_value = nil
        end

        # True for a knob a live graph read before it was defined
        # (Session::Knobs#knob: 0.5 of 0..1 until `knob :x, ...` defines it).
        attr_accessor :implicit

        # Changes the Spec (keeping the value and anything in progress),
        # e.g. when a knob is defined again.  +options+ as for Spec.
        def respec(**options)
          @spec = @spec.respec(**options)
          # (ramps in progress move in the new scale)
          [@segment, *@pending].each { |seg| seg.terms = nil if seg.is_a?(Ramp) }
          @cc = @spec.cc if options.key?(:cc)
          self
        end

        def name
          @spec.name
        end

        # Baseline plus modulation (racks R2, proposal 2.6): a node whose
        # value is this knob's moved by +source+ (a node, usually -1..1, such
        # as an LFO) times +depth+ in fractions of the knob's range, in the
        # knob's own scale (octaves for +curve: :exp+ knobs), limited to the
        # range.  Turning the knob moves the center of the modulation
        # instead of fighting it.
        #
        #     cut = knob(:cut, (100.hz..8000.hz).at(800.hz))
        #     sig.lp4(cut.mod(0.2.hz.lfo, depth: 0.2))   # +-20% of the range around the knob
        def mod(source, depth: 0.25)
          raise ArgumentError, "mod needs a graph node to modulate by (got #{source.inspect})" unless source.respond_to?(:sample)
          raise ArgumentError, "depth: must be a number (got #{depth.inspect})" unless depth.is_a?(Numeric) && depth.real?

          Recipe.call(self, :mod, [source], { depth: depth }, nil) { |_|
            moved = @spec.scale.shift(get_sampler, source, depth)
            @spec.clamp? ? moved.aclip(range.begin, range.end) : moved
          }
        end

        # Joins +session+ (Session::Knobs#adopt_knobs): a standalone knob,
        # e.g. one from a graph document loaded outside the Session, counts
        # the Session's frames from +frame+ on, keeping its value and any
        # move in progress (shifted to the Session's frame count).  Raises
        # if the knob already belongs to a Session.
        def attach(session, frame:, sample_rate: @sample_rate)
          @lock.synchronize {
            raise ArgumentError, "Knob #{name.inspect} already belongs to a Session" if @session
            offset = frame - @next_frame
            @segment.start += offset
            @pending.each { |s| s.start += offset }
            @next_frame = frame
            @span_frame = nil
            @span_count = 0
            @span_out = nil
            @session = session
            @sample_rate = sample_rate.to_f
          }
          self
        end

        # Reads +knob+ instead where this knob is read directly (#sample),
        # after its readers were rebound to it (see Reader#rebind).
        def redirect(knob)
          @joined = knob
          (@self_reader ||= Reader.new(self)).rebind(knob)
          self
        end

        def range
          @spec.range
        end

        # A new Reader for one consumer (see the class description), so a
        # knob used by several nodes never needs a Tee.
        def get_sampler
          Reader.new(self)
        end

        # Reads the knob directly (as one consumer).
        def sample(count)
          (@self_reader ||= Reader.new(self)).sample(count)
        end

        # Port type of the output (see GraphNode::Traversable#port_type).
        def port_type
          :control
        end

        def sources
          {}
        end

        def to_s
          "Knob #{name.inspect} (#{value_string})"
        end

        def inspect
          "#<Knob #{name.inspect} #{value_string}#{state_suffix}>"
        end

        def pretty_print(q)
          q.text(inspect)
        end

        # The value with its unit, e.g. "800 Hz".
        def value_string
          "#{Knob.number(MB::M.sigfigs(@value, 4))}#{@spec.unit ? " #{@spec.unit}" : ''}"
        end

        # MIDI controllers this knob listens to (see MIDI::ControlMap): its
        # ControlSpec if it has a controller.
        def control_specs
          s = @spec.to_control_spec(@cc)
          s ? [s] : []
        end

        # Plan layer, for a knob read directly (see Reader).
        include Plan::Describable

        def plan_describe(p)
          p.param(self, complex: false)
        end

        def plan_inputs
          []
        end

        def plan_param(count)
          (@self_reader ||= Reader.new(self)).plan_param(count)
        end

        def plan_complex?
          false
        end

        def plan_snapshot
          @self_reader&.plan_snapshot
        end

        def plan_restore(snapshot)
          @self_reader&.plan_restore(snapshot)
        end

        # The first frame the knob's Session is rendering for the player
        # being rendered (a player starting or waking partway through a
        # buffer starts there), or nil when no Session is rendering it
        # (readers then count frames themselves).
        def clock_frame
          @session&.knob_frame
        end

        # What the knob is doing: :hold, :ramp, or :follow.
        def mode
          case @segment
          when Ramp then :ramp
          when Follow then :follow
          else :hold
          end
        end

        # Where the knob is heading: the held value or the ramp's target
        # (nil while it follows a node).  Changes landing later aren't
        # counted.
        def target
          s = @segment
          s.is_a?(Follow) ? nil : s.is_a?(Ramp) ? s.to : s.value
        end

        # Where the knob ends up after the changes queued so far: [:follow,
        # source node] or [:hold, value] (a ramp counts as its target), from
        # the last queued hold, ramp, or follow, else the current segment
        # (set documents save send levels set but not yet rendered).
        def queued_state
          @lock.synchronize {
            seg = @pending.reverse_each.find { |s| s.is_a?(Hold) || s.is_a?(Ramp) || s.is_a?(Follow) } || @segment
            case seg
            when Follow then [:follow, seg.source]
            when Ramp then [:hold, seg.to]
            else [:hold, seg.value]
            end
          }
        end

        # The source node while following one (else nil).
        def following
          @segment.is_a?(Follow) ? @segment.source : nil
        end

        # True while the knob ramps, follows a node, or has changes queued
        # (graph-io can't save moves yet, only values).
        def moving?
          @lock.synchronize { !@segment.is_a?(Hold) || !@pending.empty? }
        end

        # The knob's state for undo (see Session::Knobs): [:hold, value] (a
        # ramp in progress counts as its target) or [:follow, Follow], with
        # the changes landing up to frame +frame+ (those already added for
        # that frame count; later ones don't).
        def state_at(frame)
          @lock.synchronize {
            s = ([@segment] + @pending).select { |x| !x.is_a?(Move) && x.start <= frame }.last || @segment
            case s
            when Follow then [:follow, s]
            when Ramp then [:hold, s.to]
            else [:hold, s.value]
            end
          }
        end

        # Jumps to +value+ on frame +frame+ (gliding over the Spec's +smooth+
        # seconds unless +smooth+ is given; 0 for an exact jump).  The value
        # is limited to the range.  Returns self.
        def set(value, frame:, smooth: nil)
          smooth = @spec.smooth if smooth.nil?
          frames = (smooth.to_f * @sample_rate).round
          return ramp_to(value, frames: frames, frame: frame) if frames > 1

          add_segment(Hold.new(frame, @spec.clamp(value)))
        end

        # Ramps to +value+ over +frames+ frames starting on frame +frame+,
        # shaped by +curve+ (an MB::Sound::Curve, a curve name like :smooth,
        # or nil for straight in the knob's scale), from where the knob is
        # (or from +from+: a jump there first).  Returns self.
        def ramp_to(value, frames:, frame:, curve: nil, from: nil)
          frames = frames.round
          return add_segment(Hold.new(frame, @spec.clamp(value))) if frames <= 1

          curve = MB::Sound::Curve[curve] unless curve.nil? || curve.is_a?(MB::Sound::Curve)
          curve = nil if curve.respond_to?(:name) && curve.name == :linear
          add_segment(Ramp.new(frame, frames, @spec.clamp(value), curve, from && @spec.clamp(from)))
        end

        # Follows +node+ (any GraphNode; its output in the knob's units,
        # limited to the range, or through +map+, a Proc given each buffer
        # as a Numo::DFloat) from frame +frame+ until the next change.
        # With +transport+ (a Session's), nodes in its graph that follow
        # the timeline (a tween's clip, tempo-synced LFOs) start counting
        # from the follow's first frame, as if launched there (automation
        # started by a turn plays from its beginning).  +time+ is the
        # landing position (for listings).  Returns self.
        def follow(node, frame:, map: nil, time: nil, transport: nil, label: nil)
          raise ArgumentError, "A knob follows a graph node (got #{node.inspect})" unless node.respond_to?(:sample) && node.respond_to?(:get_sampler)
          raise ArgumentError, "Knob #{name.inspect} can't follow itself" if node.equal?(self) || (node.is_a?(Reader) && node.knob.equal?(self))

          source = node.get_sampler
          nodes = [node, *(node.respond_to?(:graph) ? node.graph : [])].grep(Sequence::TimelineNode).uniq
          if transport
            nodes.each { |n| n.start_at(0r, origin: 0r, launch: 0r, transport: transport) }
          end
          add_segment(Follow.new(frame, source, map, nodes, label || Knob.label_of(node), time))
        end

        # Follows again what +state+ (a Follow from #state_at) followed,
        # from frame +frame+ (for undo; the source carries on from where it
        # was).  Returns self.
        def refollow(state, frame:)
          seg = state.dup
          seg.start = frame
          add_segment(seg)
        end

        # Listens to controller changes on +stream+ (a MIDI::Stream, e.g.
        # MB::Sound.midi_stream, or anything Stream.for takes) for the
        # knob's +cc+ (or the next controller moved, with #learn).
        # Controller values move the knob in its own scale (see Spec#value);
        # with +takeover: :pickup+ (the default) only once the controller
        # has passed the knob's position.  Pass nil to stop listening.
        # Returns self.
        #
        # A Session's MIDI input (Session::MidiInput) may be given instead
        # of a stream: the knob then reads each span's events on the frames
        # where the Session put them (the Session reads its inputs before
        # advancing knobs), so takes replay controller moves exactly.
        def listen(stream)
          @lock.synchronize {
            @midi.close if @midi.respond_to?(:close)
            @midi = stream.is_a?(Session::MidiInput) ? stream : (stream && MIDI::Stream.for(stream).reader)
            @picked_up = false
            @cc_position = nil
          }
          self
        end

        # The MIDI::Stream reader (or Session::MidiInput) this knob listens
        # to, or nil.
        def listening
          @midi
        end

        # Waits for the next controller moved on the stream given to
        # #listen (which must be set) and controls the knob with it from
        # then on (see #listen).  +from_frame+ ignores controllers moved
        # before that session frame (a learn landing partway through a
        # buffer).  Returns self.
        def learn(from_frame: nil)
          raise ArgumentError, "Knob #{name.inspect} isn't listening to MIDI (see #listen)" if @midi.nil?
          @lock.synchronize { @learning = true; @learn_from = from_frame; @picked_up = false; @cc_position = nil }
          self
        end

        # True while waiting for a controller to learn.
        def learning?
          !!@learning
        end

        # Sets the controller number (nil to forget it).  Returns self.
        def cc=(number)
          raise ArgumentError, "cc must be 0..127 (got #{number.inspect})" unless number.nil? || (number.is_a?(Integer) && number.between?(0, 127))
          @lock.synchronize { @cc = number; @learning = false; @picked_up = false; @cc_position = nil }
        end

        # True once a :pickup controller has caught the knob (reset when
        # something else moves it).
        def picked_up?
          @picked_up
        end

        # The values for frames [+frame+, +frame+ + +count+): a Float while
        # the knob holds that value over the whole block, else a frozen
        # Numo::SFloat.  Each block is computed once (a Session renders it
        # first; readers asking again get the same values), so this never
        # moves the knob back.  A block that starts after the last one
        # renders the frames in between first; one that starts before it
        # (a reader that fell behind) gets the current value.
        def read(frame, count)
          # (the body outside the block: a return from inside the block made
          # an imemo each read, ~4000 a second in tunnel_vision; dropouts-2)
          @lock.synchronize { read_locked(frame, count) }
        end

        # #read with the lock held.
        def read_locked(frame, count)
          begin
            if @span_frame == frame && count <= @span_count
              out = @span_out
              return out if count == @span_count || !out.is_a?(Numo::NArray)
              return out[0...count].dup.freeze
            end

            # Part of the span from a later frame (a player starting or
            # waking partway through the buffer, or a graph read in pieces)
            if @span_frame && frame > @span_frame && frame + count <= @span_frame + @span_count
              out = @span_out
              return out unless out.is_a?(Numo::NArray)
              o = frame - @span_frame
              return out[o...(o + count)].dup.freeze
            end

            if frame >= @next_frame
              skip_to(frame) if frame > @next_frame
              out = render(frame, count)
              @span_frame = frame
              @span_count = count
              @span_out = out
              return out
            end

            @value
          end
        end

        # A frozen buffer of +count+ samples of +value+, reused while both
        # stay the same.
        def steady_buffer(count, value)
          buf = @steady
          return buf if buf && buf.length == count && @steady_value.eql?(value)
          @steady_value = value
          @steady = Numo::SFloat.new(count).fill(value).freeze
        end

        # +v+ as Ruby for listings: whole numbers without ".0", others with
        # up to 6 significant figures.
        def self.number(v)
          v = v.to_f
          v == v.round && v.abs < 1e15 ? v.round.to_s : MB::M.sigfigs(v, 6).to_s
        end

        # A short description of a node a knob follows.
        def self.label_of(node)
          node.is_a?(Reader) || node.is_a?(Knob) ? "knob(#{(node.is_a?(Reader) ? node.knob : node).name.inspect})" : node.to_s.lines.first.to_s.strip[0, 40]
        end

        private

        def state_suffix
          case @segment
          when Ramp then " -> #{MB::M.sigfigs(@segment.to, 4)}"
          when Follow then " following #{@segment.label}"
          else ''
          end
        end

        # Adds a segment (replacing any other change landing on the same
        # frame; a :pickup controller must catch the knob again).  A segment
        # for a frame already rendered lands on the next frame.
        def add_segment(seg)
          @lock.synchronize {
            seg.start = @next_frame if seg.start < @next_frame
            @pending.reject! { |s| s.start == seg.start && !s.is_a?(Move) }
            idx = @pending.bsearch_index { |s| s.start > seg.start } || @pending.length
            @pending.insert(idx, seg)
            @picked_up = false unless seg.is_a?(Move)
          }
          self
        end

        # Renders and discards frames up to +frame+ (a reader that skipped
        # ahead, outside a Session).
        def skip_to(frame)
          while @next_frame < frame
            render(@next_frame, MB::M.min(frame - @next_frame, 48000))
          end
        end

        # Computes frames [+frame+, +frame+ + +count+) (frame must be
        # @next_frame): a Float if one held value covers them, else a frozen
        # SFloat.
        def render(frame, count)
          read_midi(frame, count) if @midi

          out = nil
          pos = 0
          while pos < count
            f = frame + pos
            begin_segment(@pending.shift) while @pending.first && @pending.first.start <= f

            stop = count
            nxt = @pending.first
            stop = MB::M.min(stop, nxt.start - frame) if nxt

            seg = @segment
            if seg.is_a?(Hold) && pos == 0 && stop == count
              @next_frame = frame + count
              return seg.value
            end

            out ||= render_buffer(count)
            n = stop - pos
            case seg
            when Hold
              out[pos...stop] = seg.value unless MB::Sound::Kernels.fill_range(out, pos, stop, seg.value)
              @value = seg.value
            when Ramp
              out[pos...stop] = ramp_values(seg, f, n) unless ramp_into(out, pos, seg, f, n)
              if f + n >= seg.start + seg.length
                # Done: hold the target from here on
                @value = seg.to
                @segment = Hold.new(seg.start + seg.length, seg.to)
              else
                @value = out[stop - 1]
              end
            when Follow
              v = follow_values(seg, n)
              out[pos...stop] = v unless v.is_a?(Numo::SFloat) && MB::Sound::Kernels.copy_range(out, pos, v, 0, n)
              @value = out[stop - 1]
            end

            pos = stop
          end

          @next_frame = frame + count
          @render_views.of(out)
        end

        # One of two reused SFloats of +count+ samples for #render, which
        # writes every sample (in turn, so the last span's view stays
        # valid while the next is made; its readers see a frozen view with
        # a new generation each span: GraphNode::FrozenView).
        def render_buffer(count)
          @render_flip ^= 1
          buf = @render_bufs[@render_flip]
          buf = @render_bufs[@render_flip] = Numo::SFloat.zeros(count) if buf.nil? || buf.length != count
          buf
        end

        # Starts +seg+ (from the pending list) on its frame.
        def begin_segment(seg)
          if seg.is_a?(Move)
            seg = move_segment(seg)
            return if seg.nil?
          end

          seg.from ||= @value if seg.is_a?(Ramp)
          @value = seg.value if seg.is_a?(Hold)
          @segment = seg
        end

        # A ramp's values for +n+ frames from frame +f+: the value on frame
        # start + j is from + (to - from) * curve((j + 1) / length), in the
        # knob's scale, and exactly +to+ from the last frame on.
        def ramp_values(seg, f, n)
          j0 = f - seg.start
          t = @ramp_t
          t = @ramp_t = Numo::DFloat.new(n) if t.nil? || t.length != n
          t.seq(j0 + 1)
          t.inplace / seg.length
          ends = j0 + n >= seg.length
          t.inplace.clip(0.0, 1.0) if ends
          # (in place but on the last frames, which read t again below)
          c = seg.curve ? (ends ? seg.curve.map(t) : seg.curve.map!(t, ramp_scratch(n))) : t
          k, a, b = ramp_terms(seg)
          c = c.dup if c.equal?(t) && ends
          c.inplace * k
          if @spec.curve == :exp
            c.inplace + a + b
            v = Numo::NMath.exp(c.inplace)
          else
            v = c.inplace + a
          end
          if ends
            done = t.ge(1.0)
            v[done] = seg.to
          end
          v
        end

        # #ramp_values written into out[pos, n] in C (Kernels.knob_ramp:
        # the same values) for ramps without a curve or with a linear or
        # smoothstep one; false for others.
        def ramp_into(out, pos, seg, f, n)
          cv = seg.curve
          kind = cv.nil? || cv.equal?(MB::Sound::Curve.linear) ? 0 : (cv.equal?(MB::Sound::Curve.smoothstep) ? 1 : nil)
          return false unless kind

          k, a, b = ramp_terms(seg)
          !!MB::Sound::Kernels.knob_ramp(out, pos, n, f - seg.start, seg.length, kind, @spec.curve == :exp, k, a, b, seg.to)
        end

        # Ramp +seg+'s Param::Scale#ramp_terms (computed once per ramp).
        def ramp_terms(seg)
          seg.terms ||= @spec.scale.ramp_terms(seg.from, seg.to).freeze
        end

        # A reused DFloat of +n+ samples for Curve#map! in #ramp_values.
        def ramp_scratch(n)
          sc = @ramp_scratch
          sc = @ramp_scratch = Numo::DFloat.zeros(n) if sc.nil? || sc.length != n
          sc
        end

        # +n+ frames of the followed node (holding its last value once it
        # ends), limited to the range or through the Follow's map.
        def follow_values(seg, n)
          buf = seg.source.sample(n)
          if buf.nil? || buf.empty?
            @segment = Hold.new(@next_frame, @value)
            return @value
          end

          buf = buf[0...n] if buf.length > n
          if buf.length < n
            last = buf[-1]
            buf = buf.concatenate(buf.class.new(n - buf.length).fill(last))
          end
          return seg.map.call(Numo::DFloat.cast(buf)) if seg.map
          return buf unless @spec.clamp?

          # (inside the range already, as a followed knob or LFO usually
          # is: clip would change nothing; found without allocating)
          lo = @spec.range.begin
          hi = @spec.range.end
          r = (@follow_range ||= [0.0, 0.0])
          return buf if MB::Sound::Kernels.min_max(buf, r) && r[0] >= lo && r[1] <= hi

          # (clipped in a reused copy of the same type: the same values as
          # buf.clip)
          c = @follow_buf
          c = @follow_buf = buf.class.new(n) if c.nil? || c.class != buf.class || c.length != n
          c[0..] = buf unless MB::Sound::Kernels.copy(c, buf)
          c.inplace.clip(lo, hi)
          c
        end

        # Reads controller events for frames [+frame+, +frame+ + +count+)
        # and queues them as Moves.
        def read_midi(frame, count)
          midi_events(frame, count).each do |off, e|
            next unless e.type == :cc

            if @learning && (@learn_from.nil? || frame + off >= @learn_from)
              @cc = e.note
              @learning = false
              @picked_up = false
              @cc_position = nil
            end
            next unless e.note == @cc && !@learning

            mv = Move.new(frame + off, e.value.to_f, e.note)
            idx = @pending.bsearch_index { |s| s.start > mv.start } || @pending.length
            @pending.insert(idx, mv)
          end
        end

        # [frame offset, MIDI::Event] pairs of the events for frames
        # [+frame+, +frame+ + +count+): from a Session::MidiInput's span on
        # its frames, or read from a stream reader.
        def midi_events(frame, count)
          if @midi.is_a?(Session::MidiInput)
            span = @midi.span
            return [] if span.nil?
            return span.events.filter_map { |st|
              [st.frame - frame, st.event] if st.frame >= frame && st.frame < frame + count
            }
          end

          from = @midi.cursor
          @midi.next(count.to_r / @sample_rate.to_r).map { |e|
            [((e.time - from) * @sample_rate.to_r).floor.clamp(0, count - 1), e]
          }
        end

        # The segment a controller move starts (nil if a :pickup controller
        # hasn't caught the knob yet).
        def move_segment(mv)
          prev = @cc_position
          @cc_position = mv.position

          unless @picked_up || @spec.takeover == :jump
            here = @spec.position(@value)
            crossed = prev && ((prev - here) * (mv.position - here) <= 0)
            return nil unless crossed || (mv.position - here).abs <= 0.5 / 127
            @picked_up = true
          end
          @picked_up = true

          value = @spec.value(mv.position.clamp(0.0, 1.0))
          frames = (@spec.smooth * @sample_rate).round
          if frames > 1
            Ramp.new(mv.start, frames, @spec.clamp(value), nil, nil)
          else
            Hold.new(mv.start, @spec.clamp(value))
          end
        end
      end
    end
  end
end
