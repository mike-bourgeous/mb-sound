module MB
  module Sound
    module Plan
      module Op
        # An envelope generator (MB::Sound::Envelope and Notes::NoteEnvelope):
        # FastEnvelope's kernel (shared with fast_plan through mb_envelope.h)
        # on the envelope's own state NArray, with its times (in samples),
        # curves, levels, hold, and inputs (gate, trigger, velocity, choke,
        # lift, octaves) as Values or Consts.  Like Envelope#sample, an idle
        # envelope whose gate and trigger stay quiet skips the kernel
        # (Envelope#quiet_idle?'s state updates, which equal the kernel's).
        #
        # The Ruby mirror is Envelope.process_ruby.
        class Envelope < Base
          INPUTS = [:gate, :trigger, :velocity, :choke, :lift, :octaves].freeze

          # The kernel's value for an input that is absent (env_read_signal's
          # nil values).
          NIL_VALUES = { gate: 0.0, trigger: 0.0, velocity: 1.0, choke: 0.0, lift: 0.5, octaves: 0.0 }.freeze

          attr_reader :envelope, :times, :curves, :levels, :hold, :inputs

          # The node whose #plan_feed runs each block (Notes::NoteEnvelope's
          # bookkeeping), or nil.
          attr_reader :feeder

          def initialize(dst, node, envelope, times:, curves:, levels:, hold:, gate:, trigger:, velocity:, choke:, lift:, octaves:)
            super(dst, node)
            @envelope = envelope
            @times = times
            @curves = curves
            @levels = levels
            @hold = hold
            @inputs = { gate: gate, trigger: trigger, velocity: velocity, choke: choke, lift: lift, octaves: octaves }
            @feeder = envelope.respond_to?(:plan_feed) ? envelope : nil

            all = [*@times, *@curves, *@levels, @hold, *@inputs.values].compact
            raise Unsupported.new(envelope, 'a complex envelope parameter') if all.any?(&:complex?)
            raise Unsupported.new(envelope, 'a missing segment parameter') if [*@times, *@curves, *@levels, @hold].any?(&:nil?)
          end

          def operands
            [*@times, *@curves, *@levels, @hold, *@inputs.values].grep(Value)
          end

          def expression
            ins = @inputs.filter_map { |k, v| "#{k}: #{v}" if v }
            "envelope(#{@envelope.names.length} segments, #{ins.join(', ')})"
          end

          def opcode = :envelope

          # The kernel's config (Envelope#kernel_config) and shapes.
          def config
            @envelope.kernel_config
          end

          def shapes
            @envelope.plan_shapes
          end

          def run_ruby(env, count)
            val = ->(v) { v.is_a?(Const) ? v.value.to_f : (v.nil? ? nil : env.fetch(v)) }
            out = Numo::SFloat.zeros(count)
            MB::Sound::Envelope.process_ruby(
              out, @envelope.plan_state,
              @times.map(&val), @curves.map(&val), @levels.map(&val), val.(@hold),
              INPUTS.map { |k| val.(@inputs[k]) }, config, shapes
            )
            env[@dst] = out
          end
        end
      end
    end
  end
end
