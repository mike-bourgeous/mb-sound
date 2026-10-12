module MB
  module Sound
    module Plan
      module Op
        # A one-channel GraphNode::Dynamics (compress, expand, noise_gate,
        # duck, compand): FastDynamics.compand's kernel (shared through
        # mb_dynamics.h; fast_plan's OP_DYNAMICS) on the node's own state and
        # lookahead delay, reading its input, detector signals (the input,
        # or the sidechain channels as boundary inputs), and times in
        # samples (Consts for fixed lengths; Values for node times, already
        # scaled to samples).  The mirror is Dynamics.process_ruby.
        class Dynamics < Base
          attr_reader :a, :sides, :times, :dynamics

          def initialize(dst, node, dynamics, a, sides, times)
            super(dst, node)
            raise ArgumentError, "Expected #{GraphNode::Dynamics::Transfer} times (5)" unless times.length == 5
            raise Unsupported.new(node, 'a complex dynamics input') if ([a] + sides + times).any? { |v| v.complex? }
            raise ArgumentError, 'A dynamics input must be a Value' unless a.is_a?(Value) && sides.all?(Value)
            raise ArgumentError, 'Too many sidechain signals' if sides.length > 64

            @dynamics = dynamics
            @a = a
            @sides = sides
            @times = times
          end

          def operands
            ([@a] + @sides + @times).grep(Value).uniq
          end

          def expression
            "#{@dynamics.class.name.rpartition('::').last.downcase}(#{@a}, detector: #{@sides.join(', ')}, times: #{@times.join(', ')}) [#{@dynamics.to_s}]"
          end

          def opcode = :dynamics

          def run_ruby(env, count)
            at = ->(v) {
              next v.value.to_f if v.is_a?(Const)
              buf = env.fetch(v)
              buf.nil? ? nil : (buf.length > count ? buf[0...count] : buf)
            }
            out = Numo::SFloat.zeros(count)
            d = @dynamics
            GraphNode::Dynamics.process_ruby([out], [at.(@a)], @sides.map(&at), d.plan_curve, d.plan_params, @times.map(&at),
              d.instance_variable_get(:@state), d.instance_variable_get(:@delay))
            env[@dst] = out
          end
        end
      end

      class Builder
        # +dynamics+ (a one-channel GraphNode::Dynamics) on +a+ with detector
        # signals +sides+ and the five times +times+ in samples (Values,
        # Consts, or numbers; see Op::Dynamics).
        def dynamics(dynamics, a, sides, times)
          emit(Op::Dynamics.new(value(:real), node, dynamics, self[a], sides.map { |s| self[s] }, times.map { |t| self[t] }))
        end
      end
    end
  end
end
