module MB
  module Sound
    # A signal graph node that switches from input node to input node as each
    # input node runs out of data.
    class NodeSequence
      include GraphNode

      # See GraphNode#sources.
      attr_reader :sources

      # Creates a node sequence with the given sources to play in order.
      def initialize(sources)
        @sources = Array(sources).map { |s|
          if s.is_a?(Numo::NArray)
            ArrayInput.new(data: [s])
          else
            s
          end
        }.freeze

        @current_sources = @sources.dup
      end

      # Retrieves the next +count+ samples of audio from the current source, or
      # returns nil if all sources have run out of data.  If a source returns
      # fewer than +count+ samples, then the buffer will be zero-padded to
      # +count+ samples.
      def sample(count)
        buf = nil

        while (buf.nil? || buf.empty?) && !@current_sources.empty?
          buf = @current_sources[0].sample(count)

          if buf.nil? || buf.empty?
            @current_sources.shift
          elsif buf.length < count
            buf = MB::M.zpad(buf, count)
          end
        end

        buf
      end
    end
  end
end
