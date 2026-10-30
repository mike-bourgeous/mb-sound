module MB
  module Sound
    module GraphNode
      # A signal-processing graph node that calls a given Ruby Proc with each
      # buffer retrieved from the source, with the result of the Proc returned
      # from the #sample method (GraphNode#proc: the escape hatch for code
      # the DSL has no node for; never fused by plans).  The library's own uses became node
      # types (MathFunction, BinaryOperation for #/ and #**, NoteFrequency
      # for Tuning#freq, QualityResonance; omnibus18 for the last three).
      class ProcNode
        include GraphNode
        include SampleRateHelper
        node_traits memory: :none

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

          # Where it was made, for messages: "path:line" lines in one frozen
          # String (Internal.creation_trace; omnibus13: was 24 Locations kept
          # for the graph's life)
          @callers = Internal.creation_trace(skip: [__FILE__])
          @cb = block
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

        # Plan layer (see MB::Sound::Plan): a Ruby block is never fused.
        include Plan::Describable

        def plan_unsupported_reason
          'a Ruby block'
        end
      end
    end
  end
end
