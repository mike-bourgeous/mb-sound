module MB
  module Sound
    class Notes
      # Shared parts of Cutoff and Quality: number-or-node inputs and a GM
      # controller input that #gm turns on and off.
      module FilterParamNode
        include GraphNode
        include GraphNode::SampleRateHelper

        # Turns the GM controller input (brightness or resonance) on or off.
        # Returns self.
        def gm(enabled = true)
          enabled = !!enabled
          return self if enabled == gm?

          if enabled
            @gm_input = @gm_source.call.get_sampler
          else
            @gm_input.destroy if @gm_input.respond_to?(:destroy)
            @gm_input = nil
          end
          self
        end

        # True if the GM controller input is on (see #gm).
        def gm?
          !@gm_input.nil?
        end

        private

        # The start of #sample's buffer for the plan: a number (as the float
        # #start fills) or a Value.
        def plan_start(p, value)
          value.is_a?(Numeric) ? p.const(Numo::SFloat[value][0]) : p[value]
        end

        def input(value)
          value.respond_to?(:sample) ? value.get_sampler : value.to_f
        end

        # Multiplies @buf[0...count] by +input+ (a number or node).  Returns
        # false if a node ended.
        def multiply(input, count)
          return true if input.nil?
          return (@buf.inplace * input; true) if input.is_a?(Numeric)

          data = input.sample(count)
          return false if data.nil? || data.length < count
          @buf.inplace * data
          true
        end

        # Starts @buf as +count+ copies of +input+.  Returns false if a node
        # ended.
        def start(input, count)
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          if input.is_a?(Numeric)
            @buf.fill(input)
          else
            data = input.sample(count)
            return false if data.nil? || data.length < count
            @buf[0..] = data
          end
          true
        end
      end

      # A filter cutoff in Hz that follows the notes (see Notes#cutoff):
      # base × brightness (CC 74, ±2 octaves around 64) × envelope multiplier
      # × key tracking (2 ** ((note − 60) / 12 × keytrack)), clamped to 1 Hz
      # .. 0.49 × the sample rate.
      class Cutoff
        include FilterParamNode

        # The base cutoff (Hz or a node) and the key tracking amount.
        attr_reader :base, :keytrack

        # The envelope (a cutoff multiplier node, or nil).
        def env
          @env_node
        end

        def initialize(base, number:, keytrack:, env:, brightness:, sample_rate: 48000)
          @sample_rate = sample_rate.to_f
          @base = input(base)
          @number = keytrack == 0 ? nil : number.get_sampler
          @keytrack = keytrack.to_f
          @env = env&.get_sampler
          @env_node = env
          @gm_source = brightness
          @gm_input = nil
          @buf = nil
          @node_type_name = 'Notes Cutoff'
        end

        # Turns brightness (CC 74) on or off, and GM2 time scaling of the
        # envelope if it was made by Notes#cutoff (see NoteEnvelope#gm).
        def gm(enabled = true)
          @env_node.gm(enabled) if @own_env && @env_node.respond_to?(:gm)
          super
        end

        # Used by Notes#cutoff to mark the envelope as its own default.
        def own_env!
          @own_env = true
          self
        end

        def sample(count)
          return nil unless start(@base, count)
          return nil unless multiply(@gm_input, count)
          return nil unless multiply(@env, count)

          if @number
            n = @number.sample(count)
            return nil if n.nil? || n.length < count
            @buf.inplace * Numo::NMath.exp((n - 60) * (@keytrack * Math.log(2) / 12.0))
          end

          @buf.inplace.clip(1.0, 0.49 * @sample_rate)
          @buf.not_inplace!
        end

        def sources
          { base: @base, brightness: @gm_input, env: @env, number: @number }.compact
        end

        include Plan::Describable

        # Plan layer: the base times the GM brightness, the envelope, and
        # the key tracking factor e^((n - 60) k ln 2 / 12), clipped, in the
        # same float operations as #sample (Plan::Op::Exp, Op::Clip).
        def plan_describe(p)
          buf = plan_start(p, @base)
          buf = buf * p[@gm_input] if @gm_input
          buf = buf * p[@env] if @env
          if @number
            t = (p[@number] + p.const(-60.0)) * p.const(@keytrack * Math.log(2) / 12.0)
            buf = buf * p.exp(t)
          end
          buf = p.fill(buf) if buf.is_a?(Plan::Const)
          p.clip(buf, 1.0, 0.49 * @sample_rate)
        end
      end

      # A filter quality that follows resonance (CC 71; see Notes#quality):
      # q × x0.5..x1..x4 (64 is neutral).
      class Quality
        include FilterParamNode

        attr_reader :quality

        def initialize(quality, resonance:, sample_rate: 48000)
          @sample_rate = sample_rate.to_f
          @quality = input(quality)
          @gm_source = resonance
          @gm_input = nil
          @buf = nil
          @node_type_name = 'Notes Quality'
        end

        def sample(count)
          return nil unless start(@quality, count)
          return nil unless multiply(@gm_input, count)
          @buf.not_inplace!
        end

        def sources
          { quality: @quality, resonance: @gm_input }.compact
        end

        include Plan::Describable

        # Plan layer: the base times the GM resonance controller.
        def plan_describe(p)
          buf = plan_start(p, @quality)
          buf = buf * p[@gm_input] if @gm_input
          buf.is_a?(Plan::Const) ? p.fill(buf) : buf
        end
      end

      # A 0..1 resonance amount for 4-pole filters that follows resonance
      # (CC 71; see Notes#reso): the base amount at 64, linear down to 0 at
      # raw 0 and up to 1 at 127 (the base is clamped to 0..1 first).
      class Resonance
        include FilterParamNode

        # The base amount (a number or node).
        attr_reader :amount

        def initialize(amount, control:, sample_rate: 48000)
          @sample_rate = sample_rate.to_f
          @amount = input(amount)
          @gm_source = control
          @gm_input = nil
          @buf = nil
          @node_type_name = 'Notes Resonance'
        end

        def sample(count)
          return nil unless start(@amount, count)
          @buf.inplace.clip(0.0, 1.0)

          if @gm_input
            pos = @gm_input.sample(count)
            return nil if pos.nil? || pos.length < count

            # base + pos (1 - base) above the center, base (1 + pos) below
            up = pos.clip(0.0, 1.0)
            down = pos.clip(-1.0, 0.0)
            @buf.inplace * (down - up + 1.0)
            @buf.inplace + up
          end

          @buf.not_inplace!
        end

        def sources
          { amount: @amount, control: @gm_input }.compact
        end

        include Plan::Describable

        # Plan layer: the amount clipped to 0..1, then moved toward 0 or 1 by
        # the controller as #sample does (buf (down - up + 1) + up).
        def plan_describe(p)
          buf = plan_start(p, @amount)
          buf = p.fill(buf) if buf.is_a?(Plan::Const)
          buf = p.clip(buf, 0.0, 1.0)
          return buf unless @gm_input

          pos = p[@gm_input]
          up = p.clip(pos, 0.0, 1.0)
          down = p.clip(pos, -1.0, 0.0)
          buf * ((down + up * -1.0) + 1.0) + up
        end
      end
    end
  end
end
