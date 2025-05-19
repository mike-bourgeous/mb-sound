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
        def arithmetic_sample(count, sources:, pad:, fill:, stop_early:)
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

          inputs = sources.map.with_index { |(s, extra), idx|
            complex ||= extra.is_a?(Complex)

            v = s.sample(count)&.not_inplace!
            next if v.nil? || v.empty?

            if v.length > count
              warn("Source #{idx} gave #{self} more data than requested: #{min_length}/#{max_length} vs #{count}")
            end

            min_length = v.length if v.length < min_length
            max_length = v.length if v.length > max_length

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
              raise "Tried to truncate inputs more than once -- an upstream node gave a short read repeatedly"
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

        protected

        # Checks the sample rate of the +other+ node, either setting this
        # node's sample rate to match, or setting the +other+ node's sample
        # rate to match.  Raises an error if the +other+ node does not support
        # changing sample rates and the rate does not match.
        def check_rate(other, idx = sources.length)
          if other.respond_to?(:sample_rate)
            @sample_rate ||= other.sample_rate
            if other.sample_rate != @sample_rate
              if other.respond_to?(:sample_rate=)
                other.sample_rate = @sample_rate
              elsif other.respond_to?(:at_rate)
                other.at_rate(@sample_rate)
              else
                raise "Source #{idx}/#{other} sample rate is #{other.sample_rate}; expected #{@sample_rate}"
              end
            end
          end
        end
      end
    end
  end
end
