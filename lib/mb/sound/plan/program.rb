module MB
  module Sound
    module Plan
      # A described plan: its ops (in order), boundary inputs, Constant
      # params, and output Value.  Prints as a listing (#to_s), runs in C
      # (#run, through MB::Sound::FastPlan.run on the lowered form) or in
      # Ruby (#run_ruby, each op's exact mirror).
      #
      # Lowering gives every Value a register: boundary inputs and changing
      # params point at their buffers, the output at the caller's buffer,
      # and everything else at a scratch slot, reused once the value is dead
      # (linear scan; an op's destination never shares a slot with its own
      # operands, so ops may read any operand sample after writing).
      class Program
        # Register kinds and opcodes of the C executor (see fast_plan.c;
        # specs compare them with FastPlan.constants).
        REG_KINDS = { slot: 0, input: 1, param: 2, out: 3 }.freeze
        OPCODES = { fill: 1, mul: 2, muls: 3, add: 4, adds: 5, div: 6, divs: 7, pow: 8, part: 9, tone: 10, copy: 11, shape: 12, note_freq: 13, events: 14, keep: 15, envelope: 16, smooth: 17, max: 18, powf: 19, svf: 20, four_pole: 21, biquad: 22 }.freeze

        attr_reader :ops, :inputs, :params, :output

        # A title for listings (e.g. the region's root node).
        attr_accessor :title

        # +ops+ from a Builder (in order), with its +inputs+ (Op::Input) and
        # +params+ (Op::Param), computing +output+ (a Value).
        def initialize(ops:, inputs:, params:, output:, title: nil)
          @ops = ops.freeze
          @inputs = inputs.freeze
          @params = params.freeze
          @output = output
          @title = title
          @lowered = nil
          @scratch = nil
        end

        # Every graph node with ops in this program (excluding boundary
        # inputs), in order.
        def nodes
          @ops.reject { |op| op.is_a?(Op::Input) }.map { |op| op.is_a?(Op::Param) ? op.constant : op.node }.compact.uniq
        end

        # The tone ops.
        def tones
          @ops.grep(Op::Tone)
        end

        # True if every op is bit-exact with its node.
        def exact?
          @ops.all?(&:exact?)
        end

        # The output type, :real or :complex.
        def output_type
          @output.type
        end

        # A listing of the ops, one per line, with the node that described
        # each (registers after lowering).
        def to_s
          lower
          lines = []
          lines << "Plan for #{@title}" if @title
          lines << "  #{@ops.length} ops (#{@inputs.length} inputs, #{@params.length} params), #{@nslots} scratch slots; output #{@output} (#{@output.type})"
          last_node = nil
          @ops.each do |op|
            label = op.node && !op.node.equal?(last_node) && !op.is_a?(Op::Input) ? "  # #{Plan.node_label(op.node)}" : ''
            last_node = op.node unless op.is_a?(Op::Input)
            lines << format('  %-6s %-58s%s', register_name(op.dst), op.to_s, label)
          end
          lines.join("\n")
        end

        def inspect
          "#<#{self.class.name} #{@ops.length} ops, #{@inputs.length} inputs, output #{@output}>"
        end

        # Lowers the ops to the C executor's words (see fast_plan.c):
        # [words (Int32), scalars (DFloat), objects (Array)].  Cached.
        def lower
          @lowered ||= Lowering.new(self).result.tap { |words, _, _, nslots, regs|
            @nslots = nslots
            @registers = regs
          }
        end

        # The register name of +value+ after lowering (for listings).
        def register_name(value)
          lower
          reg = @registers[value]
          return value.to_s unless reg

          kind, idx, _ = reg
          case kind
          when :input then "in#{idx}"
          when :param then "p#{idx}"
          when :out then 'out'
          else "r#{idx}"
          end
        end

        # Runs the program in C for +count+ samples: +inputs+ are the
        # boundary inputs' buffers (in #inputs order; nil for an optional
        # input that ended), +params+ the Constant values or buffers (in
        # #params order), and +out+ an SFloat or SComplex of at least
        # +count+ samples (by #output_type) that receives the output.
        # Returns +out+.
        def run(count, inputs, params, out)
          words, scalars, objects, nslots = lower
          stride = 2 * count
          if nslots > 0 && (@scratch.nil? || @scratch.length < nslots * stride)
            @scratch_stride = [stride, @scratch_stride || 0].max
            @scratch = Numo::SFloat.zeros(nslots * @scratch_stride)
          end
          @scratch ||= Numo::SFloat.zeros(1)
          MB::Sound::FastPlan.run(words, scalars, objects, inputs, params, @scratch, out, count)
        end

        # Runs the program with each op's Ruby mirror for +count+ samples
        # (+inputs+ and +params+ as for #run), returning the output buffer.
        def run_ruby(count, inputs, params)
          env = {}
          @ops.each do |op|
            case op
            when Op::Input
              buf = inputs[op.index]
              env[op.dst] = buf && buf.length > count ? buf[0...count] : buf
            when Op::Param
              v = params[op.index]
              if v.is_a?(Numeric)
                buf = (op.dst.complex? ? Numo::SComplex : Numo::SFloat).new(count)
                buf.fill(v)
                env[op.dst] = buf
              else
                env[op.dst] = v.length > count ? v[0...count] : v
              end
            else
              op.run_ruby(env, count)
            end
          end
          env.fetch(@output)
        end

        # Builds the lowered form (see Program#lower).
        class Lowering
          attr_reader :result

          def initialize(program)
            @program = program
            @scalars = []
            @objects = []
            @regs = {}.compare_by_identity # Value => [kind, index, complex, slot]
            @reg_index = {}.compare_by_identity
            @order = []
            @free = []
            @nslots = 0

            allocate
            words = [@order.length, @nslots]
            @order.each do |v|
              kind, idx, complex, slot = @regs[v]
              words.push(REG_KINDS.fetch(kind), idx, complex ? 1 : 0, slot || -1)
            end
            @program.ops.each { |op| words.concat(encode(op)) }

            @result = [
              Numo::Int32.cast(words),
              Numo::DFloat.cast(@scalars.empty? ? [0.0] : @scalars),
              @objects,
              @nslots,
              @regs.transform_values { |kind, idx, complex, _| [kind, kind == :slot ? @regs_slot_name[idx] : idx, complex] }
            ]
          end

          private

          # Linear-scan register allocation (see the Program description).
          def allocate
            ops = @program.ops
            @reserved = {}.compare_by_identity
            last_use = {}.compare_by_identity
            ops.each_with_index { |op, i| op.operands.each { |v| last_use[v] = i } }
            @regs_slot_name = {}

            ops.each_with_index do |op, i|
              v = op.dst
              case op
              when Op::Input
                define(v, :input, op.index, nil)
              when Op::Param
                # Params are filled before the ops run, so their slots are
                # their own for the whole program
                define(v, :param, op.index, new_slot)
                @reserved[v] = true
              else
                if v.equal?(@program.output)
                  define(v, :out, 0, nil)
                else
                  define(v, :slot, nil, take_slot)
                end
              end

              # Free operands that die here (after the destination is taken)
              op.operands.uniq.each do |o|
                next unless last_use[o] == i
                next if @reserved[o]
                slot = @regs[o]&.last
                @free << slot if slot && !o.equal?(@program.output)
              end

              # A value nobody reads (other than the output) frees its slot
              if !last_use.key?(v) && !v.equal?(@program.output) && !@reserved[v] && (slot = @regs[v].last)
                @free << slot
              end
            end
          end

          def take_slot
            return @free.shift unless @free.empty?

            new_slot
          end

          def new_slot
            @nslots += 1
            @nslots - 1
          end

          def define(v, kind, idx, slot)
            idx = slot if kind == :slot
            @regs_slot_name[slot] = slot if slot
            @regs[v] = [kind, idx, v.complex?, slot]
            @reg_index[v] = @order.length
            @order << v
          end

          def reg(v)
            @reg_index[v] || raise("Value #{v} has no register")
          end

          def scalar(*values)
            @scalars.concat(values.map(&:to_f))
            @scalars.length - values.length
          end

          def const(c)
            scalar(*c.parts)
          end

          def encode(op)
            case op
            when Op::Input, Op::Param
              []
            when Op::Fill
              [OPCODES[:fill], reg(op.dst), const(op.value)]
            when Op::Mul, Op::Add
              name = op.is_a?(Op::Mul) ? :mul : :add
              if op.a.is_a?(Const)
                [OPCODES[:"#{name}s"], reg(op.dst), reg(op.b), const(op.a)]
              elsif op.b.is_a?(Const)
                [OPCODES[:"#{name}s"], reg(op.dst), reg(op.a), const(op.b)]
              else
                [OPCODES[name], reg(op.dst), reg(op.a), reg(op.b)]
              end
            when Op::Div
              if op.b.is_a?(Const)
                [OPCODES[:divs], reg(op.dst), reg(op.a), const(op.b)]
              else
                [OPCODES[:div], reg(op.dst), reg(op.a), reg(op.b)]
              end
            when Op::Pow
              [OPCODES[op.fast ? :powf : :pow], reg(op.dst), reg(op.a), reg(op.b)]
            when Op::Part
              [OPCODES[:part], reg(op.dst), reg(op.a), op.part == :imag ? 1 : 0]
            when Op::Copy
              [OPCODES[:copy], reg(op.dst), reg(op.a), 0]
            when Op::NoteFreq
              @objects << op.tuning
              [OPCODES[:note_freq], reg(op.dst), reg(op.a), @objects.length - 1, op.fast ? 1 : 0]
            when Op::Shape
              sh = op.shaper
              @objects << sh.plan_state
              [OPCODES[:shape], reg(op.dst), reg(op.a), @objects.length - 1,
               scalar(Op::Shape::MODES.fetch(sh.mode), sh.p1, sh.p2, sh.antialias ? 1 : 0)]
            when Op::Tone
              encode_tone(op)
            when Op::Events
              @objects << op.list.data
              [OPCODES[:events], reg(op.dst), @objects.length - 1, 0]
            when Op::Keep
              @objects << [op.target, op.ivar].freeze
              [OPCODES[:keep], reg(op.dst), reg(op.a), @objects.length - 1]
            when Op::Envelope
              encode_envelope(op)
            when Op::Smooth
              @objects << [op.smoother, op.jumps].freeze
              [OPCODES[:smooth], reg(op.dst), reg(op.a), @objects.length - 1]
            when Op::Max
              [OPCODES[:max], reg(op.dst), reg(op.a), reg(op.b)]
            when Op::FilterSvf
              @objects << op.filter
              cnum = ->(v) { v.is_a?(Const) ? v.parts[0] : 0.0 }
              [OPCODES[:svf], reg(op.dst), reg(op.a), value_reg(op.cutoff), value_reg(op.quality), value_reg(op.gain),
               @objects.length - 1, scalar(cnum.(op.cutoff), cnum.(op.quality), cnum.(op.gain), op.gain_input ? 1 : 0)]
            when Op::FilterBiquad
              @objects << op.filter
              [OPCODES[:biquad], reg(op.dst), reg(op.a), reg(op.cutoff), reg(op.quality), @objects.length - 1, op.type_id]
            when Op::FourPole
              @objects << op.filter
              cnum = ->(v) { v.is_a?(Const) ? v.parts[0] : 0.0 }
              [OPCODES[:four_pole], reg(op.dst), reg(op.a), value_reg(op.cutoff), value_reg(op.resonance),
               @objects.length - 1, scalar(*op.settings, cnum.(op.cutoff), cnum.(op.resonance))]
            else
              raise ArgumentError, "No lowering for #{op.class}"
            end
          end

          # See run_tone in fast_plan.c.
          def encode_tone(op)
            tone = op.tone
            state = tone.state
            kernel = op.kernel
            gain, offset = tone.send(:gain_and_offset)
            fade = tone.instance_variable_get(:@fade_band) || [0.0, 0.0]
            wave = kernel == :synth ? Op::Tone::BL_WAVES.fetch(tone.wave_type) : Op::Tone::WAVES.fetch(tone.wave_type)
            width_value = op.width.is_a?(Const) ? op.width.value : nil

            sc = scalar(
              op.frequency.is_a?(Const) ? op.frequency.value : 0,
              op.phase_mod.is_a?(Const) ? op.phase_mod.value : 0,
              width_value || 0.5,
              op.gain.is_a?(Const) ? op.gain.value : 1,
              tone.advance, tone.random_advance, gain, offset, fade[0], fade[1],
              tone.instance_variable_get(:@keep_dc) ? 0 : 1,
              op.width.is_a?(Const) ? 1 : 0,
              op.gain.nil? ? 0 : (op.gain.is_a?(Const) ? 1 : 2),
              op.fast ? 1 : 0
            )

            @objects << [tone, state, op.frequency.is_a?(Const) ? op.frequency.value : nil, width_value].freeze
            [
              OPCODES[:tone], reg(op.dst), @objects.length - 1, Op::Tone::KERNELS.fetch(kernel), wave,
              value_reg(op.frequency), value_reg(op.phase_mod), value_reg(op.width),
              value_reg(op.reset), value_reg(op.target), value_reg(op.gain), sc
            ]
          end

          # See run_envelope in fast_plan.c.  Parameters filled with a
          # constant (an Op::Fill, e.g. a product folded to zero by
          # Plan::Fold) go to the kernel as numbers, as the float the fill
          # writes, so its runs apply (constants of the patch; see
          # mb_envelope.h).
          def encode_envelope(op)
            config = op.config
            nseg = op.times.length
            filled = ->(v) { v.is_a?(Value) && v.real? && v.op.is_a?(Op::Fill) && v.op.value.real? }
            cval = ->(v) {
              if v.is_a?(Const)
                v.value.to_f
              elsif filled.(v)
                Numo::SFloat[v.op.value.parts[0]][0]
              else
                0.0
              end
            }
            value_reg = ->(v) { filled.(v) ? -1 : value_reg(v) }
            sc = scalar(
              *config[0...9], config.length > 9 ? config[9] : -1,
              *op.times.flat_map.with_index { |t, i| [cval.(t), cval.(op.curves[i]), cval.(op.levels[i])] },
              cval.(op.hold),
              *Op::Envelope::INPUTS.map { |k| v = op.inputs[k]; v.nil? ? Op::Envelope::NIL_VALUES[k] : cval.(v) }
            )
            @objects << [op.envelope, op.envelope.plan_state].freeze
            shapes = op.shapes
            words = [OPCODES[:envelope], reg(op.dst), @objects.length - 1, sc, nseg]
            nseg.times do |i|
              words.push(value_reg.(op.times[i]), value_reg.(op.curves[i]), value_reg.(op.levels[i]), shapes[i])
            end
            words.push(value_reg.(op.hold))
            Op::Envelope::INPUTS.each { |k| words.push(value_reg.(op.inputs[k])) }
            words
          end

          def value_reg(v)
            v.is_a?(Value) ? reg(v) : -1
          end
        end
      end
    end
  end
end
