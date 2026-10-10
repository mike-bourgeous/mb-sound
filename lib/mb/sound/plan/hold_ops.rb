module MB
  module Sound
    module Plan
      module Op
        # Sample and hold (GraphNode::SampleHold): the source's value (or a
        # random draw) at each rising edge of the trigger (> 0 after <= 0),
        # held until the next, on the node's own held value and last trigger
        # sample (fast_plan's OP_SAMPLE_HOLD; random values come from the
        # node's Ruby generator through SampleHold#plan_draw, one call per
        # edge).  The mirror is SampleHold#process.
        class SampleHold < Base
          attr_reader :trigger, :source, :hold

          def initialize(dst, node, hold, trigger, source)
            super(dst, node)
            raise Unsupported.new(hold, 'a complex trigger or source') if trigger.complex? || source&.complex?
            raise Unsupported.new(hold, 'a constant trigger') unless trigger.is_a?(Value)
            raise Unsupported.new(hold, 'a constant source') if source && !source.is_a?(Value)

            @hold = hold
            @trigger = trigger
            @source = source
          end

          def operands
            [@trigger, @source].compact
          end

          def expression
            @source ? "sample_hold(#{@source}, trigger: #{@trigger})" : "random_hold(#{@hold.range}, trigger: #{@trigger})"
          end

          def opcode = :sample_hold

          def run_ruby(env, count)
            trig = env.fetch(@trigger)
            trig = trig[0...count] if trig.length > count
            data = @source && env.fetch(@source)
            env[@dst] = @hold.process(trig, data, count).dup
          end
        end
      end

      class Builder
        # +hold+ (a GraphNode::SampleHold) on trigger +trigger+ and source
        # +source+ (nil in random mode); see Op::SampleHold.
        def sample_hold(hold, trigger, source)
          emit(Op::SampleHold.new(value(:real), node, hold, self[trigger], source && self[source]))
        end
      end
    end
  end
end
