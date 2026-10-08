module MB
  module Sound
    module Plan
      # The operations of a plan (an audio-specific virtual machine's
      # instruction set): each op computes one Value (#dst) from Values and
      # Consts for a whole block of samples.  Ops are plain Ruby objects, so
      # a plan can be listed (Program#to_s), inspected, and tested; the C
      # executor (MB::Sound::FastPlan.run) runs the lowered form (see
      # Program#lower), and #run_ruby is the exact Ruby mirror of each op
      # (Numo arithmetic, or the node's own Ruby kernel).
      #
      # Arithmetic follows Numo (and FastArithmetic, its allocation-free
      # twin): float32 operations in the order the node does them, a Const
      # cast to float32 (or complex float32) as fill casts it, and a real
      # operand promoted to (x, +0.0) when the result is complex, with
      # complex products written out as (ar br - ai bi, ar bi + ai br).
      # So arithmetic ops are bit-exact with the nodes they describe (on
      # platforms where Numo doesn't contract products into FMAs; see
      # fast_arithmetic.c).
      #
      # Every op records the graph node that described it (#node) for
      # listings and errors.
      module Op
        # Base class of ops.
        class Base
          # The Value this op computes.
          attr_reader :dst

          # The graph node whose #plan_describe emitted this op.
          attr_reader :node

          def initialize(dst, node)
            @dst = dst
            @node = node
          end

          # The Values this op reads (Consts aren't listed).
          def operands
            []
          end

          # True if this op gives exactly the samples of the node it
          # describes (all P1 ops; a future vectorized op might claim a
          # tolerance instead, see #tolerance).
          def exact?
            true
          end

          # The largest difference from the node's own output allowed when
          # not #exact? (relative to full scale).
          def tolerance
            0.0
          end

          # The listing line's right-hand side.
          def expression
            raise NotImplementedError
          end

          def to_s
            "#{@dst} = #{expression}"
          end

          def inspect
            "#<#{self.class.name} #{self}>"
          end

          # The opcode name in the C executor (see Program#lower).
          def opcode
            raise NotImplementedError
          end

          private

          # A new NArray for this op's result.
          def result_buffer(count)
            (@dst.complex? ? Numo::SComplex : Numo::SFloat).zeros(count)
          end

          # The buffer of +operand+ (a Value in +env+) or a Const filled
          # into a buffer of +count+ samples of +type+.
          def operand_buffer(env, operand, count, complex)
            if operand.is_a?(Const)
              buf = (complex ? Numo::SComplex : Numo::SFloat).new(count)
              buf.fill(operand.complex? || complex ? Complex(*operand.parts) : operand.parts[0])
            else
              env.fetch(operand)
            end
          end
        end

        # A boundary input: a node outside the region (or one the region
        # mustn't fuse), read through the handles the region's nodes already
        # hold (Tee branches), once per block before the ops run.
        class Input < Base
          # The node read (the origin of the handles).
          attr_reader :source

          # The handles (Tee::Branch objects) the region reads each block;
          # the first gives the data, the others keep the Tee in lockstep.
          attr_reader :handles

          # Why this node is a boundary (for listings).
          attr_reader :reason

          # The input's index in the region's input list.
          attr_reader :index

          # True if the input may end (return nil) without ending the
          # region (e.g. a tone's reset trigger).
          attr_reader :optional

          def initialize(dst, node, source:, handles:, reason:, index:, optional: false)
            super(dst, node)
            @source = source
            @handles = handles
            @reason = reason
            @index = index
            @optional = optional
          end

          def expression
            "input #{@index}#{@optional ? ' (optional)' : ''}: #{Plan.node_label(@source)} [#{@reason}]"
          end

          def opcode
            :input
          end
        end

        # A Constant node's value, read live every block: a steady value is
        # filled into the register, a changing one (timed or smoothed
        # changes) is the Constant's own buffer (see
        # GraphNode::Constant#plan_param).
        class Param < Base
          # The Constant.
          attr_reader :constant

          # The param's index in the region's param list.
          attr_reader :index

          def initialize(dst, node, constant:, index:)
            super(dst, node)
            @constant = constant
            @index = index
          end

          def expression
            "param #{@index}: #{Plan.node_label(@constant)} (#{@constant.value_string})"
          end

          def opcode
            :param
          end
        end

        # A Const filled into every sample.
        class Fill < Base
          attr_reader :value

          def initialize(dst, node, value)
            super(dst, node)
            @value = value
          end

          def expression
            "fill #{@value}"
          end

          def opcode
            :fill
          end

          def run_ruby(env, count)
            env[@dst] = operand_buffer(env, @value, count, @dst.complex?).dup
          end
        end

        # Shared by the two-operand arithmetic ops: +a+ is a Value or Const
        # (Numo's fill(a) then op b, e.g. a Multiplier's constant times its
        # first input), +b+ a Value or a Const (b's fill, e.g. a Mixer's
        # gain).  At most one is a Const.
        class Binary < Base
          attr_reader :a, :b

          def initialize(dst, node, a, b)
            super(dst, node)
            raise ArgumentError, 'An op needs at least one Value operand' if a.is_a?(Const) && b.is_a?(Const)

            @a = a
            @b = b
          end

          def operands
            [@a, @b].grep(Value)
          end

          def expression
            "#{@a} #{symbol} #{@b}"
          end

          # Numo: fill the result with a, then apply the in-place operator
          # with b.
          def run_ruby(env, count)
            out = result_buffer(count)
            out[true] = operand_buffer(env, @a, count, @dst.complex?)
            out.inplace!
            numo(out, @b.is_a?(Const) ? operand_buffer(env, @b, count, @dst.complex?) : env.fetch(@b))
            env[@dst] = out.not_inplace!
          end
        end

        # a * b (Multiplier: the constant times each input in turn; Mixer:
        # the gain times an input).
        class Mul < Binary
          def symbol = '*'
          def opcode = :mul

          def numo(out, b)
            out * b
          end
        end

        # a + b (Mixer: the constant plus each term in turn).
        class Add < Binary
          def symbol = '+'
          def opcode = :add

          def numo(out, b)
            out + b
          end
        end

        # a / b, real only (the / of GraphNode arithmetic: FastArithmetic.divide).
        class Div < Binary
          def symbol = '/'
          def opcode = :div

          def run_ruby(env, count)
            out = Numo::SFloat.zeros(count)
            out[true] = operand_buffer(env, @a, count, false)
            out.inplace!
            b = @b.is_a?(Const) ? @b.value : env.fetch(@b)
            MB::Sound::FastArithmetic.divide(out, b) || (out / b)
            env[@dst] = out.not_inplace!
          end
        end

        # a ** b, real only, both Values (the ** of GraphNode arithmetic:
        # FastArithmetic.power, C's double pow rounded to float32).
        class Pow < Binary
          def symbol = '**'
          def opcode = :pow

          def run_ruby(env, count)
            out = Numo::SFloat.zeros(count)
            out[true] = operand_buffer(env, @a, count, false)
            out.inplace ** env.fetch(@b)
            env[@dst] = out.not_inplace!
          end
        end

        # A copy of a Value (a region whose output is one of its inputs).
        class Copy < Base
          attr_reader :a

          def initialize(dst, node, a)
            super(dst, node)
            @a = a
          end

          def operands
            [@a]
          end

          def expression
            "copy #{@a}"
          end

          def opcode = :copy

          def run_ruby(env, count)
            env[@dst] = env.fetch(@a).dup
          end
        end

        # A waveshaper (GraphNode::Shaper: softclip, clip, abs, quantize,
        # antialiased or plain) on a real Value, with the node's own state
        # Array (the kernel shared with FastClip.shape through
        # mb_clip_shape.h).  Antialiased shapers delay by half a sample
        # (a feedback loop would count that as latency).
        class Shape < Base
          # Mode numbers of the C executor (enum clip_mode).
          MODES = { softclip: 0, clip: 1, abs: 2, quantize: 3 }.freeze

          attr_reader :a, :shaper

          def initialize(dst, node, a, shaper)
            super(dst, node)
            raise Unsupported.new(shaper, 'complex input') if a.complex?

            @a = a
            @shaper = shaper
          end

          def operands
            [@a]
          end

          def expression
            args = case @shaper.mode
                   when :softclip then "#{@shaper.p1}, #{@shaper.p2}"
                   when :clip then "#{@shaper.p1}..#{@shaper.p2}"
                   when :quantize then @shaper.p1.to_s
                   else ''
                   end
            "#{@shaper.antialias ? '' : 'a'}#{@shaper.mode}(#{@a}#{args.empty? ? '' : ", #{args}"})"
          end

          def opcode = :shape

          def run_ruby(env, count)
            env[@dst] = MB::Sound::Shaper.shape_ruby(env.fetch(@a), @shaper.mode, @shaper.p1, @shaper.p2, @shaper.antialias, @shaper.plan_state)
          end
        end

        # The real or imaginary part of a complex Value (ComplexNode).
        class Part < Base
          attr_reader :a, :part

          def initialize(dst, node, a, part)
            super(dst, node)
            raise ArgumentError, "Unknown part #{part.inspect}" unless part == :real || part == :imag

            @a = a
            @part = part
          end

          def operands
            [@a]
          end

          def expression
            "#{@part}(#{@a})"
          end

          def opcode = :part

          def run_ruby(env, count)
            env[@dst] = Numo::SFloat.cast(@part == :real ? env.fetch(@a).real : env.fetch(@a).imag)
          end
        end
      end
    end
  end
end
