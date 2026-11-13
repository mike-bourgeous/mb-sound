module MB
  module Sound
    module Plan
      module Op
        # A GraphNode::FilterBank: FastFilter.filter_bank's kernel through
        # mb_filter_bank.h (fast_plan's OP_FILTER_BANK, plan_filter_bank.c)
        # on the node's own config and state, reading its input and its
        # signals (one per distinct parameter node; a Const for one the
        # region folded to a number).  Computes every channel: channel 0 is
        # #dst, the others #extra_dsts (a multichannel bank's Router region,
        # see GraphNode::FilterBank::Router).  Bit for bit the node's
        # samples and state.  The mirror is FilterBank.process_ruby.
        class FilterBank < Base
          attr_reader :a, :signals, :bank

          # The Values of channels 1 and up (channel 0 is #dst).
          attr_reader :extra_dsts

          def initialize(dst, node, bank, a, signals, extra_dsts: [])
            super(dst, node)
            raise Unsupported.new(node, 'a complex filter bank input') if a.complex?
            raise Unsupported.new(node, 'a complex filter bank parameter') if signals.any?(&:complex?)
            raise ArgumentError, 'A filter bank input must be a Value' unless a.is_a?(Value)
            raise ArgumentError, 'Expected one destination per channel' unless extra_dsts.length == bank.channels - 1

            @bank = bank
            @a = a
            @signals = signals
            @extra_dsts = extra_dsts
          end

          # Every Value this op computes (channel order).
          def dsts
            [@dst] + @extra_dsts
          end

          def operands
            ([@a] + @signals).grep(Value).uniq
          end

          def expression
            outs = @extra_dsts.empty? ? '' : " (also #{@extra_dsts.join(', ')})"
            sigs = @signals.empty? ? '' : ", #{@signals.join(', ')}"
            "filter_bank(#{@a}#{sigs})#{outs} [#{@bank}]"
          end

          def opcode = :filter_bank

          def run_ruby(env, count)
            at = ->(v) {
              next Kernels::Arithmetic.f32(v.parts[0]) if v.is_a?(Const)

              buf = env.fetch(v)
              buf.length > count ? buf[0...count] : buf
            }
            b = @bank
            outs = Array.new(b.channels) { Numo::SFloat.zeros(count) }
            GraphNode::FilterBank.process_ruby(outs, at.(@a), b.config, @signals.map(&at), b.instance_variable_get(:@state), b.sample_rate)
            dsts.each_with_index { |v, c| env[v] = outs[c] }
          end
        end
      end

      class Builder
        # +bank+ (a GraphNode::FilterBank) on +a+ with its +signals+
        # (Values, Consts, or numbers), returning one Value per channel
        # (see Op::FilterBank).
        def filter_bank(bank, a, signals)
          extra = Array.new(bank.channels - 1) { value(:real) }
          op = Op::FilterBank.new(value(:real), node, bank, self[a], signals.map { |s| self[s] }, extra_dsts: extra)
          extra.each { |v| v.op = op }
          [emit(op)] + extra
        end
      end
    end
  end
end
