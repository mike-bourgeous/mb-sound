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
      end
    end
  end
end
