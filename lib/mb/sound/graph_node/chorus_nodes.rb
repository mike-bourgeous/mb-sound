module MB
  module Sound
    module GraphNode
      module Chorus
        # Passes a chorus input through until it ends (returns nil or a short
        # buffer), then plays zeros for +tail+ seconds so the delay rings
        # out, then ends (nil).
        class Tail
          include GraphNode
          include SampleRateHelper

          # The source node.
          attr_reader :source

          def initialize(source, tail)
            @source = source.get_sampler
            @sample_rate = @source.sample_rate
            @tail = tail
            @left = nil
            @buf = nil
          end

          # True once the source has ended (even while the tail plays).  Not
          # named #ended? so script runners don't wait for it.
          def input_ended?
            !@left.nil?
          end

          # Returns +count+ samples of the source, then zeros for the tail,
          # then nil.
          def sample(count)
            if @left.nil?
              data = @source.sample(count)
              return data if data && data.length == count

              # The padding of this buffer counts as tail
              @left = (@tail * @sample_rate).ceil - (count - (data ? data.length : 0))
              @buf = (data ? data.class : Numo::SFloat).zeros(count)
              @buf[0...data.length] = data if data && data.length > 0
              return @buf
            end

            return nil if @left <= 0
            n = MB::M.min(count, @left)
            @left -= n
            @buf = Numo::SFloat.zeros(n) if @buf.length != n
            @buf.fill(0)
          end

          def sources
            { input: @source }
          end
        end

        # The BBD hiss: passes +noise+ until every chorus input (Tail) ended,
        # or every ending node upstream (+enders+, e.g. an effect script's
        # Ringdown) ended, then fades it out over +tail+ seconds and plays
        # silence, so renders end once the delay has rung out.
        class HissGate
          include GraphNode
          include SampleRateHelper

          # The noise source.
          attr_reader :source

          def initialize(noise, inputs, enders, tail)
            @source = noise.get_sampler
            @sample_rate = @source.sample_rate
            @inputs = inputs
            @enders = enders
            @tail = tail
            @faded = nil
            @zeros = nil
          end

          # True once the input has ended (the hiss is fading or off).
          def fading?
            !@faded.nil?
          end

          def sample(count)
            if @faded.nil?
              return @source.sample(count) unless @inputs.all?(&:input_ended?) || (!@enders.empty? && @enders.all?(&:ended?))
              @faded = 0
            end

            length = (@tail * @sample_rate).ceil
            if @faded >= length
              @zeros = Numo::SFloat.zeros(count).freeze if @zeros.nil? || @zeros.length != count
              return @zeros
            end

            ramp = 1.0 - (Numo::SFloat.new(count).seq + @faded) / length
            @faded += count
            @source.sample(count) * ramp.clip(0, 1)
          end

          def sources
            { input: @source }
          end
        end
      end
    end
  end
end
