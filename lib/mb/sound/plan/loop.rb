require_relative '../fast_loop'

module MB
  module Sound
    module Plan
      # Feedback loops (optimizer stage 2, phase 1; proposals/feedback_loops.md):
      # the body of a GraphNode::FeedbackLoop described as plan ops and run one
      # sample at a time (MB::Sound::FastLoop in C, or #run_ruby, its exact
      # mirror), so a value comes back around the loop on the next sample or
      # after any delay, and the output doesn't depend on the block size.
      #
      # The nodes on the loop (those that depend on the loop's own output) are
      # described with the plan layer's DSL (#plan_describe, or #loop_describe
      # for nodes that only run inside loops: delays and SVF filters), using
      # the block ops as scalar steps (float32 arithmetic, the shapers'
      # kernel) plus loop ops:
      #
      # - Op::LoopHistory: the loop output one sample earlier (z^-1), used when
      #   a path from the loop variable to the output has no delay (a one-pole
      #   built from nodes, `x.feedback { |y| x + (y - x) * 0.1 }`).
      # - Op::DelayRead / a ring write: a Filter::Delay node (`y.delay(t)`)
      #   reads its delay line before the sample's write, at its delay counted
      #   from the sample being computed (at least one sample), with its own
      #   time handling (Length::Source, smoothing) run per block outside the
      #   loop; when the loop has a delay on every path the loop variable is
      #   the current output and the delay provides the loop's latency.
      # - Op::Svf: a state-variable filter (`filter(:lowpass, ...)`).
      #
      # Everything that doesn't depend on the loop's output (the input, delay
      # times, gains, cutoffs, LFOs, envelopes) is computed by the graph a
      # block at a time and read per sample as boundary inputs.
      #
      # Latency compensation (user decision 2026-10-09): the delay with the
      # longest time on the loop (the "compensated" delay) reads that much
      # earlier than its time to make up for the latency of the rest of the
      # loop (a z^-1, an antialiased shaper's half sample, a lowpass SVF's
      # group delay at DC, other delays), so the loop's period is exactly the
      # delay time (Karplus-Strong tuning, exact echo times).  The latency is
      # the loop's group delay at DC, from each op's moments (gains weight
      # parallel paths: an average of a signal and its one-sample delay is
      # half a sample), computed per block in Ruby from the boundary inputs
      # (per sample when they change, e.g. a cutoff LFO).  #latency reports
      # it.
      module Loop
        # Ops that only exist in loop programs.
        module Op
          # The loop output one sample earlier (a one-sample history; state:
          # a Ruby Array [value]).
          class LoopHistory < Plan::Op::Base
            attr_reader :state

            def initialize(dst, node, state)
              super(dst, node)
              @state = state
            end

            def expression = 'history (output one sample earlier)'
            def opcode = :hread
          end

          # A delay line read inside a loop (see Ring).
          class DelayRead < Plan::Op::Base
            attr_reader :ring

            def initialize(dst, node, ring)
              super(dst, node)
              @ring = ring
            end

            def expression
              "delay_read(#{Plan.node_label(@ring.node)}#{@ring.compensated ? ', compensated' : ''})"
            end

            def opcode = :dread
          end

          # The loop variable when it is the current output (every path from it
          # to the output has a delay): a copy of the output, made after the
          # output for the delays' inputs.  The latency estimate starts here.
          class LoopOutput < Plan::Op::Copy
            def expression = "loop variable (output #{@a})"
          end

          # A state-variable filter (Filter::SVF) on a real value, with its
          # cutoff, quality, and gain as Values or Consts (a Const keeps its
          # double value, as FastFilter.svf reads a Numeric).
          class Svf < Plan::Op::Base
            attr_reader :a, :filter, :cutoff, :quality, :gain

            def initialize(dst, node, a, filter, cutoff:, quality:, gain:)
              super(dst, node)
              @a = a
              @filter = filter
              @cutoff = cutoff
              @quality = quality
              @gain = gain
            end

            def operands
              [@a, @cutoff, @quality, @gain].grep(Plan::Value)
            end

            def expression
              "svf_#{@filter.filter_type}(#{@a}, cutoff: #{@cutoff}, quality: #{@quality}, gain: #{@gain})"
            end

            def opcode = :svf
          end
        end

        # A Filter::Delay node inside a loop: its delay line (the node's own
        # MB::Sound::DelayLine buffer, so the node's state stays in the node),
        # its per-block delay times (the node's own time handling, including
        # smoothing), and the input Value written each sample.
        class Ring
          # The SampleWrapper node and its Filter::Delay.
          attr_reader :node, :delay

          # The DelayRead op and the Value written each sample.
          attr_accessor :read, :input

          # True for the delay that absorbs the loop's latency (see Loop).
          attr_accessor :compensated

          # The constant delay in samples at compile time (nil for a node
          # delay), for choosing the compensated delay.
          attr_reader :constant_samples

          # The delays of the current block (a Float or a DFloat), for the
          # latency of uncompensated delays (see Program#latency).
          attr_accessor :last_delay

          def initialize(node)
            @node = node
            @delay = node.base_filter
            @input = nil
            @read = nil
            @compensated = false
            ds = @delay.delay_samples
            @constant_samples = ds.is_a?(Numeric) ? ds.to_f : nil
          end

          # The delay line (a MB::Sound::DelayLine).
          def line
            @delay.instance_variable_get(:@line)
          end

          # The interpolation mode number (DelayLine::INTERPOLATION).
          def mode
            DelayLine::INTERPOLATION.fetch(@delay.interpolation)
          end

          # The read state Array ([previous delay]) shared with the node.
          def read_state
            @delay.instance_variable_get(:@read_state)
          end

          # The delays in samples for +count+ samples (a Numeric or an
          # NArray), or nil if the delay time node ended (Filter::Delay's
          # own per-block time handling, including smoothing).
          def delays(count)
            d = @delay.send(:delay_buffer, count)
            d.equal?(:end) ? nil : d
          end
        end

        # The loop builder: Plan::Builder with the loop ops, refusing the ops
        # that can't run one sample at a time (oscillators, envelopes, MIDI
        # events) and complex values.
        class Builder < Plan::Builder
          # The rings described so far, in order.
          attr_reader :rings

          # The history ops (zero or one).
          attr_reader :histories

          # +deferrer+ is called with (ring, handle) for each delay's input
          # (see #defer).
          def initialize(resolver, deferrer = nil)
            super(resolver)
            @deferrer = deferrer
            @rings = []
            @histories = []
          end

          # Describes +node+ with #loop_describe (nodes that only run inside
          # loops: delays and SVF filters) or #plan_describe (see
          # Plan::Builder#describe).
          def describe(node)
            @node_stack.push(node)
            v = if node.respond_to?(:loop_describe)
                  node.loop_describe(self)
                elsif node.is_a?(Plan::Describable) && (why = node.plan_unsupported_reason).nil?
                  node.plan_describe(self)
                else
                  raise Unsupported.new(node, why || "#{Plan.class_label(node)} has no loop ops (a feedback loop runs arithmetic, shapers, delays, and SVF filters per sample)")
                end
            v = const(v) if v.is_a?(Numeric)
            v = fill(v) if v.is_a?(Plan::Const)
            raise Unsupported.new(node, "its description returned #{v.inspect} instead of a Plan::Value") unless v.is_a?(Plan::Value)

            v
          ensure
            @node_stack.pop
          end

          # Queues +ring+'s input +handle+ to be described after the loop's
          # output (a delay's input may read the loop variable as the
          # current output; see GraphNode::FeedbackLoop).
          def defer(ring, handle)
            raise Unsupported.new(node, 'a delay outside a feedback loop body') unless @deferrer

            @deferrer.call(ring, handle)
          end

          # The loop variable as the current output +output+ (see
          # Op::LoopOutput).
          def loop_output(output)
            emit(Op::LoopOutput.new(value(:real), node, output))
          end

          # The loop output one sample earlier (see Op::LoopHistory).
          def history(state)
            op = Op::LoopHistory.new(value(:real), node, state)
            @histories << op
            emit(op)
          end

          # A delay line read for +ring+ (its input is resolved later; see
          # Loop::Compiler).
          def delay_read(ring)
            op = Op::DelayRead.new(value(:real), node, ring)
            ring.read = op
            @rings << ring
            emit(op)
          end

          # A state-variable filter.
          def svf(filter, a, cutoff:, quality:, gain:)
            a = self[a]
            raise Unsupported.new(node, 'a complex input') if a.complex?

            emit(Op::Svf.new(value(:real), node, a, filter, cutoff: self[cutoff], quality: self[quality], gain: self[gain]))
          end

          def fill(c)
            c = const(c) unless c.is_a?(Plan::Const)
            raise Unsupported.new(node, 'a complex constant in a feedback loop') if c.complex?

            super
          end

          def param(constant, complex: constant.constant.is_a?(Complex))
            raise Unsupported.new(node, 'a complex constant in a feedback loop') if complex

            super
          end

          def tone(*, **)
            raise Unsupported.new(node, 'an oscillator inside a feedback loop (P1 runs arithmetic, shapers, delays, and SVF filters per sample)')
          end

          %i[events smooth keep_last note_freq part envelope].each do |m|
            define_method(m) do |*, **|
              raise Unsupported.new(node, "#{m} inside a feedback loop")
            end
          end

          private

          def binary(klass, a, b)
            a, b = operands(a, b)
            raise Unsupported.new(node, 'complex values in a feedback loop') if a.complex? || b.complex?

            super
          end
        end

        # A compiled loop body (see Loop): ops in sample order, ring writes and
        # the history write at the end, boundary inputs and Constant params,
        # the output Value; lowers to FastLoop words, runs in C (#run) or Ruby
        # (#run_ruby), and computes the loop's latency (#latency).
        class Program
          # Opcodes of the C executor (fast_loop.c; specs compare them with
          # FastLoop.constants).
          OPCODES = {
            end: 0, fill: 1, mul: 2, muls: 3, add: 4, adds: 5, div: 6, divs: 7, pow: 8, max: 9, copy: 10,
            shape: 11, svf: 12, dread: 13, dwrite: 14, hread: 15, hwrite: 16, muladd: 17, mulsadd: 18,
          }.freeze

          # Sinc reads closer than the kernel's reach blend into cubic over
          # this many samples (LOOP_SINC_BLEND in fast_loop.c).
          SINC_BLEND = 4.0

          # SVF states below this flush to zero after each sample.
          SVF_FLUSH = 1e-30

          class << self
            # Whether lowering forms multiply-add superinstructions (true by
            # default; false for comparisons).  Read when a program lowers.
            attr_accessor :superinstructions
          end
          self.superinstructions = true

          attr_reader :ops, :inputs, :params, :rings, :histories, :output

          # True when the loop variable is the output one sample earlier (a
          # path without a delay), false when it is the current output.
          attr_reader :history

          # The compensated ring, or nil.
          attr_reader :compensated

          # A title for listings.
          attr_accessor :title

          def initialize(ops:, inputs:, params:, rings:, histories:, output:, history:, title: nil)
            @ops = ops.freeze
            @inputs = inputs.freeze
            @params = params.freeze
            @rings = rings.freeze
            @histories = histories.freeze
            @output = output
            @history = history
            @title = title
            @compensated = @rings.find(&:compensated)
            @lowered = nil
          end

          # True if every op gives exactly what its mirror gives (always: the
          # C loop and #run_ruby are bit-identical).
          def exact?
            true
          end

          # A listing of the ops (with ring writes and the history write).
          def to_s
            lower
            lines = []
            lines << "Feedback loop #{@title}" if @title
            lines << "  #{@ops.length} ops (#{@inputs.length} inputs, #{@params.length} params, #{@rings.length} delays, #{@history ? 'one-sample history' : 'no history'}); output #{@output}"
            @ops.each do |op|
              label = op.node && !op.is_a?(Plan::Op::Input) ? "  # #{Plan.node_label(op.node)}" : ''
              lines << format('  %-6s %-58s%s', "r#{@reg[op.dst]}", op.to_s, label)
            end
            @rings.each { |g| lines << "         write #{Plan.node_label(g.node)} <- #{g.input}" }
            @histories.each { lines << "         history <- #{@output}" }
            fused = @fused_count.to_i
            lines << "  (#{fused} multiply-add superinstruction#{fused == 1 ? '' : 's'})" if fused > 0
            lines.join("\n")
          end

          # Lowers to [words (Int32), scalars (DFloat), objects (Array of op
          # objects, with ring and history slots filled per call)].
          def lower
            return @lowered if @lowered

            @reg = {}.compare_by_identity
            @ops.each { |op| @reg[op.dst] = @reg.length }
            scalars = []
            objects = []
            sc = ->(*v) { scalars.concat(v.map(&:to_f)); scalars.length - v.length }
            reg = ->(v) { @reg.fetch(v) }

            ring_index = @rings.each_with_index.to_h { |g, i| [g, i] }.compare_by_identity
            hist_index = @histories.each_with_index.to_h { |h, i| [h, i] }.compare_by_identity

            # Ring and history objects are rebuilt per call (#objects_for)
            @ring_slots = @rings.map { objects << nil; objects.length - 1 }
            @hist_slots = @histories.map { |h| objects << h.state; objects.length - 1 }

            uses = Hash.new(0).compare_by_identity
            @ops.each { |op| op.operands.each { |v| uses[v] += 1 } }
            @rings.each { |g| uses[g.input] += 1 if g.input.is_a?(Plan::Value) }
            uses[@output] += 1
            producer = @ops.to_h { |op| [op.dst, op] }.compare_by_identity

            # Multiply-adds: an Add whose product operand is used only there
            # runs as one superinstruction at the Add (same two roundings)
            fused = {}.compare_by_identity
            fuse_at = {}.compare_by_identity
            @ops.each do |op|
              next unless Program.superinstructions && op.is_a?(Plan::Op::Add)

              f = fusable_product(op, producer, uses)
              next unless f && !fused.key?(f[1])

              fused[f[1]] = true
              fuse_at[op] = f
            end
            @fused_count = fuse_at.length

            body = []
            @ops.each do |op|
              case op
              when Plan::Op::Input, Plan::Op::Param
                next
              when Plan::Op::Fill
                body << [OPCODES[:fill], reg.(op.dst), sc.(op.value.parts[0])]
              when Plan::Op::Mul, Plan::Op::Add
                next if fused[op]

                if (f = fuse_at[op])
                  other, prod = f
                  if prod.a.is_a?(Plan::Const) || prod.b.is_a?(Plan::Const)
                    k, v = prod.a.is_a?(Plan::Const) ? [prod.a, prod.b] : [prod.b, prod.a]
                    body << [OPCODES[:mulsadd], reg.(op.dst), reg.(other), reg.(v), sc.(k.parts[0])]
                  else
                    body << [OPCODES[:muladd], reg.(op.dst), reg.(other), reg.(prod.a), reg.(prod.b)]
                  end
                  next
                end

                name = op.is_a?(Plan::Op::Mul) ? :mul : :add
                if op.a.is_a?(Plan::Const)
                  body << [OPCODES[:"#{name}s"], reg.(op.dst), reg.(op.b), sc.(op.a.parts[0])]
                elsif op.b.is_a?(Plan::Const)
                  body << [OPCODES[:"#{name}s"], reg.(op.dst), reg.(op.a), sc.(op.b.parts[0])]
                else
                  body << [OPCODES[name], reg.(op.dst), reg.(op.a), reg.(op.b)]
                end
              when Plan::Op::Div
                body << (op.b.is_a?(Plan::Const) ? [OPCODES[:divs], reg.(op.dst), reg.(op.a), sc.(op.b.parts[0])] : [OPCODES[:div], reg.(op.dst), reg.(op.a), reg.(op.b)])
              when Plan::Op::Pow
                body << [OPCODES[:pow], reg.(op.dst), reg.(op.a), reg.(op.b)]
              when Plan::Op::Max
                body << [OPCODES[:max], reg.(op.dst), reg.(op.a), reg.(op.b)]
              when Plan::Op::Copy
                body << [OPCODES[:copy], reg.(op.dst), reg.(op.a)]
              when Plan::Op::Shape
                sh = op.shaper
                objects << sh.plan_state
                body << [OPCODES[:shape], reg.(op.dst), reg.(op.a), objects.length - 1,
                         sc.(Plan::Op::Shape::MODES.fetch(sh.mode), sh.p1, sh.p2, sh.antialias ? 1 : 0)]
              when Op::Svf
                objects << op.filter.instance_variable_get(:@state)
                params = [op.cutoff, op.quality, op.gain].map { |v| v.is_a?(Plan::Const) ? -1 - sc.(v.value.to_f) : reg.(v) }
                body << [OPCODES[:svf], reg.(op.dst), reg.(op.a), objects.length - 1, *params,
                         op.filter.type_id, sc.(op.filter.sample_rate)]
              when Op::DelayRead
                body << [OPCODES[:dread], reg.(op.dst), ring_index.fetch(op.ring)]
              when Op::LoopHistory
                body << [OPCODES[:hread], reg.(op.dst), hist_index.fetch(op)]
              else
                raise Unsupported.new(op.node, "no loop lowering for #{op.class}")
              end
            end
            @rings.each_with_index { |g, i| body << [OPCODES[:dwrite], i, reg.(g.input)] }
            @histories.each_with_index { |_, i| body << [OPCODES[:hwrite], i, reg.(@output)] }
            body << [OPCODES[:end]]

            in_regs = @inputs.map { |op| reg.(op.dst) }
            par_regs = @params.map { |op| reg.(op.dst) }
            words = [@reg.length, reg.(@output), @inputs.length, @params.length, @rings.length, @histories.length,
                     *in_regs, *par_regs, *@ring_slots, *@hist_slots, *body.flatten]

            @fused = fused
            @lowered = [Numo::Int32.cast(words), Numo::DFloat.cast(scalars.empty? ? [0.0] : scalars), objects]
          end

          # Runs +count+ samples in C: +inputs+ (SFloat buffers, in #inputs
          # order), +params+ (Numerics or SFloat buffers), +delays+ (per ring:
          # a Numeric or an NArray of delays in samples, compensated), into
          # +out+ (an SFloat of at least +count+).  Returns +out+.
          def run(count, inputs, params, delays, out)
            words, scalars, objects = lower
            objects_for(objects)
            MB::Sound::FastLoop.run(words, scalars, objects, inputs, params, delays, out, count)
            store_rings(count, objects)
            out
          end

          # The exact Ruby mirror of #run (same arguments; returns a new
          # SFloat).
          def run_ruby(count, inputs, params, delays)
            lower
            regs = Array.new(@reg.length, 0.0)
            out = Numo::SFloat.zeros(count)
            in_arrays = inputs.map { |b| b.to_a }
            par_arrays = params.map { |p| p.is_a?(Numo::NArray) ? p.to_a : p }

            rings = @rings.each_with_index.map { |g, i|
              line = g.line
              state = g.read_state
              d = delays[i]
              {
                line: line, buffer: line.instance_variable_get(:@buffer), cap: line.capacity,
                w: line.instance_variable_get(:@write_offset), prev: state[0], have_prev: !state[0].nil?,
                mode: g.mode, blend: g.mode == DelayLine::INTERPOLATION[:sinc],
                delays: d.is_a?(Numo::NArray) ? d.to_a : d, moving: d.is_a?(Numo::NArray),
                max: (line.capacity - 1 - line.send(:margin, g.mode)).to_f
              }
            }
            hists = @histories.map { |h| f32(h.state[0]) }
            ops = @ops.reject { |op| op.is_a?(Plan::Op::Input) || op.is_a?(Plan::Op::Param) }
            svf_states = {}.compare_by_identity

            count.times do |i|
              @inputs.each_with_index { |op, k| regs[@reg[op.dst]] = in_arrays[k][i] }
              @params.each_with_index { |op, k| p = par_arrays[k]; regs[@reg[op.dst]] = p.is_a?(Array) ? p[i] : f32(p) }

              ops.each do |op|
                r = @reg[op.dst]
                regs[r] = step_ruby(op, regs, rings, hists, i, svf_states)
              end

              @rings.each_with_index do |g, k|
                st = rings[k]
                st[:buffer][st[:w]] = regs[@reg[g.input]]
                st[:w] += 1
                st[:w] = 0 if st[:w] >= st[:cap]
              end
              @histories.each_with_index { |_, k| hists[k] = regs[@reg[@output]] }

              out[i] = regs[@reg[@output]]
            end

            rings.each_with_index do |st, k|
              @rings[k].read_state[0] = st[:prev] if st[:have_prev]
              advance_line(@rings[k].line, count, st[:w])
            end
            @histories.each_with_index { |h, k| h.state[0] = hists[k] }
            out
          end

          # The loop's latency apart from the compensated delay, in samples
          # (a Float, or a DFloat per sample), for one block: +values+ gives
          # the block's data for each boundary input and param Value (see
          # Loop's description).  0.0 without a compensated delay.
          def latency(values)
            return 0.0 unless @compensated

            # The latency depends only on a few values (gains on parallel
            # paths, cutoffs, other delays); reuse it while they hold still
            # (a buffer counts as the same only if it is the same frozen
            # object: Constants and Notes nodes return one while they hold)
            if @lat_deps && @lat_key
              same = true
              i = 0
              @lat_deps.each do |v|
                same &&= same_value?(values[v], @lat_key[i])
                i += 1
              end
              @lat_rings.each do |g|
                same &&= same_value?(g.last_delay, @lat_key[i])
                i += 1
              end
              return @lat_value if same
            end

            @lat_record = [] unless @lat_deps
            @lat_record_rings = [] unless @lat_deps
            l = compute_latency(values)
            if @lat_record
              @lat_deps = @lat_record.uniq
              @lat_rings = @lat_record_rings.uniq
              @lat_record = @lat_record_rings = nil
            end
            @lat_key = @lat_deps.map { |v| values[v] } + @lat_rings.map(&:last_delay)
            @lat_value = l
          end

          private

          def same_value?(x, old)
            if x.is_a?(Numo::NArray)
              x.equal?(old) && x.frozen?
            else
              !old.is_a?(Numo::NArray) && x == old
            end
          end

          def compute_latency(values)
            memo = {}.compare_by_identity
            out = moments(@output, values, memo)
            din = moments(@compensated.input, values, memo)
            a = ratio(out[0], out[1])
            b = ratio(din[2], din[3])
            l = add(a, b)
            @history ? add(l, 1.0) : l
          end

          ZERO = [0.0, 0.0, 0.0, 0.0].freeze

          # Fills the per-call ring objects (see fast_loop.c).
          def objects_for(objects)
            @rings.each_with_index do |g, i|
              line = g.line
              obj = (@ring_objects ||= [])[i] ||= []
              obj[0] = line.instance_variable_get(:@buffer)
              obj[1] = line.instance_variable_get(:@write_offset)
              obj[2] = g.read_state
              obj[3] = g.mode
              obj[4] = g.mode == DelayLine::INTERPOLATION[:sinc] ? DelayLine::SINC_KERNEL : nil
              obj[5] = true
              objects[@ring_slots[i]] = obj
            end
          end

          def store_rings(count, objects)
            @rings.each_with_index do |g, i|
              advance_line(g.line, count, objects[@ring_slots[i]][1])
            end
          end

          # Moves a delay line's write offset after a loop block (and its
          # block start, so #read and #past see the block).
          def advance_line(line, count, new_offset)
            old = line.instance_variable_get(:@write_offset)
            line.instance_variable_set(:@block_start, old)
            line.instance_variable_set(:@write_offset, new_offset)
          end

          # An Add whose one operand is a Mul (or Muls) used only by this Add
          # (and not the output): [other operand, the Mul op], else nil.
          def fusable_product(add, producer, uses)
            return nil unless add.a.is_a?(Plan::Value) && add.b.is_a?(Plan::Value)

            [[add.a, add.b], [add.b, add.a]].each do |other, v|
              prod = producer[v]
              next unless prod.is_a?(Plan::Op::Mul)
              next unless uses[v] == 1 && !v.equal?(@output)
              next if prod.a.is_a?(Plan::Const) && prod.b.is_a?(Plan::Const)
              # The product must come right before the add in sample order,
              # or its operands could change in between (they can't: values
              # are computed once per sample), so any earlier product works
              return [other, prod]
            end
            nil
          end

          def f32(x)
            [x.to_f].pack('f').unpack1('f')
          end

          # One op of #run_ruby for sample +i+.
          def step_ruby(op, regs, rings, hists, i, svf_states)
            case op
            when Plan::Op::Fill
              f32(op.value.parts[0])
            when Plan::Op::Mul, Plan::Op::Add, Plan::Op::Div, Plan::Op::Pow, Plan::Op::Max
              a = op.a.is_a?(Plan::Const) ? f32(op.a.parts[0]) : regs[@reg[op.a]]
              b = op.b.is_a?(Plan::Const) ? f32(op.b.parts[0]) : regs[@reg[op.b]]
              case op
              when Plan::Op::Mul then f32(a * b)
              when Plan::Op::Add then f32(a + b)
              when Plan::Op::Div then f32(a / b)
              when Plan::Op::Pow
                v = a < 0 && b != b.round ? Float::NAN : a**b
                v = v.real if v.is_a?(Complex)
                f32(v)
              else
                a >= b || b.nan? ? a : b
              end
            when Plan::Op::Copy
              regs[@reg[op.a]]
            when Plan::Op::Shape
              sh = op.shaper
              x = Numo::SFloat[regs[@reg[op.a]]]
              MB::Sound::Shaper.shape_ruby(x, sh.mode, sh.p1, sh.p2, sh.antialias, sh.plan_state)[0]
            when Op::Svf
              val = ->(v) { v.is_a?(Plan::Const) ? v.value.to_f : regs[@reg[v]] }
              f = op.filter
              MB::Sound::Filter::SVF.process_ruby(Numo::SFloat[regs[@reg[op.a]]], val.(op.cutoff), val.(op.quality), val.(op.gain),
                                                  f.type_id, f.instance_variable_get(:@state), f.sample_rate)[0]
            when Op::DelayRead
              st = rings[@rings.index { |g| g.equal?(op.ring) }]
              d = st[:delays].is_a?(Array) ? st[:delays][i].to_f : st[:delays].to_f
              if !(d >= 1)
                d = 1.0
              elsif d > st[:max]
                d = st[:max]
              end
              rate = st[:have_prev] && st[:moving] ? (1.0 - (d - st[:prev])).abs : 1.0
              st[:prev] = d
              st[:have_prev] = true
              f32(ring_read_ruby(st, d - 1.0, rate))
            when Op::LoopHistory
              hists[@histories.index { |h| h.equal?(op) }]
            else
              raise Unsupported.new(op.node, "no loop mirror for #{op.class}")
            end
          end

          # The mirror of ring_read in fast_loop.c.
          def ring_read_ruby(st, dd, rate)
            line = st[:line]
            base = st[:w] - 1
            base += st[:cap] if base < 0
            m = st[:mode]
            sinc = DelayLine::INTERPOLATION[:sinc]
            cubic = DelayLine::INTERPOLATION[:cubic]

            if m == sinc
              return line.send(:at, base, dd.to_i) if dd == dd.floor && rate <= 1

              if st[:blend]
                fc = rate > 1 ? 1.0 / (rate < DelayLine::SINC_MAX_RATE ? rate : DelayLine::SINC_MAX_RATE) : 1.0
                support = DelayLine::SINC_HALF / fc
                ws = (dd - (support - SINC_BLEND)) / SINC_BLEND
                return line.send(:interpolate, base, dd, cubic, rate) if ws <= 0

                if ws < 1
                  s = line.send(:interpolate, base, dd, sinc, rate)
                  c = line.send(:interpolate, base, dd, cubic, rate)
                  return ws * s + (1.0 - ws) * c
                end
              end
            end

            line.send(:interpolate, base, dd, m, rate)
          end

          # The moments [a0, a1, b0, b1] of +v+ (see Loop): a relative to the
          # compensated delay's output, b relative to the loop variable.
          def moments(v, values, memo)
            return ZERO unless v.is_a?(Plan::Value)
            return memo[v] if memo.key?(v)

            memo[v] = ZERO # breaks cycles through uncompensated delays (their inputs come later)
            op = v.op
            m = case op
                when Op::DelayRead
                  if op.ring.equal?(@compensated)
                    [1.0, 0.0, 0.0, 0.0]
                  else
                    @lat_record_rings << op.ring if @lat_record_rings
                    shift(moments(op.ring.input, values, memo), op.ring.last_delay)
                  end
                when Op::LoopHistory, Op::LoopOutput
                  [0.0, 0.0, 1.0, 0.0]
                when Plan::Op::Mul
                  ma = moments(op.a, values, memo)
                  mb = moments(op.b, values, memo)
                  if ma.equal?(ZERO) && mb.equal?(ZERO)
                    ZERO
                  elsif mb.equal?(ZERO)
                    scale(ma, value_of(op.b, values))
                  elsif ma.equal?(ZERO)
                    scale(mb, value_of(op.a, values))
                  else
                    sum(ma, mb)
                  end
                when Plan::Op::Div
                  ma = moments(op.a, values, memo)
                  mb = moments(op.b, values, memo)
                  if mb.equal?(ZERO) && !ma.equal?(ZERO)
                    scale(ma, inverse(value_of(op.b, values)))
                  else
                    sum(ma, mb)
                  end
                when Plan::Op::Add
                  sum(moments(op.a, values, memo), moments(op.b, values, memo))
                when Plan::Op::Pow, Plan::Op::Max
                  sum(moments(op.a, values, memo), moments(op.b, values, memo))
                when Plan::Op::Copy
                  moments(op.a, values, memo)
                when Plan::Op::Shape
                  ma = moments(op.a, values, memo)
                  op.shaper.antialias ? shift(ma, 0.5) : ma
                when Op::Svf
                  ma = moments(op.a, values, memo)
                  svf_latency(op, ma, values)
                else
                  ZERO
                end
            memo[v] = m
          end

          # A lowpass SVF's group delay at DC is 1 / (2 g Q) samples (g =
          # tan(pi fc / rate)); an allpass's twice that.  Other types count
          # as no latency (their phase at the loop's low frequencies is
          # small or their DC gain is zero).
          def svf_latency(op, m, values)
            return m if m.equal?(ZERO)

            factor = case op.filter.filter_type
                     when :lowpass then 1.0
                     when :allpass then 2.0
                     else return m
                     end
            fc = value_of(op.cutoff, values)
            q = value_of(op.quality, values)
            rate = op.filter.sample_rate.to_f
            g = fc.is_a?(Numo::NArray) ? Numo::NMath.tan(Numo::DFloat.cast(fc).clip(1.0, rate * 0.49) * (Math::PI / rate)) : Math.tan(fc.to_f.clamp(1.0, rate * 0.49) * Math::PI / rate)
            q = q.is_a?(Numo::NArray) ? Numo::DFloat.cast(q).clip(1e-10, Float::INFINITY) : [q.to_f, 1e-10].max
            shift(m, (g * q * 2.0).then { |x| x.is_a?(Numo::NArray) ? factor / x : factor / x })
          end

          # The value of +v+ for the latency estimate: a Const, a boundary
          # input's or param's block data, or arithmetic on those inside a
          # node's description (e.g. a Multiplier's constant times an input,
          # before it multiplies the loop's signal), in double precision.
          def value_of(v, values, memo = nil)
            case v
            when Plan::Const then v.parts[0]
            when Plan::Value
              op = v.op
              if op.is_a?(Plan::Op::Input) || op.is_a?(Plan::Op::Param)
                @lat_record << v if @lat_record
                x = values[v]
                raise "No value for #{v} in the latency estimate" if x.nil?
                return x.is_a?(Numo::NArray) ? Numo::DFloat.cast(x) : x
              end

              memo ||= {}.compare_by_identity
              return memo[v] if memo.key?(v)

              memo[v] = case op
                        when Plan::Op::Fill then op.value.parts[0]
                        when Plan::Op::Copy then value_of(op.a, values, memo)
                        when Plan::Op::Mul then value_of(op.a, values, memo) * value_of(op.b, values, memo)
                        when Plan::Op::Add then value_of(op.a, values, memo) + value_of(op.b, values, memo)
                        when Plan::Op::Div then value_of(op.a, values, memo) / value_of(op.b, values, memo)
                        when Plan::Op::Pow
                          a = value_of(op.a, values, memo)
                          b = value_of(op.b, values, memo)
                          a.is_a?(Numo::NArray) || b.is_a?(Numo::NArray) ? Numo::DFloat.cast(a)**b : a**b
                        else
                          1.0 # (a loop value as a gain: no estimate)
                        end
            else
              v.to_f
            end
          end

          def inverse(x)
            x.is_a?(Numo::NArray) ? 1.0 / x : (x == 0 ? 0.0 : 1.0 / x)
          end

          def scale(m, k)
            k = Numo::DFloat.cast(k) if k.is_a?(Numo::NArray)
            m.map { |x| x * k }
          end

          def sum(a, b)
            return a if b.equal?(ZERO)
            return b if a.equal?(ZERO)

            a.zip(b).map { |x, y| x + y }
          end

          # Delays moments by +d+ samples (m1 += d m0).
          def shift(m, d)
            [m[0], m[1] + m[0] * d, m[2], m[3] + m[2] * d]
          end

          def add(a, b)
            a + b
          end

          # m1 / m0, or 0 where m0 is 0.
          def ratio(m0, m1)
            if m0.is_a?(Numo::NArray) || m1.is_a?(Numo::NArray)
              m0 = Numo::DFloat.cast(m0.is_a?(Numo::NArray) ? m0 : Numo::DFloat[m0])
              m1 = Numo::DFloat.cast(m1.is_a?(Numo::NArray) ? m1 : Numo::DFloat[m1])
              r = m1 / m0
              r[m0.eq(0)] = 0.0 if m0.eq(0).any?
              r
            else
              m0 == 0 ? 0.0 : m1 / m0
            end
          end
        end
      end
    end
  end
end
