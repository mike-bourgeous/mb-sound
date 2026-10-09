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
      end

      class Builder
        # +filter+ (a Filter::SVF) on +a+ (see Op::FilterSvf).
        def filter_svf(filter, a, cutoff:, quality:, gain:, gain_input:)
          emit(Op::FilterSvf.new(value(:real), node, filter, self[a], cutoff: self[cutoff], quality: self[quality], gain: self[gain], gain_input: gain_input))
        end
      end
    end
  end
end
