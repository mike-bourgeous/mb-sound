module MB
  module Sound
    module GraphNode
      # A signal graph node that switches from input node to input node as each
      # input node runs out of data.  See GraphNode#and_then.
      #
      # Note that some input sources, such as IO objects and Tones, will pad
      # their outputs to fill an entire buffer size, so the sequence may be a
      # handful of samples longer than expected.
      class NodeSequence
        include GraphNode

        # See GraphNode#sources.
        attr_reader :sources

        # Creates a node sequence with the given sources (either Numo::NArrays
        # or a GraphNodes) to play in order.
        def initialize(*sources)
          @sources = nil
          @current_sources = nil
          @circbuf = MB::Sound::CircularBuffer.new(buffer_size: 48000, complex: false, double: false)

          and_then(*sources)
        end

        # Retrieves the next +count+ samples of audio from the current source, or
        # returns nil if all sources have run out of data.  Sources are
        # stitched together gaplessly unless the source itself zero-pads its
        # output.  If the final source returns too few samples to reach
        # +count+, then the buffer will be zero-padded to +count+ samples.
        def sample(count)
          return nil if @circbuf.empty? && @current_sources.empty?

          while @circbuf.length < count && @current_sources.any?
            buf = @current_sources[0].sample(count)

            if buf.nil? || buf.empty?
              @current_sources.shift
            else
              @circbuf.write(buf)
            end
          end

          if @circbuf.length == 0
            nil
          elsif @circbuf.length < count
            MB::M.zpad(@circbuf.read(@circbuf.length), count)
          else
            @circbuf.read(MB::M.min(count, @circbuf.length))
          end
        end

        # Adds the given sources (wrapping Numo::NArray with ArrayInput) to the
        # sequence.  This method allows chaining GraphNode#and_then in the
        # GraphNode DSL without building more NodeSequence objects.
        def and_then(*sources)
          sources = sources[0] if sources.length == 1 && sources[0].is_a?(Array)

          # FIXME: ArrayInput (thorugh IOSampleMixin) and Tone always return a
          # full buffer even if they've exceeded their duration.  It would
          # probably be better to move zero-padding as far toward the end of a
          # signal chain as possible, ideally at the point of generating
          # output.
          source_list = Array(sources).map { |s|
            if s.is_a?(Numo::NArray)
              ArrayInput.new(data: [s])
            else
              s
            end
          }.freeze

          if @sources
            @sources = (@sources + source_list).freeze
            @current_sources += source_list
          else
            @sources = source_list
            @current_sources = @sources.dup
          end

          self
        end
      end
    end
  end
end
