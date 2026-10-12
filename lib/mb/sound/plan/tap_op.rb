module MB
  module Sound
    module Plan
      module Op
        # A probe of an intermediate Value (a spied node inside a region):
        # copies the block of +a+ into the tap's buffer, so the node's spies
        # (GraphNode#spy) see every buffer without the node becoming a
        # boundary (maintainer, 2026-10-11: "Op::Tap would be useful").
        # After the block the region calls the spies with the tap's buffer
        # (Region#finish: :pre spies with the sample count, then :post spies
        # with the samples), as the node's own #sample would have.  The
        # spies run after the whole region's block instead of right after
        # the node, so a spy whose effect another node of the same block
        # reads (a side channel, e.g. a Ruby block reading an Array the spy
        # fills) sees it one block later; Plan.observe(node) keeps such a
        # node a boundary.
        class Tap < Base
          attr_reader :a

          # The node whose spies get the buffer.
          attr_reader :target

          # [buffer] (an SFloat or SComplex of at least the block's length,
          # replaced when blocks grow; the C executor reads entry 0 each
          # run, so lowered objects stay valid).
          attr_reader :holder

          def initialize(dst, node, a, target)
            super(dst, node)
            raise ArgumentError, 'A tap reads a Value' unless a.is_a?(Value)

            @a = a
            @target = target
            @holder = [nil]
          end

          def operands = [@a]
          def expression = "tap #{@a} for #{Plan.node_label(@target)}'s spies"
          def opcode = :tap

          # Makes the buffer hold at least +n+ samples.
          def reserve(n)
            buf = @holder[0]
            return if buf && buf.length >= n

            @holder[0] = (@a.complex? ? Numo::SComplex : Numo::SFloat).zeros([n, 1].max)
            @views = {}
          end

          # The tapped samples of the last block of +n+ samples (a view
          # reused while +n+ stays the same).
          def view(n)
            (@views ||= {})[n] ||= @holder[0][0...n]
          end

          # Calls the target's spies for a block of +n+ samples (nil: the
          # region ended).
          def deliver(n)
            return unless @target.instance_variable_get(:@handled_spies)

            @target.send(:call_spies, n || 0, :pre)
            @target.send(:call_spies, n && view(n), :post)
          end

          def run_ruby(env, count)
            reserve(count)
            buf = env.fetch(@a)
            @holder[0][0...count] = buf.length > count ? buf[0...count] : buf
            env[@dst] = nil
          end
        end
      end

      class Builder
        # A tap of +a+ for +target+'s spies (see Op::Tap).  (Not named #tap:
        # Object#tap.)
        def tap_value(a, target)
          emit(Op::Tap.new(value(a.type), node, self[a], target))
        end
      end
    end
  end
end
