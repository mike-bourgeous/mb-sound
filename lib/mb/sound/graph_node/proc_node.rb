module MB
  module Sound
    module GraphNode
      # A signal-processing graph node that calls a given Ruby Proc with each
      # buffer retrieved from the source, with the result of the Proc returned
      # from the #sample method.
      class ProcNode
        include GraphNode
        include SampleRateHelper

        attr_reader :sources, :source, :callers

        # Initializes a graph node that calls the +block+ with the result of the
        # +source+'s sample method when this object's #sample method is called.
        #
        # The +extra_sources+ parameter can be used if the +block+ retrieves
        # data from more graph nodes than just +source+, so that graph
        # searching methods still work.  Pass a Hash from source name to
        # source node.
        #
        # +:type_name+ is stored in @node_type_name for display in e.g.
        # GraphViz graphs.  See GraphNode#graphviz.
        def initialize(source, extra_sources: {}, sample_rate: nil, type_name: nil, &block)
          @graph_node_name = block.source_location&.join(':')&.rpartition('mb-sound')&.last
          @node_type_name = "ProcNode (#{type_name})"

          source = source.get_sampler if source.respond_to?(:sample)

          @source = source
          @sources = { input: source }.merge(extra_sources || {}).freeze

          @sample_rate = sample_rate

          @sources.each_with_index do |(name, src), idx|
            if src.respond_to?(:sample_rate)
              @sample_rate ||= src.sample_rate
              if src.sample_rate != @sample_rate
                raise "Source #{idx}/#{name}/#{src} sample rate #{src.sample_rate} does not match expected rate #{@sample_rate}"
              end
            end
          end

          raise 'No sample rate given to ProcNode' unless @sample_rate

          @callers = caller_locations(5)
          @cb = block
        end

        # Calls the block given to the constructor with the input data and
        # returns the result from the block.
        def sample(count)
          data = @source.sample(count)
          return nil if data.nil?
          @cb.call(data)
        end

        # Plan layer (see MB::Sound::Plan): GraphNode#/ and #** make
        # ProcNodes whose operation is known (+plan_operator+, set by
        # ArithmeticMethods); other procs run Ruby blocks and stay unfused.
        include Plan::Describable

        # The operation of a ProcNode whose block is known to the plan
        # layer: '/' or '**' (GraphNode#/ and #**), or :note_freq
        # (Tuning#freq, with +plan_tuning+); nil for other blocks.
        attr_accessor :plan_operator

        # The Tuning of a :note_freq ProcNode.
        attr_accessor :plan_tuning

        def plan_describe(p)
          a = p[@source]
          return p.note_freq(a, @plan_tuning) if @plan_operator == :note_freq

          b = p[@sources[:operand]]
          @plan_operator == '/' ? a / b : a ** b
        end

        def plan_inputs
          [@source, @sources[:operand]].select { |s| s.respond_to?(:sample) }
        end

        def plan_unsupported_reason
          return nil if @plan_operator == :note_freq && @plan_tuning
          return 'a Ruby block' unless @plan_operator == '/' || @plan_operator == '**'

          operand = @sources[:operand]
          return 'a constant exponent (Numo multiplies)' if @plan_operator == '**' && !operand.respond_to?(:sample)
          return "a #{operand.class} divisor" if @plan_operator == '/' && operand.is_a?(Numeric) && !operand.is_a?(Float) && !operand.is_a?(Integer)

          nil
        end
      end
    end
  end
end
