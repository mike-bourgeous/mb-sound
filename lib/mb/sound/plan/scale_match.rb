module MB
  module Sound
    module Plan
      # Lets regions that differ only by constant gains on some values run
      # together in a LaneGroup: `x` and `x * c` are treated as the same
      # shape (the maintainer's P3b note, 2026-10-10: "treat x and x * 1
      # (sign-only differences like stereo_drone's noise * -1) as the same
      # shape so such channels can group").  A region whose program lacks a
      # gain another member has gets `x * 1` inserted at that place (#pad),
      # exact for every float (x * 1.0f is x, signed zeros, infinities, and
      # NaNs included), so its programs then lower to the same words and
      # differ only in that scalar.
      #
      # A gain here is an Op::Mul of a Value by a real Const whose operand
      # is read by nothing else (so `x * c` replaces x in the program).
      # The core of a program is its ops with these gains left out; two
      # programs with the same core (#core's key) can be padded to the same
      # shape.  LaneGroups#refresh pads, then groups by the real signature,
      # so a mismatch the key doesn't see only costs the grouping.
      module ScaleMatch
        # Returns [key, sites] for +program+: +key+ describes its core
        # (each op's class, opcode, operand positions, and type, plus the
        # output), and +sites+ a Hash of core op index => the number of
        # gains applied to that op's value.
        def self.core(program)
          ops = program.ops
          uses = Hash.new(0).compare_by_identity
          ops.each { |op| op.operands.each { |v| uses[v] += 1 } }
          uses[program.output] += 1

          alias_of = {}.compare_by_identity
          producer = {}.compare_by_identity
          sites = Hash.new(0)
          desc = []
          resolve = ->(v) { v = alias_of[v] while alias_of.key?(v); v }

          ops.each do |op|
            x = gain_operand(op, uses)
            if x
              x = resolve.(x)
              k = producer[x]
              if k
                alias_of[op.dst] = x
                sites[k] += 1
                next
              end
            end

            desc << [op.class, op.opcode, op.operands.map { |v| producer[resolve.(v)] }, op.dst.type, op.is_a?(Op::Binary) ? [op.a.class, op.b.class] : nil]
            producer[op.dst] = desc.length - 1
          end

          out = resolve.(program.output)
          [[desc, producer[out], out.type, program.output.type], sites]
        end

        # The Value of +op+ scaled by a gain (see the module description),
        # or nil.
        def self.gain_operand(op, uses)
          return nil unless op.instance_of?(Op::Mul)

          a, b = op.a, op.b
          x, c = a.is_a?(Const) ? [b, a] : [a, b]
          return nil unless c.is_a?(Const) && c.real? && x.is_a?(Value)
          return nil unless uses[x] == 1
          return nil unless x.real? && op.dst.real? # (x * 1 is exact for real floats only)

          x
        end

        # A new Program from +program+ with `x * 1` after the core ops listed
        # in +pads+ (core op index => count), every later read of x reading
        # the product instead.  The ops are +program+'s own (changed in
        # place: call this only on a freshly compiled program).
        def self.pad(program, pads)
          return program if pads.nil? || pads.empty?

          ops = program.ops
          uses = Hash.new(0).compare_by_identity
          ops.each { |op| op.operands.each { |v| uses[v] += 1 } }
          uses[program.output] += 1

          alias_of = {}.compare_by_identity
          producer = {}.compare_by_identity
          subst = {}.compare_by_identity
          resolve = ->(v) { v = alias_of[v] while alias_of.key?(v); v }
          out = []
          k = 0

          ops.each do |op|
            x = gain_operand(op, uses) # (before substituting, as #core saw it)
            substitute(op, subst) unless subst.empty?
            out << op

            if x && producer.key?(resolve.(x))
              alias_of[op.dst] = resolve.(x)
              next
            end

            producer[op.dst] = k
            n = pads[k] || 0
            k += 1
            v = op.dst
            n.times do
              b = v.builder
              m = Op::Mul.new(b.value(v.type), op.node, Const.new(b, 1.0), v)
              m.dst.op = m
              out << m
              v = m.dst
            end
            subst[op.dst] = v unless v.equal?(op.dst)
          end

          output = subst[program.output] || program.output
          Program.new(ops: out, inputs: program.inputs, params: program.params, output: output, title: program.title)
        end

        # Replaces every Value in +op+'s instance variables (directly, in
        # Arrays, or in Hashes) found in +subst+.
        def self.substitute(op, subst)
          op.instance_variables.each do |iv|
            next if iv == :@dst || iv == :@node

            v = op.instance_variable_get(iv)
            case v
            when Value
              op.instance_variable_set(iv, subst[v]) if subst.key?(v)
            when Array
              op.instance_variable_set(iv, v.map { |e| e.is_a?(Value) && subst.key?(e) ? subst[e] : e }) if v.any? { |e| e.is_a?(Value) && subst.key?(e) }
            when Hash
              op.instance_variable_set(iv, v.transform_values { |e| e.is_a?(Value) && subst.key?(e) ? subst[e] : e }) if v.each_value.any? { |e| e.is_a?(Value) && subst.key?(e) }
            end
          end
        end
      end
    end
  end
end
