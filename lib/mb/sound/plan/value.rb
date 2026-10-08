module MB
  module Sound
    module Plan
      # A signal in a plan: one buffer of float32 samples (real, or complex
      # float32 pairs) computed by an op, read from a boundary input, or
      # read from a Constant.  Values are what nodes work with in
      # #plan_describe: arithmetic operators on them append ops to the plan
      # (see Builder), so a node describes its per-sample work in the same
      # Ruby it would use for the math:
      #
      #     def plan_describe(p)
      #       @multiplicands.keys.reduce(p.const(@constant)) { |product, m| product * p[m] }
      #     end
      #
      # Each operator gives the same float32 results, in the same order, as
      # the Numo (or FastArithmetic) arithmetic of the node it describes,
      # with real operands promoted to (x, +0.0) when the other is complex
      # (see Op).  Lowering (Program#lower) assigns each Value a register.
      class Value
        # :real or :complex.
        attr_reader :type

        # The op that computes this value.
        attr_reader :op

        # A number for listings (assigned in order of creation).
        attr_reader :id

        # The Builder that made this value.
        attr_reader :builder

        # For internal use by Builder: a value of +type+ made by +builder+.
        def initialize(builder, type, id)
          raise ArgumentError, "Unknown value type #{type.inspect}" unless type == :real || type == :complex

          @builder = builder
          @type = type
          @id = id
          @op = nil
        end

        # For internal use by Builder#emit.
        def op=(op)
          raise 'A value is computed by only one op' if @op

          @op = op
        end

        def complex?
          @type == :complex
        end

        def real?
          @type == :real
        end

        # The product (an Op::Mul): self times +other+ (a Value or Numeric).
        def *(other)
          @builder.mul(self, other)
        end

        # The sum (an Op::Add): self plus +other+ (a Value or Numeric).
        def +(other)
          @builder.add(self, other)
        end

        # The quotient (an Op::Div; real values only).
        def /(other)
          @builder.div(self, other)
        end

        # Self to the power of +other+ (an Op::Pow; real values only).
        def **(other)
          @builder.pow(self, other)
        end

        # The real part (an Op::Part; a real value is returned as is).
        def real
          complex? ? @builder.part(self, :real) : self
        end

        # The imaginary part (an Op::Part).
        def imag
          @builder.part(self, :imag)
        end

        # Lets numbers come first: `2 * value`.
        def coerce(numeric)
          [@builder.const(numeric), self]
        end

        def to_s
          "v#{@id}"
        end

        def inspect
          "#<#{self.class.name} #{self} #{@type}>"
        end
      end

      # A number in a plan: a compile-time scalar that ops cast to float32
      # (or complex float32) as Numo's fill does.  Made by Builder#const and
      # by numbers used with Values.
      class Const
        # The Ruby number (Integer, Float, Rational, or Complex).
        attr_reader :value

        # :real or :complex (complex for a Complex value, or when forced so
        # that ops use complex arithmetic, as a promoted node buffer does).
        attr_reader :type

        # The Builder that made this constant.
        attr_reader :builder

        def initialize(builder, value, complex: false)
          raise ArgumentError, "A plan constant must be a Numeric (got #{value.inspect})" unless value.is_a?(Numeric)

          @builder = builder
          @value = value
          @type = complex || value.is_a?(Complex) ? :complex : :real
        end

        def complex?
          @type == :complex
        end

        def real?
          @type == :real
        end

        # [real part, imaginary part] as Floats.
        def parts
          v = @value
          v.is_a?(Complex) ? [v.real.to_f, v.imag.to_f] : [v.to_f, 0.0]
        end

        def *(other)
          @builder.mul(self, other)
        end

        def +(other)
          @builder.add(self, other)
        end

        def to_s
          v = @value
          s = v.is_a?(Float) ? format('%.7g', v) : v.to_s
          s = "(#{s})" if v.is_a?(Complex)
          complex? && !v.is_a?(Complex) ? "#{s}+0i" : s
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end
      end
    end
  end
end
