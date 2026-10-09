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

        # +filter+ (a Filter::FourPole) on +a+ (see Op::FourPole).
        def four_pole(filter, a, cutoff:, resonance:)
          emit(Op::FourPole.new(value(:real), node, filter, self[a], cutoff: self[cutoff], resonance: self[resonance]))
        end
      end
    end
  end
end
