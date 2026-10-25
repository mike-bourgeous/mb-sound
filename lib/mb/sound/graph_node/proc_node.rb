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

        # Where the block was written ("lib/mb/sound/tuning.rb:87" inside
        # mb-sound, else the full path), or nil.
        attr_reader :source_location

        # The root of the mb-sound checkout or gem (paths inside it are shown
        # relative to it).
        ROOT = File.expand_path('../../../..', __dir__) + File::SEPARATOR

        # A block's source_location as "file:line", relative to ROOT when
        # inside it.
        def self.short_location(location)
          return nil unless location

          file, line = location
          "#{file.delete_prefix(ROOT)}:#{line}"
        end

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
          # Where the block was written, for graphviz and debugging; not the
          # node's name (ux-fix-2: names are shown as values, so `play C4`
          # printed freq=/.../lib/mb/sound/tuning.rb:87)
          @source_location = ProcNode.short_location(block.source_location)
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

          @callers = caller_locations(5, 24) # where it was made, for messages (a full backtrace costs ~5 us deep in a build)
          @cb = block

          # Set by ArithmeticMethods and Tuning after construction (here so
          # every ProcNode has one instance variable layout; see
          # GraphNode::IvarPreset)
          @operator = nil
          @plan_operator = nil
          @plan_tuning = nil
        end

        # What GraphNode#make_source_name shows for this node when it isn't
        # named: the note for Tuning#freq of a constant note number (C4),
        # hz(...) of other note numbers; nil for other blocks (shown by id).
        def display_label
          return nil unless @plan_operator == :note_freq

          src = climb_tee_tree(@source)
          if src.is_a?(Constant) && src.constant.is_a?(Numeric) && src.constant.real? && src.constant == src.constant.round
            Note.new(src.constant.round).to_s
          else
            "hz(#{make_source_name(src)})"
          end
        end

        # See GraphNode#to_s_graphviz (adds where the block was written).
        def to_s_graphviz
          @source_location ? "#{super}#{@source_location}\n" : super
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
          # (a Float exponent is filled into a register; see Plan::Builder#pow)
          return "a #{operand.class} exponent (Numo multiplies)" if @plan_operator == '**' && !operand.respond_to?(:sample) && !operand.is_a?(Float)
          return "a #{operand.class} divisor" if @plan_operator == '/' && operand.is_a?(Numeric) && !operand.is_a?(Float) && !operand.is_a?(Integer)

          nil
        end
      end
    end
  end
end
