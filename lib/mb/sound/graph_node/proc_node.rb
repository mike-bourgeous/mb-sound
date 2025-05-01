module MB
  module Sound
    module GraphNode
      # A signal-processing graph node that calls a given Ruby Proc with each
      # buffer retrieved from the source, with the result of the Proc returned
      # from the #sample method.
      class ProcNode
        include GraphNode

        attr_reader :sources, :source, :callers, :sample_rate

        # Initializes a graph node that calls the +block+ with the result of the
        # +source+'s sample method when this object's #sample method is called.
        # The +extra_sources+ parameter can be used if the +block+ retrieves data
        # from more graph nodes than just +source+, so that graph searching
        # methods still work.
        def initialize(source, extra_sources = nil, sample_rate: nil, &block)
          @graph_node_name = block.source_location&.join(':')
          @source = source
          @sources = [source, *extra_sources].freeze

          @sample_rate = sample_rate

          @sources.each_with_index do |s, idx|
            if s.respond_to?(:sample_rate)
              @sample_rate ||= s.sample_rate
              if s.sample_rate != @sample_rate
                raise "Source #{idx}/#{s} sample rate #{s.sample_rate} does not match expected rate #{@sample_rate}"
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
