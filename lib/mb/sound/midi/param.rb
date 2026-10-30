module MB
  module Sound
    module MIDI
      # Parameters that move (midi-consol-2; design/notes/midi.md,
      # "Parameters that move"): MIDI transforms work in event time, so a
      # moving parameter answers "what is your value at this moment?"
      # (#value_at) at each decision point rather than being sampled per
      # buffer: at the played note-on for humanize, quantize, swing, chance,
      # and transpose, at each step for arp and ratchet, and at each cycle or
      # bar start for every and generators.
      #
      # The protocol is one method, shared by every value that moves
      # (MB::Sound::ValueSource: knobs, clock speeds, followed tempos):
      #
      #     value_at(pos, frame: nil, transport: nil, stream: nil)
      #
      # +pos+ is a timeline position (Rational whole notes), +frame+ the
      # Session frame when the reader knows it (knobs read there), +transport+
      # the transform's Sequence::Transport, and +stream+ the transform's
      # Param::Reading (what it has seen on its input, for #cc).  Plain
      # values (numbers, Durations, Intervals, Lengths, Symbols, Scales)
      # answer themselves through ValueSource.value_at, which allocates
      # nothing for them.
      #
      # Params:
      # - `cc(1, 0.3..0.95, curve: :linear)` (Param::CC): the last value of
      #   controller 1 on the transform's own input stream, else on the
      #   Session's MIDI input, else its default.
      # - Session knobs, `knob(:swing)` (GraphNode::Knob#value_at), also in
      #   graph arithmetic with numbers and tempo LFOs.
      # - Tempo LFOs, `2.bars.lfo.at(0.5..0.66)`: a pure function of the
      #   timeline position (Param::Graph).
      # - Clips, `seq(0, -4, 3, -2).n1.loop`: the value of the note sounding
      #   at the position (Sequence::Clip#value_at; transpose by a
      #   sequence).
      # - Arithmetic: params combine with numbers and each other (`0.5 +
      #   cc(1) * 0.2`, Param::Expr) and print back as the Ruby that made
      #   them (graph documents and recipes).
      #
      # Not params: per-sample audio nodes (a transform has no sample
      # clock); have a knob follow the node instead (`turn :x, follow:
      # node`).
      module Param
        # Raised for values that can't be read as params.
        class NotAParam < ArgumentError; end

        # Runs the block with param reads as peeks (G3, Generative::Steer
        # speculating on the next cycle): knobs answer what they know
        # without deciding (no decision remembered or logged for takes) and
        # choices keep their hysteresis state, so a peek never changes what
        # a later read answers.  Returns the block's value.
        def self.peek
          prev = Thread.current[:mb_param_peek]
          Thread.current[:mb_param_peek] = true
          yield
        ensure
          Thread.current[:mb_param_peek] = prev
        end

        # True inside Param.peek on this thread.
        def self.peeking?
          Thread.current[:mb_param_peek] ? true : false
        end

        # True if +x+ moves (a param, or something #wrap makes one of).
        def self.param?(x)
          x.is_a?(Base) || x.is_a?(Sequence::Clip) || x.is_a?(GraphNode::Knob::Reader) ||
            (x.is_a?(GraphNode) && !x.is_a?(GraphNode::Constant) && !x.is_a?(Pitch)) # (Pitches and Notes are values)
        end

        # Returns +x+ ready for #value_at: params as they are, clips and
        # graph nodes (knobs, tempo LFOs, constants, and arithmetic on them)
        # checked and wrapped, plain values as they are.  +what+ names the
        # option in errors.
        def self.wrap(x, what = 'This option')
          case x
          when Base then x
          when Sequence::Clip then ClipValue.new(x)
          when GraphNode::Constant then x.constant
          when GraphNode, GraphNode::Knob::Reader then Graph.new(x, what)
          else x
          end
        end

        # +x+ for transform names (#to_s): params and plain values as Ruby,
        # graph nodes as the expression that built them.
        def self.label(x)
          return x.to_s unless x.is_a?(GraphNode) || x.is_a?(GraphNode::Knob::Reader) || x.is_a?(Graph)
          node = x.is_a?(Graph) ? x.node : x
          text = (node.to_ruby rescue nil)
          text && !text.include?("\n") ? text : node.to_s
        end

        # The largest value +x+ may take, as far as it says (a controller's
        # or knob's range), else +fallback+: for tails (how long a
        # transform may delay notes).
        def self.largest(x, fallback)
          case x
          when CC then [x.spec.range.begin.abs, x.spec.range.end.abs].max
          when Graph
            n = ValueSource.knob_of(Graph.unwrap(x.node))
            n ? [n.range.begin.abs, n.range.end.abs].max : fallback
          when Numeric then x
          else fallback
          end
        end

        # The Session whose MIDI input a #cc falls back to: the one
        # rendering on this thread, else the current one (without creating
        # one).
        def self.session
          Session.span&.session || Session.existing
        end

        # The raw value (0..127) of controller +number+ (on any channel, or
        # 0-based +channel+) on the Session's default MIDI input at or before
        # timeline position +pos+, or nil if it hasn't moved.
        def self.session_cc(number, pos, channel: nil)
          s = session or return nil
          input = s.midi_inputs[nil] or return nil
          input.cc_at(number, pos, channel: channel)
        end

        # What a transform has seen on its input stream, for params that
        # listen to it (#cc): the latest raw value of every controller.
        # Transforms feed it every non-note event in time order before
        # deciding.
        class Reading
          def initialize
            @cc = {}
          end

          # Notes event +e+ (controllers only).
          def observe(e)
            @cc[[e.channel, e.note]] = @cc[[nil, e.note]] = e.raw if e.type == :cc
            self
          end

          # The latest raw value of controller +number+ (on 0-based
          # +channel+, or any), or nil if none was seen.
          def cc(number, channel: nil)
            @cc[[channel, number]]
          end
        end

        # Common behavior of params: arithmetic (Param::Expr), coercion of
        # numbers on the left, and printing back as Ruby through a recipe
        # (Generative::Value's, shared with probability scales).
        class Base
          include Generative::Value

          # The value at timeline position +pos+ (see Param).
          def value_at(pos, frame: nil, transport: nil, stream: nil)
            raise NotImplementedError, "#{self.class} must implement #value_at"
          end

          # MIDI controllers this param reads (see MIDI::ControlMap).
          def control_specs
            []
          end

          # The graph nodes this param reads (knobs, tempo LFOs), so graph
          # traversals (documents' knob headers, Sessions adopting knobs)
          # find them through the transforms that hold the param.
          def nodes
            []
          end

          [:+, :-, :*, :/, :**].each do |op|
            define_method(op) do |other|
              raise NotAParam, "#{self} #{op} #{other.inspect}: params combine with numbers and other params" unless other.is_a?(Numeric) || Param.param?(other)
              Expr.new(op, self, other)
            end
          end

          # Numbers on the left (`0.5 + cc(1)`).
          def coerce(other)
            raise TypeError, "#{other.inspect} can't combine with a param" unless other.is_a?(Numeric)
            [Const.new(other), self]
          end

          def to_s
            to_ruby
          end

          def inspect
            "#<Param #{self}>"
          end

          # Ruby for this param (see Generative::Value#to_ruby); without a
          # block, graph nodes in it (knobs, LFOs) print as the expressions
          # that built them.
          def to_ruby(&value_text)
            return super if value_text
            super() { |v| v.is_a?(GraphNode) || v.is_a?(GraphNode::Knob::Reader) ? Param.label(v) : RubyValue.to_ruby(v, gains: true) }
          end

          # Params print without a recipe as their class name.
          def plain_ruby(_value_text)
            self.class.name.split('::').last
          end
        end

        # A number on the left of param arithmetic (see Base#coerce).
        class Const < Base
          attr_reader :value

          def initialize(value)
            @value = value
            freeze
          end

          def value_at(_pos, frame: nil, transport: nil, stream: nil)
            @value
          end

          def plain_ruby(value_text)
            value_text.call(@value)
          end
        end

        # Arithmetic on params: +a+ +op+ +b+ evaluated at each position.
        class Expr < Base
          attr_reader :op, :a, :b

          def initialize(op, a, b)
            @op = op
            @a = Param.wrap(a, 'An operand')
            @b = Param.wrap(b, 'An operand')
            with_recipe(a.is_a?(Const) ? a.value : a, op, [b])
          end

          def value_at(pos, frame: nil, transport: nil, stream: nil)
            x = ValueSource.value_at(@a, pos, frame: frame, transport: transport, stream: stream)
            y = ValueSource.value_at(@b, pos, frame: frame, transport: transport, stream: stream)
            x = x.to_f if x.is_a?(Rational) && y.is_a?(Float)
            x.public_send(@op, y)
          end

          def control_specs
            [@a, @b].flat_map { |x| x.respond_to?(:control_specs) ? x.control_specs : [] }
          end

          def nodes
            [@a, @b].flat_map { |x| x.is_a?(Base) ? x.nodes : [] }
          end
        end

        # A MIDI controller as a param (MidiMethods#cc): the last value of
        # controller +number+ seen on the transform's own input stream (a
        # live keyboard's knobs move its own transforms), else on the
        # Session's default MIDI input (a clip's transforms steered from a
        # controller), else +default+ (a raw value, 0 by default), mapped
        # onto +range+ with +curve+ (:linear, :exp, or :switch; see
        # ControlSpec#value).  +channel+ (0-based) listens to one channel
        # only.
        class CC < Base
          attr_reader :spec, :channel

          def initialize(number, range = 0.0..1.0, curve: :linear, default: nil, channel: nil, name: nil)
            raise ArgumentError, "cc channel must be 0..15 (got #{channel.inspect})" unless channel.nil? || (channel.is_a?(Integer) && channel.between?(0, 15))
            @spec = ControlSpec.new(number: number, range: range, curve: curve, default: default, name: name, description: 'Param read by MIDI transforms')
            @channel = channel
            kwargs = { curve: (curve unless curve == :linear), default: default, channel: channel, name: name }.compact
            args = [number]
            args << range unless range == (0.0..1.0)
            with_recipe(nil, :cc, args, kwargs)
            freeze
          end

          def number
            @spec.number
          end

          def value_at(pos, frame: nil, transport: nil, stream: nil)
            raw = stream&.cc(number, channel: @channel)
            raw ||= Param.session_cc(number, pos, channel: @channel) if pos
            @spec.value(raw || @spec.default)
          end

          def control_specs
            [@spec]
          end
        end

        # A param that picks one of +choices+ by where +source+ is in its
        # range (GraphNode::Knob#choose: `knob(:style).choose(:mash, :play,
        # :along)`; KeyMethods#modes): the range split into equal zones,
        # one per choice, with hysteresis, so a knob resting on a border
        # (or a controller wobbling there) doesn't flutter between two
        # choices: leaving the current choice takes a move past the border
        # by HYSTERESIS of a zone.
        #
        # The hysteresis keeps the last choice made, so readers asking in
        # time order (note-ons, steps, cycles) get stable answers; a take
        # replays the same reads in the same order.
        class Choice < Base
          # How far past a border (in zones) the source must move to change
          # the choice.
          HYSTERESIS = 0.25

          attr_reader :source, :choices

          def initialize(source, choices, recipe: nil)
            raise ArgumentError, 'choose needs at least one choice' if choices.empty?
            @source = source.is_a?(Base) ? source : Param.wrap(source, 'choose')
            @choices = choices.freeze
            @last = nil
            @lock = Mutex.new
            receiver, name, args, kwargs = recipe || [source, :choose, choices, {}]
            with_recipe(receiver, name, args, kwargs || {})
          end

          # The 0..1 position of the source at +pos+: a knob's position in
          # its own range and scale, a cc's controller position along its
          # curve (ControlSpec#position: where a knob learned on that cc
          # sits, so both pick alike), else the value itself (clamped to
          # 0..1).
          def position_at(pos, frame: nil, transport: nil, stream: nil)
            v = ValueSource.value_at(@source, pos, frame: frame, transport: transport, stream: stream).to_f
            k = Choice.knob_of(@source)
            if k
              k.spec.position(v)
            elsif @source.is_a?(CC)
              @source.spec.position(v)
            else
              v
            end.clamp(0.0, 1.0)
          end

          def value_at(pos, frame: nil, transport: nil, stream: nil)
            @choices[index_at(position_at(pos, frame: frame, transport: transport, stream: stream))]
          end

          # The choice index for 0..1 position +x+, with hysteresis.
          def index_at(x)
            n = @choices.length
            raw = MB::M.clamp((x * n).floor, 0, n - 1)
            peek = Param.peeking?
            @lock.synchronize {
              last = @last
              if last && raw != last
                # Stay unless past the current zone's border by the margin
                lo = last.to_f / n - HYSTERESIS / n
                hi = (last + 1).to_f / n + HYSTERESIS / n
                raw = last if x >= lo && x < hi
              end
              @last = raw unless peek
              raw
            }
          end

          def control_specs
            @source.respond_to?(:control_specs) ? @source.control_specs : []
          end

          def nodes
            @source.is_a?(Base) ? @source.nodes : []
          end

          # The knob behind +source+ (a Knob, a Reader, or a Graph of one),
          # or nil.
          def self.knob_of(source)
            ValueSource.knob_of(source.is_a?(Graph) ? Graph.unwrap(source.node) : source)
          end
        end

        # A clip read as a param (Sequence::Clip#value_at): the value of the
        # note sounding at each position (looping clips follow the
        # timeline from 0).
        class ClipValue < Base
          attr_reader :clip

          def initialize(clip)
            @clip = clip
            freeze
          end

          def value_at(pos, frame: nil, transport: nil, stream: nil)
            @clip.value_at(pos)
          end

          def to_ruby(&value_text)
            value_text ? value_text.call(@clip) : @clip.to_s
          end
        end

        # A graph read as a param: Session knobs (GraphNode::Knob, Readers),
        # tempo LFOs (Tones on a tempo-synced pitch such as `2.bars.lfo`,
        # with #at ranges, any phase, and the plain shapes), constants, and
        # sums and products of those (`0.6 + 0.3 * 2.bars.lfo`).  Anything
        # else raises when wrapped, naming the node.
        class Graph < Base
          # Tone shapes a tempo LFO param may have.
          SHAPES = [:sine, :triangle, :square, :ramp, :parabola, :gauss].freeze

          attr_reader :node

          def initialize(node, what = 'This option')
            @node = node
            Graph.check(node, what)
            freeze
          end

          def value_at(pos, frame: nil, transport: nil, stream: nil)
            Graph.eval(@node, pos, frame)
          end

          def control_specs
            Graph.nodes(@node).flat_map { |n| n.respond_to?(:control_specs) && n.is_a?(GraphNode::Knob) ? n.control_specs : [] }
          end

          def nodes
            [@node]
          end

          def to_ruby(&value_text)
            value_text ? value_text.call(@node) : Param.label(@node)
          end

          # +node+ through Tee branches to the node behind them.
          def self.unwrap(node)
            node = node.original_source while node.is_a?(GraphNode::Tee::Branch)
            node
          end

          # The nodes of the tree (see .check).
          def self.nodes(node)
            node = unwrap(node)
            case node
            when GraphNode::Mixer then [node] + node.summands.flat_map { |s| nodes(s) }
            when GraphNode::Multiplier then [node] + node.multiplicands.flat_map { |m| nodes(m) }
            when GraphNode::Knob::Reader then [node.knob]
            else [node]
            end
          end

          # Raises NotAParam unless every node of +node+'s tree can be read
          # at a position.
          def self.check(node, what)
            nodes(node).each do |n|
              case n
              when GraphNode::Mixer, GraphNode::Multiplier, GraphNode::Constant, GraphNode::Knob
                next
              when Tone
                f = unwrap(n.frequency)
                ok = f.is_a?(Sequence::TempoNode) && f.mode == :hz && n.phase_mod.nil? && SHAPES.include?(n.wave_type)
                next if ok
                hz = f.is_a?(GraphNode::Constant) ? f.constant.to_f : (f.is_a?(Numeric) ? f.to_f : nil)
                if hz&.positive? && hz < 20 && n.phase_mod.nil?
                  # (a Hz LFO: name the tempo LFO with about its period)
                  raise NotAParam, "#{what} reads params at decision points, which follow the timeline, not a sample clock: " \
                    "write #{tempo_lfo_for(hz)}.lfo.at(...) for #{MB::M.sigfigs(hz, 3)}.hz.lfo, or use cc(1, lo..hi), knob(:x), or a clip"
                end
                raise NotAParam, "#{what} reads params at decision points: a tempo LFO like 2.bars.lfo (plain shapes, #at, with_phase) works, " \
                  "a #{n.wave_type} Tone at #{Param.label(n.frequency)} doesn't (a transform has no sample clock; to steer it from audio, have a knob follow it: turn :x, follow: node)"
              else
                raise NotAParam, "#{what} reads params at decision points (knob(:x), cc(1), 2.bars.lfo, a clip, numbers, and sums or products of them), " \
                  "not audio-rate nodes like #{n.class.name.split('::').last}; to steer it from audio, have a knob follow it: turn :x, follow: node"
              end
            end
          end

          # A tempo length about one period of +hz+ at the current tempo, as
          # Ruby: "5.bars" (0.1 Hz at 120 BPM), else "3.beats".
          def self.tempo_lfo_for(hz)
            t = Sequence.current_transport
            whole = t.whole_notes_per_second.to_f / hz
            bars = whole / t.bar_length.to_f
            return (bars.round == 1 ? '1.bar' : "#{bars.round}.bars") if bars >= 0.75
            beats = MB::M.max((whole * 4).round, 1)
            beats == 1 ? '1.beat' : "#{beats}.beats"
          end

          # The value of the tree at +pos+ (knobs at Session frame +frame+
          # when given).
          def self.eval(node, pos, frame = nil)
            node = unwrap(node)
            case node
            when GraphNode::Constant then node.constant
            when GraphNode::Knob, GraphNode::Knob::Reader then node.value_at(pos, frame: frame)
            when GraphNode::Mixer
              node.summands.sum(node.constant.to_f) { |s| node[s] * eval(s, pos, frame) }
            when GraphNode::Multiplier
              node.multiplicand_counts.reduce(node.constant.to_f) { |p, (m, k)| p * eval(m, pos, frame)**k }
            when Tone then lfo_value(node, pos)
            else raise NotAParam, "Can't read #{node} as a param"
            end
          end

          # A tempo LFO's value at timeline position +pos+: its shape at
          # pos / cycle length plus its phase, through its #at range.
          def self.lfo_value(tone, pos)
            tempo = unwrap(tone.frequency)
            cycles = (pos.to_r / tempo.duration.whole_notes) + tone.phase.to_r
            phase = (cycles - cycles.floor).to_f
            v = Tone.shape_ruby(tone.wave_type, Numo::DFloat[phase], 0.0, nil)[0]
            r = tone.range
            r ? (r.end - r.begin) / 2.0 * v + (r.begin + r.end) / 2.0 : v
          end
        end
      end
    end
  end
end
