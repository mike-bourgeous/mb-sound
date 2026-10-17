module MB
  module Sound
    module GraphNode
      # A named value that a performer turns (contract K6 in
      # design/notes/arrangement.md): `knob :cut, 800, range: 100..8000,
      # curve: :exp` in the console, then `knob(:cut)` wherever a graph
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
      #     play 110.hz.ramp.lp4(cut)
      #     cut.ramp_to(3000, frames: 96000, frame: cut.next_frame)   # (Session#turn does this)
      class Knob
        include GraphNode

        # How a knob's value relates to a 0..1 position (its scale for
        # ramps, MIDI controllers, and snapshot crossfades).
        CURVES = { linear: :linear, lin: :linear, exp: :exp, exponential: :exp, log: :exp }.freeze

        # How a MIDI controller takes over: :pickup waits until the
        # controller passes the knob's position (no jumps), :jump moves the
        # knob right away.
        TAKEOVERS = [:pickup, :jump].freeze

        # The knob's description, shaped like MIDI::ControlSpec (contract
        # K6): +name+ (a Symbol), +default+ (the starting value), +range+
        # (a Range of Floats), +curve+ (:linear or :exp), +unit+ (a String
        # for display, or nil), +cc+ (a MIDI controller number, or nil),
        # +takeover+ (:pickup or :jump), and +smooth+ (seconds over which a
        # turn without +over:+ glides, a declick; 0 for exact jumps).
        class Spec < Data.define(:name, :default, :range, :curve, :unit, :cc, :takeover, :smooth)
          def initialize(name:, default: nil, range: 0.0..1.0, curve: :linear, unit: nil, cc: nil, takeover: :pickup, smooth: Session::Fades::DECLICK_SECONDS)
            raise ArgumentError, "Knob names must be Symbols (got #{name.inspect})" unless name.is_a?(Symbol)
            raise ArgumentError, "Range must be a Range of numbers (got #{range.inspect})" unless range.is_a?(Range) && range.begin.is_a?(Numeric) && range.end.is_a?(Numeric)
            lo = range.begin.to_f
            hi = range.end.to_f
            raise ArgumentError, "Range must go up (got #{range.inspect})" unless hi > lo
            c = CURVES[curve] or raise ArgumentError, "Unknown knob curve #{curve.inspect} (#{CURVES.keys.map(&:inspect).join(', ')})"
            raise ArgumentError, "An exponential knob's range can't include 0 (got #{range.inspect})" if c == :exp && lo * hi <= 0
            raise ArgumentError, "Takeover must be #{TAKEOVERS.map(&:inspect).join(' or ')} (got #{takeover.inspect})" unless TAKEOVERS.include?(takeover)
            raise ArgumentError, "cc: must be 0..127 (got #{cc.inspect})" unless cc.nil? || (cc.is_a?(Integer) && cc.between?(0, 127))

            default = lo if default.nil?
            raise ArgumentError, "Default must be a number (got #{default.inspect})" unless default.is_a?(Numeric) && default.real?
            default = default.to_f.clamp(lo, hi)
            smooth = MB::Sound::Length.seconds(smooth).to_f
            raise ArgumentError, "smooth: must be 0 or more seconds (got #{smooth})" unless smooth >= 0

            super(name: name, default: default, range: (lo..hi).freeze, curve: c, unit: unit&.to_s&.freeze, cc: cc, takeover: takeover, smooth: smooth)
          end

          # The 0..1 position of +value+ in the range (beyond 0..1 outside
          # it).
          def position(value)
            lo = range.begin
            hi = range.end
            curve == :exp ? Math.log(value.to_f / lo) / Math.log(hi / lo) : (value.to_f - lo) / (hi - lo)
          end

          # The value at position +pos+ (a Float or a Numo::DFloat).
          def value(pos)
            lo = range.begin
            hi = range.end
            if curve == :exp
              pos.is_a?(Numo::NArray) ? Numo::NMath.exp(pos * Math.log(hi / lo)) * lo : lo * Math.exp(pos * Math.log(hi / lo))
            else
              pos * (hi - lo) + lo
            end
          end

          # +value+ limited to the range.
          def clamp(value)
            value.to_f.clamp(range.begin, range.end)
          end

          # A MIDI::ControlSpec for this knob's controller (for
          # MIDI::ControlMap and ACID XML), or nil without a +cc+.
          def to_control_spec
            return nil if cc.nil?
            raw = (position(default) * 127).round.clamp(0, 127)
            MIDI::ControlSpec.new(
              number: cc, name: name.to_s, range: range, default: raw, curve: curve == :exp ? :exponential : :linear,
              description: "Knob #{name.inspect}#{unit ? " (#{unit})" : ''}"
            )
          end

          # The console line that defines this knob.
          def to_ruby
            parts = [name.inspect, Knob.number(default)]
            parts << "range: #{Knob.number(range.begin)}..#{Knob.number(range.end)}" unless range == (0.0..1.0)
            parts << "curve: #{curve.inspect}" unless curve == :linear
            parts << "unit: #{unit.inspect}" if unit
            parts << "cc: #{cc}" if cc
            parts << "takeover: #{takeover.inspect}" unless takeover == :pickup
            parts << "smooth: #{Knob.number(smooth)}" unless smooth == Session::Fades::DECLICK_SECONDS
            "knob #{parts.join(', ')}"
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
        Ramp = Struct.new(:start, :length, :to, :curve, :from)

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

        # Creates a knob named +name+ starting at +default+ (see Spec for
        # the options).  +session+ is the Session that advances it (see
        # Session::Knobs; Session#knob makes knobs), and +frame+ the first
        # frame it renders (the Session's frame counter).
        def initialize(name, default = nil, session: nil, sample_rate: 48000, frame: 0, **spec)
          @spec = Spec.new(name: name, default: default, **spec)
          @session = session
          @sample_rate = sample_rate.to_f
          @value = @spec.default
          @segment = Hold.new(frame, @value)
          @pending = []
          @next_frame = frame
          @span_frame = nil
          @span_count = 0
          @span_out = nil
          @steady = nil
          @cc = @spec.cc
          @midi = nil
          @learning = nil
          @picked_up = false
          @cc_position = nil
          @lock = Mutex.new
          @node_type_name = 'Knob'
          @self_reader = nil
        end

        # Changes the Spec (keeping the value and anything in progress),
        # e.g. when a knob is defined again.  +options+ as for Spec.
        def respec(**options)
          @spec = Spec.new(**@spec.to_h.merge(options))
          @cc = @spec.cc if options.key?(:cc)
          self
        end

        def name
          @spec.name
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
          s = (@cc == @spec.cc ? @spec : @spec.with(cc: @cc)).to_control_spec
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
          @lock.synchronize {
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
          }
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

            out ||= Numo::SFloat.zeros(count)
            n = stop - pos
            case seg
            when Hold
              out[pos...stop] = seg.value
              @value = seg.value
            when Ramp
              out[pos...stop] = ramp_values(seg, f, n)
              if f + n >= seg.start + seg.length
                # Done: hold the target from here on
                @value = seg.to
                @segment = Hold.new(seg.start + seg.length, seg.to)
              else
                @value = out[stop - 1]
              end
            when Follow
              out[pos...stop] = follow_values(seg, n)
              @value = out[stop - 1]
            end

            pos = stop
          end

          @next_frame = frame + count
          out.freeze
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
          t = Numo::DFloat.new(n).seq(j0 + 1)
          t.inplace / seg.length
          ends = j0 + n >= seg.length
          t.inplace.clip(0.0, 1.0) if ends
          c = seg.curve ? seg.curve.map(t) : t
          if @spec.curve == :exp
            p0 = @spec.position(seg.from)
            p1 = @spec.position(seg.to)
            c = c.dup if c.equal?(t) && ends
            c.inplace * (Math.log(@spec.range.end / @spec.range.begin) * (p1 - p0))
            c.inplace + Math.log(@spec.range.begin) + p0 * Math.log(@spec.range.end / @spec.range.begin)
            v = Numo::NMath.exp(c.inplace)
          else
            c = c.dup if c.equal?(t) && ends
            c.inplace * (seg.to - seg.from)
            v = c.inplace + seg.from
          end
          if ends
            done = t.ge(1.0)
            v[done] = seg.to
          end
          v
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
          buf.clip(@spec.range.begin, @spec.range.end)
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
