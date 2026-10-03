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
        include MultiOutput

        # One output tap from the multitap delay.
        class DelayTap
          extend Forwardable

          include GraphNode
          include SampleRateHelper
          include NodeOutput

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
          # +:smoothing+ - Delay smoothing, as for Filter::Delay (false for
          #                none).
          def initialize(mtd:, index:, delay_samples:, smoothing: false)
            @owner = mtd
            @mtd = mtd
            @index = index

            @graph_node_name = "Tap #{index}"

            case delay_samples
            when Numeric
              @delay_samples = delay_samples.constant(unit: ' samples', si: false)

            else
              raise 'Delay must be Numeric or respond to :sample' unless delay_samples.respond_to?(:sample)
              check_rate(delay_samples, index)
              @delay_samples = delay_samples.get_sampler
            end

            # TODO: Support per-tap feedback into all taps?
            # TODO: Support per-tap feedback just into that tap?

            @sources = {
              delay_samples: @delay_samples,
              multitap_delay: @mtd,
            }.freeze

            # This tap's previous delay, for the read speed (sinc)
            @read_state = []

            # Starts at the first delay instead of gliding up from zero
            @smoother = MB::Sound::DelayLine.smoother(smoothing, mtd.sample_rate)
            @smoother_started = false
          end

          # Returns +count+ samples from this delay tap, based on the delay
          # that was given to MultitapDelay#initialize.
          def sample(count)
            delay_buf = @delay_samples.sample(count)
            return nil if delay_buf.nil?

            if @smoother
              delay_buf = delay_buf.real if delay_buf.is_a?(Numo::SComplex) || delay_buf.is_a?(Numo::DComplex)
              unless @smoother_started
                @smoother.reset(delay_buf[0])
                @smoother_started = true
              end
              delay_buf = MB::Sound::DelayLine.smooth(@smoother, delay_buf)
            end

            @mtd.internal_sample(self, delay_buf, @read_state)
          end

          # Changes the sample rate of all taps on this multitap delay and all
          # upstream nodes.
          def sample_rate=(new_rate)
            super
            @mtd.sample_rate = new_rate
            @smoother = @smoother&.at_rate(new_rate)
            self
          end
          alias at_rate sample_rate=
        end

        # An Array of the individual output nodes.
        attr_reader :taps

        # The input node whose audio is delayed.
        attr_reader :source

        # A Hash of sources that feed the parent multi-tap delay (for GraphNode
        # compatibility; just contains the source node).
        attr_reader :sources

        # The name of the overall delay parent object (for GraphNode
        # compatibility).  See #named.
        attr_reader :graph_node_name

        # Sample rate used for converting delay times to delays in samples.
        attr_reader :sample_rate

        # How fractional delays are interpolated (see
        # MB::Sound::DelayLine::INTERPOLATION).
        attr_reader :interpolation

        # Creates a MultitapDelay that samples audio from one +source+ graph
        # node and produces output tap nodes for each source +delay_in_seconds+
        # (Numeric or GraphNode).
        #
        # +:interpolation+ chooses how fractional delays are read: :linear,
        # :cubic, or :sinc (see MB::Sound::DelayLine).
        #
        # +:smoothing+ glides each tap's delay changes as for Filter::Delay
        # (true, a rate in seconds per second, or a Filter); off by default,
        # so delay jumps (e.g. a ramp restarting) stay jumps.
        def initialize(source, *delays_in_seconds, initial_buffer_seconds: 1, sample_rate: 48000, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, smoothing: false)
          unless MB::Sound::DelayLine::INTERPOLATION.include?(interpolation)
            raise ArgumentError, "Unknown interpolation #{interpolation.inspect} (use one of #{MB::Sound::DelayLine::INTERPOLATION.keys.join(', ')})"
          end
          @interpolation = interpolation

          raise 'Delay audio source must respond to :sample' unless source.respond_to?(:sample)

          @graph_node_name = nil
          @named = false

          # TODO: is the sample_rate_node needed?
          @sample_rate = sample_rate.to_f
          @sample_rate_node = @sample_rate.constant(smoothing: false, unit: 'Hz')
          @source = source.get_sampler
          @sources = { input: @source }.freeze

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
              delay_samples: d * @sample_rate_node,
              smoothing: smoothing
            )
          }

          @line = MB::Sound::DelayLine.new((initial_buffer_seconds * sample_rate).ceil)
          @audio_buf = nil
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
        # delayed output for a given tap.  The first tap sampled in each graph
        # frame reads the input and writes it to the shared delay line; every
        # tap then reads the line at its own delays.
        def internal_sample(tap, delay_buf, state = nil)
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

            @line.prepare(@audio_buf.length, delay_buf.max.real.ceil, @audio_buf.class)
            @line.write(@audio_buf)
          else
            # Later taps may have longer delays (growing keeps the block)
            @line.prepare(@audio_buf.length, delay_buf.max.real.ceil, @audio_buf.class)
          end

          @sampled << tap.index

          @line.read(MB::M.min(delay_buf.length, @audio_buf.length), delay_buf, interpolation: @interpolation, state: state)
        end
      end
    end
  end
end
