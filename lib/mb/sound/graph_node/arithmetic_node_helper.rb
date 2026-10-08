module MB
  module Sound
    module GraphNode
      # Common functions for nodes that perform arithmetic operations on
      # multiple inputs, like Mixer and Mulitiplier.
      #
      # Any GraphNode using this helper must also include BufferHelper.
      module ArithmeticNodeHelper
        # TODO: should there be an actual standalone ArithmeticNode?
        # TODO: asking users to set instance variables isn't a great API

        # Implements most of the #sample method by retrieving buffers from each
        # of the sources, skipping empty or nil buffers, padding or truncating
        # as necessary, and stopping when defined by +:stop_early+.
        #
        # +count+ is the number of samples to read, +:sources+ is the list of
        # nodes to read from (a Hash where the node is the key), +:pad+ is the
        # value to use for padding any buffers, +:fill+ is the value to use
        # for filling the output buffer before yielding.
        #
        # Yields the output buffer and the list of inputs and their associated
        # data (if any) (an Array of two-element Arrays).  Returns the output
        # buffer.
        def arithmetic_sample(count, sources:, pad:, fill:, stop_early:, &block)
          sampled = sources.map { |s, extra| [s.sample(count), extra] }
          arithmetic_combine(count, sampled, sources: sources, pad: pad, fill: fill, stop_early: stop_early, &block)
        end

        # Samples +count+ samples from each of +sources+ (a Hash from node to
        # extra data), returning [buffer, extra] pairs in order like
        # #arithmetic_sample, but in an Array (and pairs) reused by every
        # call, so a buffer allocates nothing here.  The result is only valid
        # until the next call.
        def arithmetic_inputs(count, sources)
          sampled = (@arithmetic_sampled ||= [])
          if sampled.length != sources.length
            sampled.clear
            sources.length.times { sampled << [nil, nil] }
          end

          idx = 0
          sources.each do |s, extra|
            pair = sampled[idx]
            pair[0] = s.sample(count)
            pair[1] = extra
            idx += 1
          end

          sampled
        end

        # The rest of #arithmetic_sample, for inputs already sampled: +sampled+
        # is an Array of [buffer or nil, extra data] in the order of
        # +sources+.  Used directly by nodes with a fast path for the common
        # case (see Multiplier#sample).
        def arithmetic_combine(count, sampled, sources:, pad:, fill:, stop_early:)
          complex = @bufcomplex
          complex ||= @constant.is_a?(Complex) if defined?(@constant)
          complex ||= fill.is_a?(Complex)
          complex ||= pad.is_a?(Complex)

          # There might not be any sources to set min and max length.  If so,
          # set them explicitly.
          if sources.empty?
            min_length = count
            max_length = count
          else
            min_length = Float::INFINITY
            max_length = 0
          end

          inputs = sampled.map.with_index { |(v, extra), idx|
            complex ||= extra.is_a?(Complex)

            v = v&.not_inplace!
            next if v.nil? || v.empty?

            min_length = v.length if v.length < min_length
            max_length = v.length if v.length > max_length

            if v.length > count
              warn("Source #{idx} gave #{self} more data than requested: #{min_length}/#{max_length}/#{v.length} vs #{count}")
            end

            expand_buffer(v)

            [v, extra]
          }

          inputs.compact!

          # Ensure the buffer type is promoted even if there are no inputs
          promote_buffer(complex: complex) if complex

          if stop_early
            return nil if inputs.length != sources.length

            @truncated ||= false
            if @truncated && max_length > min_length
              raise 'Tried to truncate inputs more than once -- an upstream node gave a short read repeatedly'
            end

            # Truncate if stop_early is true
            inputs = inputs.map { |v, extra|
              if v.length > min_length
                @truncated = true
                v = v[0...min_length]
              end
              [v, extra]
            }

            retbuf = @buf[0...min_length]
          else
            return nil if inputs.empty? && !sources.empty?

            # Pad if stop_early is false
            inputs = inputs.map { |v, extra|
              v = MB::M.pad(v, max_length, value: pad) if v.length < max_length
              [v, extra]
            }

            retbuf = @buf[0...max_length]
          end

          retbuf.fill(fill)

          yield retbuf, inputs

          retbuf.not_inplace!
        end

        # Input buffer classes that never promote a buffer of each class (the
        # same precision, or real into complex).
        FAST_INPUTS = {
          Numo::SFloat => [Numo::SFloat].freeze,
          Numo::DFloat => [Numo::DFloat].freeze,
          Numo::SComplex => [Numo::SComplex, Numo::SFloat].freeze,
          Numo::DComplex => [Numo::DComplex, Numo::DFloat].freeze,
        }.freeze

        # For the fast paths: true if every input in +sampled+ ([buffer,
        # extra] pairs) is a full +count+-sample buffer that wouldn't promote
        # this node's buffer type (the same type, or real into complex), the
        # buffers are large enough, and no extra data or +fill+ would promote
        # it either, so the general path would do exactly the same
        # arithmetic.
        def arithmetic_fast?(count, sampled, fill)
          return false if @buf.nil? || @buf.length < count
          return false if !@bufcomplex && fill.is_a?(Complex)

          ok = FAST_INPUTS[@buf.class]
          return false unless ok

          sampled.all? { |v, extra|
            v && v.length == count && ok.include?(v.class) && (@bufcomplex || !extra.is_a?(Complex))
          }
        end

        # True if this node's buffer has been promoted to complex (a plan
        # then computes complex values even from real inputs, as the node
        # does).
        def plan_complex_buffer?
          @buf.is_a?(Numo::SComplex) || @buf.is_a?(Numo::DComplex)
        end

        # A view of the first +count+ samples of +buf+, reused while the
        # buffer and count stay the same.
        def arithmetic_view(buf, count, key)
          @arithmetic_views ||= {}
          cached = @arithmetic_views[key]
          return cached[2] if cached && cached[0].equal?(buf) && cached[1] == count

          view = buf[0...count]
          @arithmetic_views[key] = [buf, count, view]
          view
        end
      end
    end
  end
end
