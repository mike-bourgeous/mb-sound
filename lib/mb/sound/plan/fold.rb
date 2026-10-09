module MB
  module Sound
    module Plan
      module Op
        # A product with a zero factor folded to zero (Plan::Fold): fills its
        # register with 0, so the ops reading it (and their own folds, e.g.
        # an envelope time computed from it) see a constant.  The other
        # factor's ops still run every block, unread, so the nodes behind it
        # (controllers, Tee branches, envelopes) stay in step.
        class ZeroFold < Fill
          # The other factor of the folded product (a Value or Const).
          attr_reader :folded

          # True when the zero is a constant of the patch, false when it is
          # another folded product (a fold propagating).
          attr_reader :primary

          def initialize(dst, node, value, folded, primary: true)
            super(dst, node, value)
            @folded = folded
            @primary = primary
          end

          def expression
            "0 (folded: 0 * #{@folded})"
          end
        end
      end

      # Folds products with a zero factor to zero (user decision 2026-10-09:
      # "a non-finite x there is a patch bug"): 0 * x is 0 for every finite
      # x, but where x is infinite or NaN the unfused graph gives NaN and
      # the plan 0, and a negative x gives -0 unfused and +0 planned (equal
      # in every comparison).  The zero is a constant in the patch (a plan
      # Const, a fill, or a product already folded), never a Constant
      # node's live value, so the fold doesn't depend on what is played.
      # Reported once per kind of node (Plan.fold_warnings) and listed by
      # Plan.explain.  The research spike found 18-24 such products per
      # synth script: GmTime-scaled envelope times of 0 (research-fused-ops
      # 3b8c8b7f).
      module Fold
        # Returns [ops, folds]: +ops+ with each Op::Mul that has a zero
        # factor replaced by an Op::ZeroFold of the same destination (the
        # destination Value's op is updated), and the ZeroFold ops.
        def self.zero_products(ops)
          zero = {}.compare_by_identity
          folds = []
          out = ops.map do |op|
            next op unless op.is_a?(Op::Mul)

            za = zero?(op.a, zero)
            zb = zero?(op.b, zero)
            next op unless za || zb

            dst = op.dst
            c = Const.new(dst.builder, 0.0, complex: dst.complex?)
            zf = za ? op.a : op.b
            primary = !(zf.is_a?(Value) && zero.key?(zf))
            f = Op::ZeroFold.new(dst, op.node, c, za ? op.b : op.a, primary: primary)
            dst.replace_op(op, f)
            zero[dst] = true
            folds << f
            f
          end
          [out, folds]
        end

        # True if +v+ is a zero Const, a Value filled with zero, or a folded
        # product.
        def self.zero?(v, zero)
          case v
          when Const then v.value == 0
          when Value then zero.key?(v) || (v.op.is_a?(Op::Fill) && v.op.value.value == 0)
          else false
          end
        end

        # Warns once per kind of folded product (the describing node's class
        # and the other factor's node class) unless Plan.fold_warnings is
        # false.
        def self.report(folds)
          return if folds.empty? || !Plan.fold_warnings

          @warned ||= {}
          folds.each do |f|
            next unless f.primary

            other = f.folded.is_a?(Value) && f.folded.op&.node ? Plan.class_label(f.folded.op.node) : f.folded.to_s
            key = [Plan.class_label(f.node), other]
            next if @warned[key]

            @warned[key] = true
            warn "Plan: folded 0 * x to 0 in #{Plan.node_label(f.node)} (x from #{other}); an infinite or NaN x would " \
              "no longer give NaN there.  Plan.explain lists every fold; Plan.fold_warnings = false silences this."
          end
        end
      end
    end
  end
end
