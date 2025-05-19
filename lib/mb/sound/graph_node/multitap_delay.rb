require 'forwardable'

module MB
  module Sound
    module GraphNode
      # A delay object, simplified from the Filter::Delay class, plus support
      # for multiple delay taps from a single input stream.
      #
      # Use GraphNode#multitap_delay to create a multi-tap delay in a graph.
      class MultitapDelay
        include SampleRateHelper

        # One output tap from the multitap delay.
        class DelayTap
          extend Forwardable

          include GraphNode
          include SampleRateHelper

          # Graph nodes or numeric values that feed into this delay tap for
          # audio or delay time.
          attr_reader :sources

          # The index of this tap in the parent MultitapDelay.
          attr_reader :index

          def_delegators :@mtd, :sample_rate

          # Called by MultitapDelay to create an output node for each delay tap.
          #
          # +:mtd+ - The containing MultitapDelay object.
          # +:index+ - The index of this tap.
          # +:delay+ - The delay source for this tap.
          def initialize(mtd:, index:, delay_samples:)
            @mtd = mtd
            @index = index

            @graph_node_name = "Tap #{index}"

            case delay_samples
            when Numeric
              @delay_samples = delay_samples.constant

            else
              raise 'Delay must be Numeric or respond to :sample' unless delay_samples.respond_to?(:sample)
              check_rate(delay_samples, index)
              @delay_samples = delay_samples
            end

            # TODO: Support per-tap feedback into all taps?
            # TODO: Support per-tap feedback just into that tap?

            @sources = [@delay_samples, @mtd].freeze
          end

          # Returns +count+ samples from this delay tap, based on the delay
          # that was given to MultitapDelay#initialize.
          def sample(count)
            delay_buf = @delay_samples.sample(count)
            return nil if delay_buf.nil?

            @mtd.internal_sample(self, delay_buf)
          end

          # Changes the sample rate of all taps on this multitap delay and all
          # upstream nodes.
          def sample_rate=(new_rate)
            super
            @mtd.sample_rate = new_rate
            self
          end
          alias at_rate sample_rate=
        end

        # An Array of the individual output nodes.
        attr_reader :taps

        # The input node whose audio is delayed.
        attr_reader :source

        # An Array of sources that feed the parent multi-tap delay (for
        # GraphNode compatibility; just contains the source node).
        attr_reader :sources

        # The name of the overall delay parent object (for GraphNode
        # compatibility).  See #named.
        attr_reader :graph_node_name

        # Sample rate used for converting delay times to delays in samples.
        attr_reader :sample_rate

        # Creates a MultitapDelay that samples audio from one +source+ graph
        # node and produces output tap nodes for each source +delay_in_seconds+
        # (Numeric or GraphNode).
        def initialize(source, *delays_in_seconds, initial_buffer_seconds: 1, sample_rate: 48000)
          raise 'Delay audio source must respond to :sample' unless source.respond_to?(:sample)

          @graph_node_name = nil
          @named = false

          @sample_rate = sample_rate.to_f
          @sample_rate_node = @sample_rate.constant
          @source = source
          @sources = [source].freeze

          # Keeps track of which delays have already been processed, so we know
          # when a new graph frame has started and don't over-sample the input.
          @sampled = Set.new

          if delays_in_seconds.empty?
            raise 'No delay taps were provided; give Numeric or GraphNode values for delays'
          end

          @taps = delays_in_seconds.map.with_index { |d, idx|
            DelayTap.new(
              mtd: self,
              index: idx,
              delay_samples: d * @sample_rate_node
            )
          }

          @write_offset = 0
          @read_offset = 0 # Previous write offset, not delay read point
          @buf = Numo::SFloat[0]
          @audio_buf = nil
          update_buf(Numo::SFloat, (initial_buffer_seconds * sample_rate).ceil)
        end

        # Sets the name of the overarching multi-tap delay node (kind of a
        # placeholder node in the graph to show the common parentage of the
        # individual delay tap nodes).
        def named(s)
          @graph_node_name = s&.to_s
          @named = true
          self
        end

        # Returns true if a custom name has been assigned to this parent delay
        # container.
        def named?
          @named
        end

        # Changes the sample rate of the delay and all upstream nodes.
        def sample_rate=(new_rate)
          super
          @sample_rate = sample_rate.to_f
          @sample_rate_node.constant = @sample_rate
          self
        end
        alias at_rate sample_rate=

        # Do not use directly.  Called by DelayTap#sample to retrieve the
        # delayed output for a given tap.
        def internal_sample(tap, delay_buf)
          max_delay = delay_buf.max.ceil
          # Ensure there are at least three buffers for delay increases without dropouts
          max_delay = delay_buf.length if max_delay < delay_buf.length

          if @sampled.include?(tap.index)
            if @sampled.length < @taps.length
              warn "Delay tap #{tap} on #{self} sampled again with #{@sampled.length} of #{@taps.length} sampled"
            end

            @sampled.clear
            @audio_buf = nil
          end

          if @audio_buf.nil?
            # TODO: drain the delay buffer if the audio stops?  Or rely on
            # .and_then in graph DSL to append silence?
            @audio_buf = @source.sample(delay_buf.length)
            return nil if @audio_buf.nil?

            update_buf(@audio_buf.class, @audio_buf.length + 2 * max_delay)

            MB::M.circular_write(@buf, @audio_buf, @write_offset)

            @read_offset = @write_offset
            @write_offset = (@write_offset + @audio_buf.length) % @buf.length
          else
            update_buf(@audio_buf.class, @audio_buf.length + 2 * max_delay)
            @read_offset = (@write_offset - @audio_buf.length) % @buf.length
          end

          @sampled << tap.index

          # TODO: Only allocate one complex buffer per tap if needed instead of
          # reallocating every iteration
          if (delay_buf.is_a?(Numo::SFloat) || delay_buf.is_a?(Numo::DFloat)) &&
              @buf.is_a?(Numo::SComplex) || @buf.is_a?(Numo::DComplex)
            delay_buf = Numo::SComplex.cast(delay_buf)
          end

          result = delay_buf.inplace!.map_with_index { |d, idx|
            d = d.real
            d = 0 if d < 0
            d = @buf.length - 1 if d >= @buf.length - 1

            d1 = d.floor
            d2 = d.ceil
            delta = d - d1

            o1 = (@read_offset - d1 + idx) % @buf.length
            o2 = (@read_offset - d2 + idx) % @buf.length

            v1 = @buf[o1]
            v2 = @buf[o2]

            v2 * (1.0 - delta) + v1 * delta
          }.not_inplace!

          result
        end

        private

        # TODO: There's got to be a way to abstract this common buffer
        # management that occurs in a lot of different classes
        # 
        # TODO: maybe use BufferHelper
        def update_buf(type, min_length)
          length = min_length
          length = @buf.length if @buf.length > min_length

          if @buf.is_a?(Numo::SFloat) && (type == Numo::SComplex || type == Numo::DComplex)
            @buf = Numo::SComplex.cast(@buf)
          end

          if @buf.length < min_length
            old_buf = @buf
            @buf = @buf.class.new(min_length).allocate
            @buf[0...old_buf.length] = old_buf
            @buf[old_buf.length..-1].fill(0)
          end
        end
      end
    end
  end
end
