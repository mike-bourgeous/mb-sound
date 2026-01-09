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
        include SampleRateHelper

        # The 0-based index of the active node in the sequence.
        attr_reader :current_node

        # Creates a node sequence with the given sources (either Numo::NArrays
        # or a GraphNodes) to play in order.
        def initialize(*sources, sample_rate: nil)
          @sources = nil
          @current_sources = nil
          @sample_rate = sample_rate
          @current_node = 0
          @node_type_name = "NodeSequence(node=0)"

          and_then(*sources)

          unless @sample_rate
            raise "No sources provided a sample rate.  Provide a sample_rate parameter to the constructor."
          end

          @circbuf = MB::Sound::CircularBuffer.new(buffer_size: @sample_rate.ceil, complex: false, double: false)
        end

        # Retrieves the next +count+ samples of audio from the current source, or
        # returns nil if all sources have run out of data.  Sources are
        # stitched together gaplessly unless the source itself zero-pads its
        # output.  If the final source returns too few samples to reach
        # +count+, then the short buffer will be returned as-is.
        def sample(count)
          return nil if @circbuf.empty? && @current_sources.empty?

          # TODO: Preserve depleted sources so node graphs can be reset or looped
          while @circbuf.length < count && @current_sources.any?
            buf = @current_sources[0].sample(count)

            if buf.nil? || buf.empty?
              @current_node += 1
              @current_sources.shift
              @node_type_name = "NodeSequence(node=#{@current_node})"
            else
              if @circbuf.available < buf.length
                @circbuf = @circbuf.dup(@circbuf.buffer_size + buf.length)
              end

              @circbuf.write(buf)
            end
          end

          if @circbuf.length == 0
            nil
          else
            @circbuf.read(MB::M.min(count, @circbuf.length))
          end
        end

        # Adds the given sources (wrapping Numo::NArray with ArrayInput) to the
        # sequence.  This method allows chaining GraphNode#and_then in the
        # GraphNode DSL without building more NodeSequence objects.
        def and_then(*sources)
          sources = sources[0] if sources.length == 1 && sources[0].is_a?(Array)

          # FIXME: ArrayInput (through IOSampleMixin) and Tone always return a
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

          source_list.each_with_index do |s, idx|
            if s.respond_to?(:sample_rate)
              @sample_rate ||= s.sample_rate
              if s.sample_rate != @sample_rate
                raise "Source #{idx}/#{s} sample rate #{s.sample_rate} does not match sequence rate #{@sample_rate}"
              end
            end
          end

          if @sources
            @sources = (@sources + source_list).freeze
            @current_sources += source_list
          else
            @sources = source_list
            @current_sources = @sources.dup
          end

          self
        end

        # See GraphNode#sources.
        def sources
          @sources.map.with_index { |src, idx|
            [:"input_#{idx + 1}", src]
          }.to_h
        end
      end
    end
  end
end
