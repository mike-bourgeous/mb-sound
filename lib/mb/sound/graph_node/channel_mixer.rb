require 'forwardable'

module MB
  module Sound
    module GraphNode
      # Mixes N input channels into M output channels with an M×N matrix of
      # gains: output j is the sum of gain[j][i] times input i.  Gains may be
      # numbers, complex numbers, or per-sample arrays computed from graph
      # nodes.
      #
      # Each mixing law is a subclass (Pan, Balance, Width, Mono, MidSide,
      # FromMidSide, Swap, Matrix, Position) that declares its channel
      # counts, parameters, and options, and computes the gains:
      #
      #     class Pan < ChannelMixer
      #       channels 1 => 2
      #       param :position, default: 0, range: -1..1
      #       option :law, default: :equal_power, values: PanLaws::LAWS
      #
      #       def gains_for(position:)
      #         left, right = PanLaws.gains(option(:law), position)
      #         [[left], [right]]
      #       end
      #     end
      #
      # Parameters are numbers or graph nodes (read every sample).  When every
      # parameter is a number, the gains are computed once; otherwise
      # #gains_for receives one NArray per node parameter for each buffer, so
      # gain formulas should work on both (see .math).
      #
      # Complex gains (phase positioning, matrix surround) need complex
      # inputs: real inputs pass through a Filter::HilbertIIR to become
      # analytic signals, and the outputs are their real parts.  If any input
      # is already complex, the outputs stay complex.
      #
      # The mixer itself holds the outputs (see #outputs); the DSL methods
      # (GraphNode#pan, #balance, #width, #mono, #matrix, #position, ...)
      # return them as a Channels bundle, or the single output node.
      class ChannelMixer
        include MultiOutput
        include Nameable

        # One output channel of a ChannelMixer.
        class Output
          extend Forwardable

          include GraphNode
          include GraphNode::SampleRateHelper
          include GraphNode::NodeOutput

          def_delegators :@mixer, :sample_rate

          # The index of this output.
          attr_reader :index

          def initialize(mixer:, index:)
            @owner = mixer
            @mixer = mixer
            @index = index
          end

          def sample(count)
            @mixer.sample_internal(count, @index)
          end

          # Sets the sample rate of the whole mixer and its inputs.
          def sample_rate=(rate)
            @mixer.sample_rate = rate
            self
          end

          def sources
            { mixer: @mixer }
          end

          def to_s
            "#{@mixer} output #{@index + 1} of #{@mixer.outputs.length}"
          end
        end

        # Passes complex input through, and converts real input to an
        # analytic signal with Filter::HilbertIIR (for complex gains).
        class Analytic
          include GraphNode
          include GraphNode::SampleRateHelper

          def initialize(source, sample_rate:)
            @source = source.get_sampler
            @sample_rate = sample_rate.to_f
            @hilbert = nil
            @complex_input = false
            @node_type_name = 'Analytic'
          end

          # True once a complex buffer has come through (the input was
          # already analytic).
          def complex_input?
            @complex_input
          end

          def sample(count)
            data = @source.sample(count)
            return nil if data.nil?

            if data.is_a?(Numo::SComplex) || data.is_a?(Numo::DComplex)
              @complex_input = true
              data
            else
              @hilbert ||= MB::Sound::Filter::HilbertIIR.new(sample_rate: @sample_rate)
              @hilbert.process(data)
            end
          end

          def sample_rate=(rate)
            super
            @hilbert = nil
            self
          end

          def sources
            { input: @source }
          end
        end

        class << self
          # Declares the channel counts as `inputs => outputs`: an Integer, or
          # :any for any number of channels (Integer outputs only).
          def channels(spec = nil)
            if spec
              raise ArgumentError, 'Declare channels as inputs => outputs' unless spec.is_a?(Hash) && spec.length == 1
              @channels = spec.first
            end
            @channels || superclass.instance_variable_get(:@channels)
          end

          # Declares a parameter: a number or graph node, given to #gains_for
          # by name.  +range+ documents (and checks, for numbers) the
          # expected values.
          def param(name, default:, range: nil)
            own_params[name] = { default: default, range: range }.freeze
          end

          # Declares an option: a fixed setting chosen when the mixer is
          # created, one of +values+ if given.
          def option(name, default:, values: nil)
            own_options[name] = { default: default, values: values }.freeze
          end

          # The parameters declared by this class and its superclasses.
          def params
            (superclass.respond_to?(:params) ? superclass.params : {}).merge(own_params)
          end

          # The options declared by this class and its superclasses.
          def options
            (superclass.respond_to?(:options) ? superclass.options : {}).merge(own_options)
          end

          # Returns Numo::NMath for an NArray and Math for a number, so gain
          # formulas work on both (e.g. `math(x).cos(x)`).
          def math(value)
            value.is_a?(Numo::NArray) ? Numo::NMath : Math
          end

          private

          def own_params
            @own_params ||= {}
          end

          def own_options
            @own_options ||= {}
          end
        end

        # The output nodes, one per output channel.
        attr_reader :outputs

        # The input nodes (sampler branches).
        attr_reader :inputs

        attr_reader :sample_rate

        # Creates a mixer for +inputs+ (a node, a Channels bundle or other
        # multi-output node, or an Array of nodes) with parameter and option
        # values by name (see .param and .option).
        def initialize(inputs, sample_rate: nil, **settings)
          inputs = input_list(inputs)
          @sample_rate = (sample_rate || inputs.first.sample_rate).to_f

          in_spec, out_spec = self.class.channels
          if in_spec.is_a?(Integer) && inputs.length != in_spec
            raise ArgumentError, "#{self.class.name.split('::').last} needs #{in_spec} input channel#{in_spec == 1 ? '' : 's'} (got #{inputs.length})"
          end

          @param_values = {}
          @options = {}
          setup(inputs, settings)

          self.class.params.each do |name, spec|
            set_param(name, settings.key?(name) ? settings.delete(name) : spec[:default], spec[:range])
          end
          self.class.options.each do |name, spec|
            value = settings.key?(name) ? settings.delete(name) : spec[:default]
            if spec[:values] && !spec[:values].include?(value)
              raise ArgumentError, "#{name} must be one of #{spec[:values].map(&:inspect).join(', ')} (got #{value.inspect})"
            end
            @options[name] = value
          end
          raise ArgumentError, "Unknown settings for #{self.class.name}: #{settings.keys.join(', ')}" unless settings.empty?

          @complex = complex_gains?
          @inputs = inputs.map { |inp|
            @complex ? Analytic.new(inp, sample_rate: @sample_rate) : inp.get_sampler
          }
          @inputs.each do |inp|
            inp.sample_rate = @sample_rate if inp.respond_to?(:sample_rate=) && inp.sample_rate != @sample_rate
          end

          @gains = numeric_params? ? gains_for(**@param_values) : nil

          output_count = out_spec.is_a?(Integer) ? out_spec : output_channels
          @outputs = Array.new(output_count) { |idx| Output.new(mixer: self, index: idx) }.freeze

          @sampled = Set.new
          @output_data = nil
        end

        # The value of option +name+.
        def option(name)
          @options.fetch(name)
        end

        # The parameter values by name: numbers, or the graph nodes given.
        def params
          @param_values.transform_values { |v| v.respond_to?(:original_source) ? v.original_source : v }
        end

        # The current gain matrix (Arrays of rows; per-sample NArrays for
        # node parameters, from the last buffer).
        def gains
          @gains || @last_gains
        end

        # Returns the M×N gain matrix for the given parameter values (numbers
        # or NArrays).  Implemented by subclasses.
        def gains_for(**params)
          raise NotImplementedError, "#{self.class} must implement #gains_for"
        end

        # The inputs and node parameters (for graph traversal and sample rate
        # changes).
        def sources
          @inputs.map.with_index { |inp, idx| [:"input_#{idx + 1}", inp] }.to_h.merge(
            @param_values.select { |_, v| v.respond_to?(:sample) }
          )
        end

        # Sets the sample rate of the inputs and node parameters.
        def sample_rate=(rate)
          @sample_rate = rate.to_f
          sources.each_value do |src|
            src.sample_rate = @sample_rate if src.respond_to?(:sample_rate=)
          end
          self
        end
        alias at_rate sample_rate=

        # Called by Output#sample: samples the inputs and node parameters once
        # per frame (the first time any output is sampled, or when an output
        # is sampled again), mixes, and returns output +index+.
        def sample_internal(count, index)
          if @sampled.include?(index) || @output_data.nil?
            if @sampled.length != 0 && @sampled.length != @outputs.length
              warn "#{self} output #{index} sampled again before other outputs"
            end
            @sampled.clear

            data = @inputs.map { |inp| inp.sample(count)&.dup }
            return @output_data = nil if data.any?(&:nil?)

            values = @param_values.transform_values { |v| v.respond_to?(:sample) ? v.sample(count) : v }
            return @output_data = nil if values.values.any?(&:nil?)

            length = (data + values.values.grep(Numo::NArray)).map(&:length).min
            data = data.map { |d| d.length > length ? d[0...length] : d }
            values = values.transform_values { |v| v.is_a?(Numo::NArray) && v.length > length ? v[0...length] : v }

            gains = @gains || (@last_gains = gains_for(**values))
            @output_data = mix(gains, data)
          end

          return nil if @output_data.nil?

          @sampled << index
          @output_data[index].dup
        end

        # A description with the mixing law, options, and parameters.
        def to_s
          law = self.class.name.split('::').last
          opts = @options.map { |k, v| "#{k}: #{v}" }
          prms = params.map { |k, v| "#{k}: #{v.is_a?(Numeric) ? MB::M.sigfigs(v, 4) : v}" }
          details = (opts + prms).join(', ')
          details.empty? ? law : "#{law} (#{details})"
        end

        private

        # Called before parameters are read, with the input list and the
        # remaining settings; subclasses may add parameters (see #add_param)
        # or consume settings.
        def setup(inputs, settings)
        end

        # The number of outputs, for classes declaring :any outputs.
        def output_channels
          raise NotImplementedError, "#{self.class} must declare its output channel count or implement #output_channels"
        end

        # True if the gains are complex (inputs then pass through Analytic).
        def complex_gains?
          false
        end

        # Adds an instance parameter (e.g. one per Matrix entry).
        def add_param(name, value)
          set_param(name, value, nil)
        end

        def set_param(name, value, range)
          if value.respond_to?(:sample)
            node = value.get_sampler
            node.sample_rate = @sample_rate if node.respond_to?(:sample_rate=) && node.sample_rate != @sample_rate
            @param_values[name] = node
          elsif value.is_a?(Numeric)
            if range && value.real? && !range.cover?(value)
              raise ArgumentError, "#{name} must be in #{range} (got #{value})"
            end
            @param_values[name] = value
          else
            raise ArgumentError, "#{name} must be a number or a graph node (got #{value.inspect})"
          end
        end

        def numeric_params?
          @param_values.values.all?(Numeric)
        end

        # Returns output data: each output is the sum of gain times input,
        # skipping zero gains, as real parts unless an input was complex.
        def mix(gains, data)
          real_out = @complex && @inputs.none? { |inp| inp.complex_input? }

          gains.map { |row|
            out = nil
            row.each_with_index do |g, i|
              next if g.is_a?(Numeric) && g == 0
              term = g * data[i]
              out = out.nil? ? term : out + term
            end
            out ||= data[0].class.zeros(data[0].length)
            out = out.real if real_out && (out.is_a?(Numo::SComplex) || out.is_a?(Numo::DComplex))
            out
          }
        end

        def input_list(inputs)
          list = if inputs.is_a?(Array)
                   inputs.flat_map { |i| i.respond_to?(:outputs) ? i.outputs : [i] }
                 elsif inputs.respond_to?(:outputs)
                   inputs.outputs
                 else
                   [inputs]
                 end
          raise ArgumentError, 'A mixer needs at least one input' if list.empty?
          raise ArgumentError, 'Mixer inputs must be graph nodes' unless list.all? { |i| i.respond_to?(:sample) }
          list
        end
      end
    end
  end
end
