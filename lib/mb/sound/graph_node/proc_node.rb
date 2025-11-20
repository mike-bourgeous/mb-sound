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
        def initialize(source, extra_sources = {}, sample_rate: nil, type_name: nil, &block)
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
      end
    end
  end
end
