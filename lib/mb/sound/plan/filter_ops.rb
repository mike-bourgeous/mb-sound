module MB
  module Sound
    module Plan
      module Op
        # A Filter::SVF on a block (Filter::SampleWrapper with cutoff,
        # quality, and gain inputs): FastFilter.svf's kernel through
        # mb_svf.h (fast_plan's OP_SVF, plan_filters.c), on the filter's own
        # state Array, remembering the last cutoff, quality, and (with a gain
        # input) gain as SVF#dynamic_process does.  Parameters may move on
        # any sample; bit for bit the node's samples and state.
        class FilterSvf < Base
          attr_reader :a, :filter, :cutoff, :quality, :gain

          # True when the gain is an input (remembered after each block).
          attr_reader :gain_input

          def initialize(dst, node, filter, a, cutoff:, quality:, gain:, gain_input:)
            super(dst, node)
            raise Unsupported.new(node, 'a complex filter input') if a.complex?
            [cutoff, quality, gain].each do |v|
              raise Unsupported.new(node, 'a complex filter parameter') if v.complex?
            end

            @filter = filter
            @a = a
            @cutoff = cutoff
            @quality = quality
            @gain = gain
            @gain_input = gain_input
          end

          def operands
            [@a, @cutoff, @quality, @gain].grep(Value)
          end

          def expression
            "svf_#{@filter.filter_type}(#{@a}, cutoff: #{@cutoff}, quality: #{@quality}#{@gain_input || @filter.gain ? ", gain: #{@gain}" : ''})"
          end

          def opcode = :svf

          def run_ruby(env, count)
            par = ->(v) { v.is_a?(Const) ? v.parts[0] : env.fetch(v) }
            f = @filter
            c = par.(@cutoff)
            q = par.(@quality)
            g = par.(@gain)
            out = Filter::SVF.process_ruby(Numo::SFloat.cast(env.fetch(@a)), c, q, g, f.instance_variable_get(:@type_id),
                                           f.instance_variable_get(:@state), f.sample_rate)
            f.send(:remember, c, q, @gain_input ? g : nil)
            env[@dst] = out
          end
        end

        # A Filter::Cookbook on a block (Filter::SampleWrapper with cutoff
        # and quality inputs: `structure: :biquad`): Cookbook#dynamic_process
        # (FastSound.dynamic_biquad's loop, through mb_biquad.h; fast_plan's
        # OP_BIQUAD in plan_biquad.c) on the filter's coefficients and x/y
        # state, setting its last quality and cutoff as the node does.  The
        # mirror runs the node's own #dynamic_process (the cookbook biquad
        # has no Ruby mirror of its dynamic kernel).
        class FilterBiquad < Base
          attr_reader :a, :filter, :cutoff, :quality

          def initialize(dst, node, filter, a, cutoff:, quality:)
            super(dst, node)
            raise Unsupported.new(node, 'a complex filter input') if a.complex?
            [cutoff, quality].each do |v|
              raise Unsupported.new(node, 'a biquad parameter that is not a signal') unless v.is_a?(Value)
              raise Unsupported.new(node, 'a complex filter parameter') if v.complex?
            end

            @filter = filter
            @a = a
            @cutoff = cutoff
            @quality = quality
          end

          def operands
            [@a, @cutoff, @quality]
          end

          def expression
            "biquad_#{@filter.filter_type}(#{@a}, cutoff: #{@cutoff}, quality: #{@quality})"
          end

          def opcode = :biquad

          def type_id
            Filter::Cookbook::FILTER_TYPE_IDS.fetch(@filter.filter_type)
          end

          def run_ruby(env, count)
            env[@dst] = @filter.dynamic_process(Numo::SFloat.cast(env.fetch(@a)), cutoff: env.fetch(@cutoff), quality: env.fetch(@quality))
          end
        end

        # +a+ limited to lo..hi as Numo's SFloat#clip does (the bounds cast
        # to float; NaN stays NaN): Notes filter parameter nodes.
        class Clip < Base
          attr_reader :a, :lo, :hi

          def initialize(dst, node, a, lo, hi)
            super(dst, node)
            raise Unsupported.new(node, 'a complex clip input') if a.complex?

            @a = a
            @lo = lo.to_f
            @hi = hi.to_f
          end

          def operands = [@a]
          def expression = "clip(#{@a}, #{@lo}..#{@hi})"
          def opcode = :clip

          def run_ruby(env, count)
            env[@dst] = Numo::SFloat.cast(env.fetch(@a)).clip(@lo, @hi)
          end
        end

        # e^a in float as Numo::NMath.exp on an SFloat ((float)exp(double)):
        # Notes::Cutoff's key tracking.
        class Exp < Base
          attr_reader :a

          def initialize(dst, node, a)
            super(dst, node)
            raise Unsupported.new(node, 'a complex exp input') if a.complex?

            @a = a
          end

          def operands = [@a]
          def expression = "exp(#{@a})"
          def opcode = :exp

          def run_ruby(env, count)
            env[@dst] = Numo::NMath.exp(Numo::SFloat.cast(env.fetch(@a)))
          end
        end

        # SQ80::TimeScale#time per sample (double precision, stored as
        # float).
        class TimeScale < Base
          attr_reader :a, :scale

          def initialize(dst, node, a, scale)
            super(dst, node)
            raise Unsupported.new(node, 'a complex time scale input') if a.complex?

            @a = a
            @scale = scale
          end

          def operands = [@a]
          def expression = "#{@scale.kind}_time(#{@a}, #{@scale.seconds} s, amount #{@scale.amount})"
          def opcode = :time_scale

          def run_ruby(env, count)
            env[@dst] = Numo::SFloat.cast(Numo::SFloat.cast(env.fetch(@a)).to_a.map { |v| @scale.time(v) })
          end
        end

        # GraphNode::FourPole on a block: Filter::FourPole#dynamic_process
        # (FastFilter.four_pole or .diode_ladder, through mb_four_pole.h) on
        # the filter's own state, every mode, drive mode, clip, curve,
        # self-oscillation, and the diode ladder (fast_plan's OP_FOUR_POLE).
        # Cutoff and resonance are numbers or Values read per sample.
        class FourPole < Base
          attr_reader :a, :filter, :cutoff, :resonance

          def initialize(dst, node, filter, a, cutoff:, resonance:)
            super(dst, node)
            raise Unsupported.new(node, 'a complex filter input') if a.complex?
            [cutoff, resonance].each do |v|
              raise Unsupported.new(node, 'a complex filter parameter') if v.complex?
            end

            @filter = filter
            @a = a
            @cutoff = cutoff
            @resonance = resonance
          end

          def operands
            [@a, @cutoff, @resonance].grep(Value)
          end

          def expression
            "#{@filter.mode}(#{@a}, cutoff: #{@cutoff}, resonance: #{@resonance})"
          end

          def opcode = :four_pole

          # The kernel settings for fast_plan (see mb_plan_four_pole).
          def settings
            f = @filter
            curve, drive_mode, clip = f.send(:kernel_options)
            [
              f.instance_variable_get(:@k_max), f.instance_variable_get(:@compensation), f.instance_variable_get(:@drive),
              *f.instance_variable_get(:@mix), curve, drive_mode, clip, f.normalize? ? 1 : 0, f.diode? ? 1 : 0,
            ]
          end

          def run_ruby(env, count)
            par = ->(v) { v.is_a?(Const) ? v.parts[0] : env.fetch(v) }
            env[@dst] = @filter.dynamic_process_ruby(Numo::SFloat.cast(env.fetch(@a)), cutoff: par.(@cutoff), resonance: par.(@resonance))
          end
        end
      end

      class Builder
        # +filter+ (a Filter::SVF) on +a+ (see Op::FilterSvf).
        def filter_svf(filter, a, cutoff:, quality:, gain:, gain_input:)
          emit(Op::FilterSvf.new(value(:real), node, filter, self[a], cutoff: self[cutoff], quality: self[quality], gain: self[gain], gain_input: gain_input))
        end

        # +filter+ (a Filter::Cookbook) on +a+ (see Op::FilterBiquad).
        def filter_biquad(filter, a, cutoff:, quality:)
          emit(Op::FilterBiquad.new(value(:real), node, filter, self[a], cutoff: self[cutoff], quality: self[quality]))
        end

        # +a+ clipped to +lo+..+hi+ (see Op::Clip).
        def clip(a, lo, hi)
          emit(Op::Clip.new(value(:real), node, self[a], lo, hi))
        end

        # e^+a+ (see Op::Exp).
        def exp(a)
          emit(Op::Exp.new(value(:real), node, self[a]))
        end

        # SQ80::TimeScale +scale+'s times for +a+ (see Op::TimeScale).
        def time_scale(scale, a)
          emit(Op::TimeScale.new(value(:real), node, self[a], scale))
        end

        # +filter+ (a Filter::FourPole) on +a+ (see Op::FourPole).
        def four_pole(filter, a, cutoff:, resonance:)
          emit(Op::FourPole.new(value(:real), node, filter, self[a], cutoff: self[cutoff], resonance: self[resonance]))
        end
      end
    end
  end
end
