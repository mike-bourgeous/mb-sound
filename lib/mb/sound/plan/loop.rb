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
      #   built from nodes, `sig.feedback { |fb, input| input + (fb - input) * 0.1 }`).
      # - Op::DelayRead / a ring write: a Filter::Delay node (`fb.delay(t)`)
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
      # it.  That's the `compensate: :dc` mode; the default (`:pitch`,
      # Program#pitch_latency, user decision 2026-10-09) uses the loop's
      # phase delay at the fundamental 1 / T instead, from each op's complex
      # response (delays e^(-iwd), gains, antialiased shapers' half sample,
      # SVFs' exact response), evaluated at every 16th sample of the stream
      # in scalar Ruby (the same bits at any block split) and ramped between
      # those points; the DC estimate unwraps the phase and gives the sign
      # of the loop gain (a negative gain is a polarity, not a delay), and
      # linear-phase loops keep the exact DC value.  The same points give
      # the sustain shelf's gains (FeedbackLoop's `sustain:`,
      # Program#pitch_track).
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

          # A per-block value the FeedbackLoop computes for the sustain shelf
          # (see Program#pitch_track): the shelf's dry gain (:gain), its
          # lowpass gain (:rest), or its lowpass cutoff (:cutoff).
          class SustainParam < Plan::Op::Param
            attr_reader :role

            def initialize(dst, node, role:, index:)
              super(dst, node, constant: nil, index: index)
              @role = role
            end

            def expression = "sustain #{@role} (param #{@index})"
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

          # True for the delay whose time sets the loop's pitch (1 / its
          # time) for the latency at the pitch and for sustain: the
          # compensated delay, or the longest delay without compensation.
          attr_accessor :pitched

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

          # A value FeedbackLoop sets every block (see Op::SustainParam).
          def sustain_param(role)
            op = Op::SustainParam.new(value(:real), node, role: role, index: @params.length)
            @params << op
            emit(op)
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

          # The sustain shelf (see #pitch_track), or nil: a Hash with the
          # shelf's :input and :output Values, its :filter (the hidden
          # lowpass Filter::SVF), and its :gain, :rest, and :cutoff params.
          attr_reader :sustain

          # The ring whose time sets the loop's pitch (see Ring#pitched).
          attr_reader :pitch_ring

          # The shelf's gain at the pitch (the sustain boost or cut) at the
          # last point #pitch_track evaluated (1.0 before or without sustain).
          attr_reader :sustain_ratio

          def initialize(ops:, inputs:, params:, rings:, histories:, output:, history:, title: nil, sustain: nil)
            @sustain = sustain
            @sustain_ratio = 1.0
            @ops = ops.freeze
            @inputs = inputs.freeze
            @params = params.freeze
            @rings = rings.freeze
            @histories = histories.freeze
            @output = output
            @history = history
            @title = title
            @compensated = @rings.find(&:compensated)
            @pitch_ring = @rings.find(&:pitched) || @compensated
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
            return 0.0 unless @pitch_ring

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
              @lat_hit = same
              return @lat_value if same
            end
            @lat_hit = false

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

          # Samples between the points where #pitch_track evaluates the
          # loop's response at the pitch (it ramps linearly between points).
          PITCH_STEP = 16

          # The sustain shelf's lowpass cutoff as a fraction of the pitch
          # (see #pitch_track; chosen 2026-10-09 by simulating KS strings at
          # 55 Hz to 3.5 kHz: shelves at 0.7 and 0.85 of the pitch were stable
          # up to boosts of 2.0 and 2.3, 0.35 only to 1.5).
          SUSTAIN_SHELF = 0.85

          # The shelf lowpass's quality (critically damped: no peak).
          SUSTAIN_SHELF_Q = 0.5

          # The largest sustain boost (the shelf's high gain, about +6 dB):
          # a lowpass whose loss at the pitch needs more (a cutoff below
          # about 0.6 times the pitch) shortens the ring again.  Larger
          # boosts make the shelf's transition ring on its own (a mode below
          # the pitch, where the loop's delay phase meets the shelf's phase
          # lead) and grow without bound (2.6 did at every pitch tested).
          SUSTAIN_MAX = 2.0

          # Points of #pitch_track between evaluations of the sustain
          # stretch (Program#sustain_stretch, the costliest part; it changes
          # slowly): every 64 samples of the stream.
          STRETCH_EVERY = 4

          # The smallest sustain gain (a flat cut where the filters have
          # gain above 1 at the pitch, e.g. a resonant peak there).
          SUSTAIN_MIN = 1.0 / 64

          # The loop's latency apart from the pitch delay at the played
          # pitch (see Loop), and the sustain shelf's gains when the loop
          # has one: [latency, gain, rest].  The latency is the phase delay
          # of the rest of the loop at the loop's fundamental 1 / T (T the
          # pitch delay's time), so the fundamental is exactly 1 / T even
          # where the filters' phase delay at the pitch differs from their
          # group delay at DC.
          #
          # Sustain (FeedbackLoop's `sustain: true`): the shelf y = gain x +
          # rest lowpass(x) on the pitch delay's input makes the loop's gain
          # at the pitch what it would be with every SVF on the loop
          # replaced by a wire, so the fundamental rings as long as the
          # loop's other gains say whatever the filters do there.  A boost
          # (filters losing gain at the pitch) is a high shelf (gain s, rest
          # 1 - s, lowpass at SUSTAIN_SHELF times the pitch) so DC and the
          # lowest frequencies keep their loop gain: a flat boost would make
          # the loop's DC mode grow (a lowpass passes DC at full gain).  The
          # shelf's gain at the pitch is solved exactly, its phase there is
          # part of the latency, and s is limited to SUSTAIN_MAX.  Boosts
          # only make up for lowpass shapes (every SVF on the loop a lowpass
          # with a quality up to 1 / sqrt(2) at that point, and joining paths
          # filtered alike): other filters
          # can have more gain at the harmonics than at the pitch, so a
          # boost would make those grow.  A cut (filter gain above 1 at the
          # pitch, e.g. a resonant lowpass there) is flat (gain r, rest 0).
          #
          # Evaluated at every PITCH_STEP-th sample of the stream (so the
          # result is the same at any block size), ramping linearly from the
          # previous point's values over the next PITCH_STEP samples; Floats
          # while they hold still (exactly the values at the pitch), DFloats
          # per sample while they ramp.  +count+ is the block's length.
          #
          # Runs in C (FastLoop.pitch_track, see loop_pitch.rb) unless the
          # plan engine is :ruby; #pitch_track_ruby is its exact mirror.
          def pitch_track(values, count)
            return pitch_track_ruby(values, count) if Plan.engine == :ruby

            pitch_track_c(values, count)
          end

          # The Ruby version of #pitch_track (the mirror of the C kernel).
          def pitch_track_ruby(values, count)
            return [0.0, 1.0, 0.0] unless @pitch_ring

            pos = @pitch_pos || 0
            dc = latency(values)
            t = @pitch_ring.last_delay
            first = (-pos) % PITCH_STEP
            m = first < count ? (count - 1 - first) / PITCH_STEP + 1 : 0

            # Nothing moved since the last evaluation: the held values
            if @pitch_b && @pitch_a == @pitch_b && @lat_hit && !t.is_a?(Numo::NArray) && t == @pitch_t
              @pitch_pos = pos + count
              return @pitch_b
            end

            lp = []
            if m > 0
              idx = Numo::Int64.new(m).seq(first, PITCH_STEP)
              lp = pitch_points(values, idx, t, dc, pos)
              @pitch_a ||= lp[0]
              @pitch_b ||= lp[0]
            end
            @pitch_t = t.is_a?(Numo::NArray) ? nil : t

            a = @pitch_a
            b = @pitch_b
            if lp.all? { |x| x == b } && a == b
              @pitch_pos = pos + count
              return b
            end

            # Sample i is in segment j (0 before the block's first point),
            # ramping from chain[j] to chain[j + 1]
            i = Numo::Int64.new(count).seq
            j = (i - first) / PITCH_STEP + 1
            j[i.lt(first)] = 0 if first > 0
            frac = Numo::DFloat.cast((i + pos) % PITCH_STEP) / PITCH_STEP
            pts = [a, b, *lp]
            out = Array.new(b.length) do |k|
              chain = Numo::DFloat.cast(pts.map { |p| p[k] })
              ca = chain[j]
              frac * (chain[j + 1] - ca) + ca
            end
            a, b = m > 0 ? [pts[m], pts[m + 1]] : [a, b]
            @pitch_a = a
            @pitch_b = b
            @pitch_pos = pos + count
            out
          end

          # The sustain shelf's lowpass cutoff in Hz for the pitch delay's
          # time +t+ in samples (a Float or a DFloat).
          def sustain_cutoff(t)
            SUSTAIN_SHELF * @sustain[:filter].sample_rate.to_f / t
          end

          private

          # [latency, gain, rest] at the samples +idx+ of the block (see
          # #pitch_track): the latency unwrapped toward the group delay at
          # DC +dc+.  Each point runs the same scalar code
          # (#response_program), so the result doesn't depend on where
          # blocks split or on whether an input moved.
          def pitch_points(values, idx, t, dc, pos = 0)
            list, oa, ob = response_program
            # Values at the points: Arrays where they move, Floats where
            # they hold (read by point number)
            pts = ->(x) { x.is_a?(Numo::NArray) ? Numo::DFloat.cast(x[idx]).to_a : x.to_f }
            at = ->(x, j) { x.is_a?(Array) ? x[j] : x }

            # Per-block values of each entry's parameters
            params = list.map { |e|
              case e[0]
              when :delay then pts.call(e[3].last_delay)
              when :scale then pts.call(value_of(e[3], values).then { |x| e[4] ? inverse(x) : x })
              when :svf
                op = e[3]
                [value_of(op.cutoff, values), value_of(op.quality, values), op.gain.nil? ? 1.0 : value_of(op.gain, values)].map(&pts)
              end
            }
            t = pts.call(t)
            dc = pts.call(dc)
            gain = pts.call(@lat_gain)
            twopi = 2 * Math::PI

            Array.new(idx.length) do |i|
              ti = at.call(t, i)
              w = twopi / ti
              dcp = at.call(dc, i)
              next [dcp, 1.0, 0.0] if oa.nil? || ob.nil?

              rr, ri = loop_response(list, params, at, i, w, oa, ob, true)
              next [dcp, 1.0, 0.0] if rr.nil?

              g1 = 1.0
              g2 = 0.0
              if @sustain
                # The stretch (every STRETCH_EVERY points of the stream, from
                # the shelf for the previous stretch)
                g1, g2, hr, hi, m0 = sustain_point(list, params, at, i, w, ti, oa, ob, rr, ri, @stretch || 1.0)
                if !(g1 == 1.0 && g2 == 0.0) && (@stretch.nil? || ((pos + idx[i]) / PITCH_STEP) % STRETCH_EVERY == 0)
                  @stretch = sustain_stretch(list, params, at, i, w, ti, oa, ob, g1, g2, rr, ri, hr, hi, dcp, at.call(gain, i) < 0)
                  g1, g2, hr, hi = sustain_point(list, params, at, i, w, ti, oa, ob, rr, ri, @stretch, m0)
                end
                rr, ri = rr * hr - ri * hi, rr * hi + ri * hr
              end

              if @history
                cr = Math.cos(w); ci = -Math.sin(w)
                rr, ri = rr * cr - ri * ci, rr * ci + ri * cr
              end

              # A negative loop gain is a polarity, not a delay: measure
              # the phase against the sign of the loop gain at DC (from
              # #latency's moments)
              if at.call(gain, i) < 0
                rr = -rr
                ri = -ri
              end

              arg = Math.atan2(ri, rr)
              l = (((w * dcp + arg) / twopi).round * twopi - arg) / w

              # Linear-phase loops (delays, averages, shapers) have the same
              # delay at every frequency: keep the exact DC value there
              [(l - dcp).abs < 1e-9 ? dcp : l, g1, g2]
            end
          end

          # The loop's response (real and imaginary parts) at +w+ radians
          # per sample apart from the pitch delay, at point +i+, or nil
          # without a path; with +svf+ false every SVF counts as a wire.
          def loop_response(list, params, at, i, w, oa, ob, svf)
            n = list.length
            ar = (@resp_ar ||= []); ai = (@resp_ai ||= [])
            br = (@resp_br ||= []); bi = (@resp_bi ||= [])
            ha = (@resp_ha ||= []); hb = (@resp_hb ||= [])
            if ar.length != n
              [ar, ai, br, bi].each { |x| x.replace(Array.new(n, 0.0)) }
              [ha, hb].each { |x| x.replace(Array.new(n, false)) }
            end

            list.each_with_index do |e, k|
              case e[0]
              when :one_a
                ar[k] = 1.0; ai[k] = 0.0; ha[k] = true; hb[k] = false
              when :one_b
                br[k] = 1.0; bi[k] = 0.0; hb[k] = true; ha[k] = false
              when :add
                x = e[2]; y = e[3]
                ha[k] = ha[x] || ha[y]
                hb[k] = hb[x] || hb[y]
                ar[k] = (ha[x] ? ar[x] : 0.0) + (ha[y] ? ar[y] : 0.0)
                ai[k] = (ha[x] ? ai[x] : 0.0) + (ha[y] ? ai[y] : 0.0)
                br[k] = (hb[x] ? br[x] : 0.0) + (hb[y] ? br[y] : 0.0)
                bi[k] = (hb[x] ? bi[x] : 0.0) + (hb[y] ? bi[y] : 0.0)
              else
                x = e[2]
                case e[0]
                when :scale
                  cr = at.call(params[k], i); ci = 0.0
                when :copy
                  cr = 1.0; ci = 0.0
                when :delay
                  ph = w * at.call(params[k], i)
                  cr = Math.cos(ph); ci = -Math.sin(ph)
                when :half
                  cr = Math.cos(w * 0.5); ci = -Math.sin(w * 0.5)
                when :svf
                  if svf
                    fc, q, g = params[k]
                    cr, ci = svf_point(e[3], at.call(fc, i), at.call(q, i), at.call(g, i), w)
                  else
                    cr = 1.0; ci = 0.0
                  end
                end
                ha[k] = ha[x]; hb[k] = hb[x]
                ar[k] = ar[x] * cr - ai[x] * ci; ai[k] = ar[x] * ci + ai[x] * cr
                br[k] = br[x] * cr - bi[x] * ci; bi[k] = br[x] * ci + bi[x] * cr
              end
            end
            return nil unless ha[oa] && hb[ob]

            [ar[oa] * br[ob] - ai[oa] * bi[ob], ar[oa] * bi[ob] + ai[oa] * br[ob]]
          end

          # The sustain shelf at point +i+ (see #pitch_track): [gain, rest,
          # the shelf's response at +w+ (real, imaginary)], from the loop's
          # response +rr+, +ri+ there (with its SVFs).
          # +stretch+ raises the unfiltered loop gain to that power (see
          # #sustain_stretch).
          # (+m0+, the unfiltered loop gain at the pitch, is returned last
          # and may be passed back to skip its computation.)
          def sustain_point(list, params, at, i, w, t, oa, ob, rr, ri, stretch = 1.0, m0 = nil)
            m = Math.hypot(rr, ri)
            unless m0
              r0, i0 = loop_response(list, params, at, i, w, oa, ob, false)
              m0 = r0 ? Math.hypot(r0, i0) : 0.0
            end
            return [1.0, 0.0, 1.0, 0.0, m0] unless m0 > 1e-12 && m > 0 && m.finite?

            r = m0**stretch / m
            if r <= 1
              # A flat cut
              r = SUSTAIN_MIN if r < SUSTAIN_MIN
              @sustain_ratio = r
              return [r, 0.0, r, 0.0, m0]
            end

            # Only lowpass shapes are made up for: a filter with more gain
            # above the pitch than at it (a highpass, bandpass, notch, peak
            # cut, a resonant lowpass, or a filtered path mixed with an
            # unfiltered one) would push the harmonics above unity
            # (measured: highpasses, bandpasses, notches, peak cuts, and
            # mixed paths near the pitch grew without bound when boosted)
            if harmonic_risk?(list, params, at, i)
              @sustain_ratio = 1.0
              return [1.0, 0.0, 1.0, 0.0, m0]
            end

            # A high shelf: |s (1 - lp) + lp| = r at the pitch
            lr, li = svf_response(0, sustain_cutoff(t), SUSTAIN_SHELF_Q, 1.0, @sustain[:filter].sample_rate.to_f, w)
            xr = 1.0 - lr; xi = -li
            qa = xr * xr + xi * xi
            qb = 2.0 * (xr * lr + xi * li)
            qc = lr * lr + li * li - r * r
            s = (-qb + Math.sqrt(qb * qb - 4.0 * qa * qc)) / (2.0 * qa)

            s = SUSTAIN_MAX if s > SUSTAIN_MAX
            s = 1.0 if s < 1.0

            hr = s * xr + lr
            hi = s * xi + li
            @sustain_ratio = Math.hypot(hr, hi)
            [s, 1.0 - s, hr, hi, m0]
          end

          # The ratio of the loop's group delay at the pitch to its period
          # +t+, with the shelf (+g1+, +g2+) in it: a mode's envelope decays
          # by the loop gain once per group delay, not per period, so the
          # gain to aim for is the unfiltered gain to this power (a lowpass
          # at the pitch delays the envelope by about a fifth of a period:
          # without this its strings rang 4% longer at 110 Hz and about 15%
          # at 1760 Hz).  The group delay is a central difference of the
          # phase at w (1 +/- 1e-4); limited to 0.5..4.
          def sustain_stretch(list, params, at, i, w, t, oa, ob, g1, g2, rr, ri, hr, hi, dcp, negative)
            rate = @sustain[:filter].sample_rate.to_f
            fc = sustain_cutoff(t)
            # The response with the shelf and history at +wx+ (block-local
            # names: until 2026-10-10 this lambda assigned the method's rr,
            # ri, hr, hi, so the phase below came from w - h with the shelf
            # applied twice; fixed by the user's decision, with the kernel)
            resp = ->(wx) {
              xr, xi = loop_response(list, params, at, i, wx, oa, ob, true)
              lr, li = svf_response(0, fc, SUSTAIN_SHELF_Q, 1.0, rate, wx)
              sr = g1 + g2 * lr; si = g2 * li
              xr, xi = xr * sr - xi * si, xr * si + xi * sr
              if @history
                cr = Math.cos(wx); ci = -Math.sin(wx)
                xr, xi = xr * cr - xi * ci, xr * ci + xi * cr
              end
              [xr, xi]
            }
            h = w * 1e-4
            ar, ai = resp.call(w + h)
            br, bi = resp.call(w - h)
            gd = -Math.atan2(ai * br - ar * bi, ar * br + ai * bi) / (2 * h)

            rr, ri = rr * hr - ri * hi, rr * hi + ri * hr
            if @history
              cr = Math.cos(w); ci = -Math.sin(w)
              rr, ri = rr * cr - ri * ci, rr * ci + ri * cr
            end
            if negative
              rr = -rr
              ri = -ri
            end
            twopi = 2 * Math::PI
            arg = Math.atan2(ri, rr)
            phase = (((w * dcp + arg) / twopi).round * twopi - arg) / w

            ((t - phase + gd) / t).clamp(0.5, 4.0)
          end

          # True when an SVF on the loop could have more gain above the
          # pitch than at it (anything but a lowpass with a quality up to
          # 1 / sqrt(2), whose gain falls monotonically).
          def harmonic_risk?(list, params, at, i)
            return true if uneven_filters?(list)

            list.each_with_index.any? { |e, k|
              next false unless e[0] == :svf

              e[3].filter.filter_type != :lowpass || at.call(params[k][1], i) > 0.7072
            }
          end

          # True when paths that join on the loop went through different
          # SVFs (e.g. a filtered and a dry signal mixed): the filters'
          # response is then no product of lowpasses and may rise again
          # (measured: half a lowpass at a quarter of the pitch plus half
          # the dry signal grew when boosted).
          def uneven_filters?(list)
            return @uneven_filters unless @uneven_filters.nil?

            sets = []
            uneven = false
            list.each_with_index do |e, k|
              sets[k] = case e[0]
                        when :one_a, :one_b then []
                        when :svf then (sets[e[2]] + [e[3]]).sort_by(&:object_id)
                        when :add
                          a = sets[e[2]]; b = sets[e[3]]
                          uneven ||= a.map(&:object_id) != b.map(&:object_id)
                          a
                        else sets[e[2]]
                        end
            end
            @uneven_filters = uneven
          end

          # An SVF's response at +w+ for a type id, cutoff, quality, and gain
          # (as #svf_point, without the cache).
          def svf_response(type_id, fc, q, gain, rate, w)
            g, k, _, m0, m1, m2 = Filter::SVF.coefficients(type_id, fc, q, gain, rate)
            si = Math.tan(w * 0.5) / g
            nr = m2; ni = m1 * si
            dr = 1.0 - si * si; di = k * si
            den = dr * dr + di * di
            [(nr * dr + ni * di) / den + m0, (ni * dr - nr * di) / den]
          end

          # The loop's response at the pitch as a list of scalar steps, in
          # an order where sources come first: [list, a slot of the
          # output, b slot of the compensated delay's input] (slots nil
          # where there is no path).  Like #moments, a is relative to the
          # compensated delay's output, b to the loop variable.
          def response_program
            @response_program ||= begin
              list = []
              memo = {}.compare_by_identity
              build = nil
              emit = ->(e) { list << e; list.length - 1 }
              build = lambda do |v|
                next nil unless v.is_a?(Plan::Value)
                next memo[v] if memo.key?(v)

                memo[v] = nil # breaks cycles through uncompensated delays
                next memo[v] = build.call(@sustain[:input]) if @sustain && v.equal?(@sustain[:output])

                op = v.op
                r = case op
                    when Op::DelayRead
                      if op.ring.equal?(@pitch_ring)
                        emit.call([:one_a, nil])
                      else
                        x = build.call(op.ring.input)
                        x && emit.call([:delay, nil, x, op.ring])
                      end
                    when Op::LoopHistory, Op::LoopOutput
                      emit.call([:one_b, nil])
                    when Plan::Op::Mul
                      x = build.call(op.a)
                      y = build.call(op.b)
                      if x && y then emit.call([:add, nil, x, y])
                      elsif x then emit.call([:scale, nil, x, op.b, false])
                      elsif y then emit.call([:scale, nil, y, op.a, false])
                      end
                    when Plan::Op::Div
                      x = build.call(op.a)
                      y = build.call(op.b)
                      if x && !y then emit.call([:scale, nil, x, op.b, true])
                      elsif x && y then emit.call([:add, nil, x, y])
                      else y
                      end
                    when Plan::Op::Add, Plan::Op::Pow, Plan::Op::Max
                      x = build.call(op.a)
                      y = build.call(op.b)
                      x && y ? emit.call([:add, nil, x, y]) : (x || y)
                    when Plan::Op::Copy
                      build.call(op.a)
                    when Plan::Op::Shape
                      x = build.call(op.a)
                      x && op.shaper.antialias ? emit.call([:half, nil, x]) : x
                    when Op::Svf
                      x = build.call(op.a)
                      x && emit.call([:svf, nil, x, op])
                    end
                memo[v] = r
              end
              oa = build.call(@output)
              ob = build.call(@pitch_ring.input)
              [list.freeze, oa, ob]
            end
          end

          # The SVF's response (real and imaginary parts) at +w+ radians per
          # sample for a cutoff, quality, and gain (Filter::SVF#response),
          # with the last point's coefficients reused while they hold.
          def svf_point(op, fc, q, gain, w)
            c = (@svf_coefs ||= {}.compare_by_identity)[op]
            unless c && c[0] == fc && c[1] == q && c[2] == gain
              f = op.filter
              c = [fc, q, gain, *Filter::SVF.coefficients(f.instance_variable_get(:@type_id), fc, q, gain, f.sample_rate.to_f)]
              @svf_coefs[op] = c
            end
            g = c[3]; k = c[4]; m0 = c[6]; m1 = c[7]; m2 = c[8]

            # s = (1 - z^-1) / (g (1 + z^-1)) = i tan(w / 2) / g
            sr = 0.0
            si = Math.tan(w * 0.5) / g
            # (m1 s + m2) / (s^2 + k s + 1) + m0
            nr = m1 * sr + m2; ni = m1 * si
            dr = sr * sr - si * si + k * sr + 1.0; di = 2.0 * sr * si + k * si
            den = dr * dr + di * di
            [(nr * dr + ni * di) / den + m0, (ni * dr - nr * di) / den]
          end

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
            din = moments(@pitch_ring.input, values, memo)
            a = ratio(out[0], out[1])
            b = ratio(din[2], din[3])
            @lat_gain = out[0] * din[2]
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
            # The sustain shelf counts as no latency (its phase at the pitch
            # is in #pitch_track)
            return memo[v] = moments(@sustain[:input], values, memo) if @sustain && v.equal?(@sustain[:output])

            op = v.op
            m = case op
                when Op::DelayRead
                  if op.ring.equal?(@pitch_ring)
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

            # Every parameter counts as a dependency (#pitch_track evaluates
            # every type's response at the pitch while any of them moves)
            value_of(op.gain, values) if @lat_record && op.gain.is_a?(Plan::Value)
            fc = value_of(op.cutoff, values)
            q = value_of(op.quality, values)
            factor = case op.filter.filter_type
                     when :lowpass then 1.0
                     when :allpass then 2.0
                     else return m
                     end
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
