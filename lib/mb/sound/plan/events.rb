module MB
  module Sound
    module Plan
      # How event-driven nodes (MIDI note and controller nodes, envelopes'
      # per-buffer bookkeeping) take part in plans.
      #
      # Their work splits in two:
      # - per block, in Ruby, a *feed* (#plan_feed on the node, called by
      #   the Region once per planned block, before the ops run) reads the
      #   node's events and updates the node's own state exactly as its
      #   #sample does (its reader, note stack, held values, glide), but
      #   instead of writing samples it records what the buffer holds as an
      #   EventList: held values from a sample offset on, single-sample
      #   impulses, or glide ramps;
      # - in C (Op::Events), the list is rendered into a register.
      #
      # So node state stays in the node (a plan can drop at any block
      # boundary), the exact-sample edge rules are the node's own Ruby
      # (Notes::Node#items, #render), and a block costs one Ruby feed per
      # node (cheap without events) instead of buffer fills, constant
      # buffers, ports, and Tee branches.
      #
      # Feeds may also end planning: #plan_finished? (checked before
      # anything is read) is true once the node's stream is over, when the
      # node could start returning nil (ending the graph) in an order that
      # depends on which node is sampled first; the Region then runs that
      # block unfused and replans with the node as a boundary.
      #
      # An EventList is a flat Ruby Array read by the C executor (see
      # fast_plan.c run_events): the mode (MODE_HELD: entries cover the
      # block; MODE_IMPULSES: zeros plus single samples), then entries of
      # ENTRY_SIZE values: kind, from, to, and five arguments.
      class EventList
        MODE_HELD = 0
        MODE_IMPULSES = 1

        # Entry kinds (enum event_kind in fast_plan.c).
        FILL = 0     # a: the value from +from+ to +to+
        IMPULSE = 1  # a: the value at +from+
        GLIDE = 2    # a: start, b: target, c: position at +from+, d: length, e: overshoot k (Notes::Glide)
        BUFFER = 3   # a: an SFloat whose first to - from samples are copied
        RAMP = 4     # a: position at +from+, b: length (Notes::FadeIn)

        ENTRY_SIZE = 8

        # The Array the executor reads.
        attr_reader :data

        def initialize
          @data = [MODE_HELD]
        end

        # Starts a new block of held values (FILL/GLIDE/BUFFER entries
        # covering it).
        def held!
          @data.clear
          @data << MODE_HELD
          self
        end

        # Starts a new block of impulses on zeros.
        def impulses!
          @data.clear
          @data << MODE_IMPULSES
          self
        end

        def mode
          @data[0]
        end

        # A held block of +count+ samples of +value+, leaving the list as it
        # is if it already says that (a steady node's usual block).
        def steady!(count, value)
          d = @data
          return self if d.length == 9 && d[0] == MODE_HELD && d[1] == FILL && d[3] == count && d[4] == value && d[2] == 0

          held!
          fill(0, count, value)
        end

        # +value+ from sample +from+ to +to+ (exclusive).
        def fill(from, to, value)
          @data.push(FILL, from, to, value, 0, 0, 0, 0)
          self
        end

        # +value+ at sample +off+ (replacing an impulse already there).
        def impulse(off, value)
          i = 1
          while i < @data.length
            if @data[i + 1] == off
              @data[i + 3] = value
              return self
            end
            i += ENTRY_SIZE
          end
          @data.push(IMPULSE, off, off + 1, value, 0, 0, 0, 0)
          self
        end

        # The impulse value at +off+ as the buffer would hold it (float32),
        # or 0.0.
        def impulse_at(off)
          i = 1
          while i < @data.length
            return Plan.float32(@data[i + 3]) if @data[i + 1] == off
            i += ENTRY_SIZE
          end
          0.0
        end

        # A Notes::Glide smoothstep ramp (see Notes::Glide#fill).
        def glide(from, to, start, target, position, length, k)
          @data.push(GLIDE, from, to, start.to_f, target.to_f, position.to_f, length.to_f, k.to_f)
          self
        end

        # A Notes::FadeIn ramp: (position + 1 + i) / length, clipped to 0..1,
        # in single precision as FadeIn#fill computes it.
        def ramp(from, to, position, length)
          @data.push(RAMP, from, to, position.to_f, length.to_f, 0, 0, 0)
          self
        end

        # The value of a held list's first sample (as the buffer would hold
        # it), or 0.0.
        def first_value
          return 0.0 if @data.length < 1 + ENTRY_SIZE || @data[0] != MODE_HELD

          kind, from, to, a, b = @data[1, 5]
          return 0.0 unless from == 0
          case kind
          when FILL then Plan.float32(a)
          when RAMP then render(1)[0]
          else render(1)[0]
          end
        end

        # The first to - from samples of +buffer+ (an SFloat).
        def buffer(from, to, buffer)
          @data.push(BUFFER, from, to, buffer, 0, 0, 0, 0)
          self
        end

        # The entries as [kind, from, to, args...] Arrays (for listings and
        # specs).
        def entries
          @data[1..].each_slice(ENTRY_SIZE).to_a
        end

        # Renders the list into an SFloat of +count+ samples (the Ruby
        # mirror of fast_plan.c run_events).
        def render(count)
          out = Numo::SFloat.zeros(count)
          entries.each do |kind, from, to, a, b, c, d, e|
            # Entries past a short block (a boundary input gave fewer
            # samples) are cut off, as the node's buffer would be
            next if from >= count
            to = count if to > count

            case kind
            when FILL
              out[from...to] = a if to > from
            when IMPULSE
              out[from] = a
            when GLIDE
              out[from...to] = EventList.glide_ruby(to - from, a, b, c, d, e) if to > from
            when BUFFER
              out[from...to] = a[0...(to - from)] if to > from
            when RAMP
              out[from...to] = (Numo::SFloat.new(to - from).seq(a.to_i + 1) / b.to_i).clip(0.0, 1.0) if to > from
            else
              raise ArgumentError, "Unknown event list entry #{kind}"
            end
          end
          out
        end

        # The ramp of Notes::Glide#fill for +n+ samples (a DFloat), with the
        # same operations in the same order.
        def self.glide_ruby(n, start, target, position, length, k)
          t = Numo::DFloat.new(n).seq(position + 1)
          t.inplace / length
          t.inplace.clip(0.0, 1.0)
          shaped = t * -2
          shaped.inplace + 3
          sq = t * t
          shaped.inplace * sq
          if k != 0
            bump = t * -1
            bump.inplace + 1
            bump.inplace * bump
            sq.inplace * t
            bump.inplace * sq
            bump.inplace * k
            shaped.inplace + bump
          end
          shaped.inplace * (target - start)
          shaped.inplace + start
          shaped
        end

        # The last sample of a glide ramp of +n+ samples (a Float of the
        # float32 value the buffer holds), with the ramp's operations.
        def self.glide_last(n, start, target, position, length, k)
          t = (position + n).to_f / length
          t = 0.0 if t < 0.0
          t = 1.0 if t > 1.0
          shaped = t * -2
          shaped += 3
          sq = t * t
          shaped *= sq
          if k != 0
            bump = t * -1
            bump += 1
            bump *= bump
            sq *= t
            bump *= sq
            bump *= k
            shaped += bump
          end
          shaped *= (target - start)
          shaped += start
          Plan.float32(shaped)
        end
      end

      # Stands in for a node's output buffer while its own #render records
      # an EventList (see Notes::Node#plan_feed): `buf[from...to] = value`
      # becomes a held entry, `buf.fill(0)` starts impulses, and `buf[off]`
      # reads an impulse back as the buffer would hold it.
      class Recorder
        attr_reader :list
        attr_accessor :length

        def initialize(list)
          @list = list
          @length = 0
        end

        # Starts recording a block of +count+ samples (held values).
        def start(count)
          @length = count
          @list.held!
          self
        end

        def fill(value)
          raise ArgumentError, "A recorder only fills with 0 (impulses), not #{value}" unless value == 0

          @list.impulses!
          self
        end

        def [](index)
          raise ArgumentError, 'A recorder reads impulses only' unless @list.mode == EventList::MODE_IMPULSES && index.is_a?(Integer)

          @list.impulse_at(index)
        end

        def []=(index, value)
          raise ArgumentError, "A recorder takes numbers (got #{value.class})" unless value.is_a?(Numeric)

          if index.is_a?(Range)
            from = index.begin
            to = index.exclude_end? ? index.end : index.end + 1
            @list.fill(from, to, value.to_f) if to > from
          else
            @list.impulse(index, value.to_f)
          end
        end
      end

      # The session Tuning as it is when each block runs (Tuning.current),
      # for Op::NoteFreq.
      CURRENT_TUNING = Object.new
      class << CURRENT_TUNING
        def note = MB::Sound::Tuning.current.note
        def frequency = MB::Sound::Tuning.current.frequency
        def to_s = 'current tuning'
        alias inspect to_s
      end

      class << self
        # +feeders+ (see EventList) with the ones whose class groups its
        # feeds (.plan_group, e.g. Notes nodes on one stream) grouped, in
        # order of first appearance.
        def group_feeders(feeders)
          groupable = feeders.select { |f| f.class.respond_to?(:plan_group) }
          return feeders if groupable.length < 2

          by_class = groupable.group_by { |f| f.class.method(:plan_group).owner }
          grouped = by_class.values.flat_map { |list| list[0].class.plan_group(list) }
          rest = feeders - groupable
          first = ->(g) { (g.respond_to?(:plan_nodes) ? g.plan_nodes : [g]).map { |n| feeders.index { |f| f.equal?(n) } }.min }
          (rest + grouped).sort_by { |g| first.(g) }
        end

        # True if +node+ is an event-driven node a plan feeds (see
        # EventList), e.g. a Notes trigger.
        def event_node?(node)
          node.respond_to?(:plan_feed)
        end

        # +x+ rounded to float32, as a Float.
        def float32(x)
          [x].pack('f').unpack1('f')
        end
      end

      module Op
        # A block of an event-driven node's output, rendered from the
        # EventList its feed recorded (see Plan::EventList): held values,
        # impulses, and glide ramps.  Exact: the same float32 values the
        # node's #render writes.
        class Events < Base
          # The node whose feed fills the list.
          attr_reader :feeder

          # The output's name for nodes with several outputs (nil for the
          # main one).
          attr_reader :port

          # The EventList.
          attr_reader :list

          def initialize(dst, node, feeder:, port: nil)
            super(dst, node)
            @feeder = feeder
            @port = port
            @list = feeder.plan_event_list(port)
          end

          def expression
            "events #{Plan.node_label(@feeder)}#{@port ? " #{@port}" : ''}"
          end

          def opcode = :events

          def run_ruby(env, count)
            env[@dst] = @list.render(count)
          end
        end

        # A Notes::Smoother on a Value (a smoothed controller node's
        # events), with the smoother's own state Arrays and the block's jump
        # offsets (the node's feed fills them; see Notes::Node).  The kernel
        # is FastControl.smooth's (mb_smooth.h); the mirror
        # Notes::Smoother.smooth_ruby.
        class Smooth < Base
          attr_reader :a, :smoother, :jumps

          def initialize(dst, node, a, smoother, jumps)
            super(dst, node)
            raise Unsupported.new(node, 'complex smoothing') if a.complex?

            @a = a
            @smoother = smoother
            @jumps = jumps
          end

          def operands
            [@a]
          end

          def expression
            "smooth(#{@a}, #{MB::M.sigfigs(@smoother.kernel_samples, 4)} samples)"
          end

          def opcode = :smooth

          # Notes::Smoother#process's segments between jumps.
          def run_ruby(env, count)
            x = env.fetch(@a)
            x = x[0...count] if x.length > count
            out = Numo::SFloat.zeros(count)
            st, r1, r2 = @smoother.plan_arrays
            settle = (r1.length + r2.length - 2).to_f
            start = 0
            @jumps.each do |j|
              next if j < start || j >= count

              MB::Sound::Notes::Smoother.smooth_ruby(x, out, start, j, st, r1, r2) if j > start
              st[1] = x[j]
              st[6] = settle
              start = j
            end
            MB::Sound::Notes::Smoother.smooth_ruby(x, out, start, count, st, r1, r2) if start < count
            env[@dst] = out
          end
        end

        # The larger of two real Values, as Numo::SFloat.maximum chooses
        # (a if a >= b or b is NaN, else b).
        class Max < Binary
          def initialize(dst, node, a, b)
            super
            raise Unsupported.new(node, 'complex maximum') if a.complex? || b.complex?
            raise Unsupported.new(node, 'a constant maximum') unless a.is_a?(Value) && b.is_a?(Value)
          end

          def expression
            "max(#{@a}, #{@b})"
          end

          def opcode = :max

          def run_ruby(env, count)
            env[@dst] = Numo::SFloat.maximum(env.fetch(@a)[0...count], env.fetch(@b)[0...count])
          end
        end

        # Stores the last sample of a Value into a node's instance variable
        # (a node's #value, e.g. Notes::Frequency's latest frequency) after
        # the block.  Its dst is never read.
        class Keep < Base
          attr_reader :a, :target, :ivar

          def initialize(dst, node, a, target, ivar)
            super(dst, node)
            raise ArgumentError, 'Keep needs a real Value' unless a.is_a?(Value) && a.real?

            @a = a
            @target = target
            @ivar = ivar
          end

          def operands
            [@a]
          end

          def expression
            "keep last #{@a} in #{Plan.node_label(@target)}#{@ivar}"
          end

          def opcode = :keep

          def run_ruby(env, count)
            buf = env.fetch(@a)
            if count > 0
              @target.is_a?(Hash) ? @target[@ivar] = buf[count - 1] : @target.instance_variable_set(@ivar, buf[count - 1])
            end
            env[@dst] = nil
          end
        end
      end
    end
  end
end
