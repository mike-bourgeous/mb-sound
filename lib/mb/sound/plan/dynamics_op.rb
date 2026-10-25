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

          # Every channel's input Value (the first is #a).
          attr_reader :channels

          # The Values of channels 1 and up (channel 0 is #dst), computed by
          # this same op: a multichannel Dynamics runs every channel in one
          # kernel call (linked channels share one detector; see
          # GraphNode::Dynamics as a MultiDescribable).
          attr_reader :extra_dsts

          def initialize(dst, node, dynamics, channels, sides, times, extra_dsts: [])
            super(dst, node)
            channels = Array(channels)
            raise ArgumentError, "Expected #{GraphNode::Dynamics::Transfer} times (5)" unless times.length == 5
            raise ArgumentError, 'Expected one destination per channel' unless extra_dsts.length == channels.length - 1
            raise Unsupported.new(node, 'a complex dynamics input') if (channels + sides + times).any? { |v| v.complex? }
            raise ArgumentError, 'A dynamics input must be a Value' unless channels.all?(Value) && sides.all?(Value)
            raise ArgumentError, 'Too many channels or sidechain signals' if channels.length > 64 || sides.length > 64

            @dynamics = dynamics
            @channels = channels
            @a = channels[0]
            @sides = sides
            @times = times
            @extra_dsts = extra_dsts
          end

          # Every Value this op computes (channel order).
          def dsts
            [@dst] + @extra_dsts
          end

          def operands
            (@channels + @sides + @times).grep(Value).uniq
          end

          def expression
            outs = @extra_dsts.empty? ? '' : " (also #{@extra_dsts.join(', ')})"
            "#{@dynamics.class.name.rpartition('::').last.downcase}(#{@channels.join(', ')}, detector: #{@sides.join(', ')}, times: #{@times.join(', ')})#{outs} [#{@dynamics.to_s}]"
          end

          def opcode = :dynamics

          def run_ruby(env, count)
            at = ->(v) {
              next v.value.to_f if v.is_a?(Const)
              buf = env.fetch(v)
              buf.nil? ? nil : (buf.length > count ? buf[0...count] : buf)
            }
            outs = Array.new(@channels.length) { Numo::SFloat.zeros(count) }
            d = @dynamics
            GraphNode::Dynamics.process_ruby(outs, @channels.map(&at), @sides.map(&at), d.plan_curve, d.plan_params, @times.map(&at),
              d.instance_variable_get(:@state), d.instance_variable_get(:@delay))
            dsts.each_with_index { |v, c| env[v] = outs[c] }
          end
        end
      end

      class Builder
        # +dynamics+ (a one-channel GraphNode::Dynamics) on +a+ with detector
        # signals +sides+ and the five times +times+ in samples (Values,
        # Consts, or numbers; see Op::Dynamics).
        def dynamics(dynamics, a, sides, times)
          emit(Op::Dynamics.new(value(:real), node, dynamics, [self[a]], sides.map { |s| self[s] }, times.map { |t| self[t] }))
        end

        # Like #dynamics for several channels +channels+ (a multichannel
        # GraphNode::Dynamics, every channel in one op), returning one Value
        # per channel.
        def dynamics_channels(dynamics, channels, sides, times)
          extra = Array.new(channels.length - 1) { value(:real) }
          op = Op::Dynamics.new(value(:real), node, dynamics, channels.map { |c| self[c] }, sides.map { |s| self[s] }, times.map { |t| self[t] },
            extra_dsts: extra)
          extra.each { |v| v.op = op }
          [emit(op)] + extra
        end
      end
    end
  end
end
