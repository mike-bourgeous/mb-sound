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
          # +:delay+ - The delay time for this tap (any time Filter::Delay#delay=
          #            accepts: seconds, lengths, Durations, graph nodes).
          # +:smoothing+ - Delay smoothing, as for Filter::Delay (false for
          #                none).
          def initialize(mtd:, index:, delay:, smoothing: false)
            @owner = mtd
            @mtd = mtd
            @index = index

            @graph_node_name = "Tap #{index}"

            @time = MB::Sound::Length::Source.new(delay)
            check_rate(@time.node, index) if @time.node?

            # TODO: Support per-tap feedback into all taps?
            # TODO: Support per-tap feedback just into that tap?

            @sources = {
              **(@time.node? ? { delay: @time.node } : {}),
              multitap_delay: @mtd,
            }.freeze

            # This tap's previous delay, for the read speed (sinc)
            @read_state = []

            # Starts at the first delay instead of gliding up from zero
            @smoothing = smoothing
            @smoother = MB::Sound::DelayLine.smoother(smoothing, mtd.sample_rate)
            @smoother_started = false
          end

          # The delay time as given.
          def delay
            @time.length
          end

          # The longest delay in samples at +sample_rate+, if known.
          def max_delay_samples(sample_rate)
            @time.max_samples(sample_rate)
          end

          # Returns +count+ samples from this delay tap, based on the delay
          # that was given to MultitapDelay#initialize.
          def sample(count)
            delays = @time.samples(count, sample_rate)
            return nil if delays.nil?

            if @smoother
              delays = delays.real if delays.is_a?(Numo::SComplex) || delays.is_a?(Numo::DComplex)
              unless @smoother_started
                @smoother.reset(delays.is_a?(Numeric) ? delays : delays[0])
                @smoother_started = true
              end
              delays = Numo::SFloat.new(count).fill(delays) if delays.is_a?(Numeric)
              delays = MB::Sound::DelayLine.smooth(@smoother, delays)
            end

            @mtd.internal_sample(self, count, delays, @read_state)
          end

          # Changes the sample rate of all taps on this multitap delay and all
          # upstream nodes.
          def sample_rate=(new_rate)
            old_rate = @mtd.sample_rate
            super
            @mtd.sample_rate = new_rate
            @smoother = MB::Sound::DelayLine.rescale_smoother(@smoother, @smoothing, old_rate, @mtd.sample_rate)
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
        # node and produces output tap nodes for each of the +delays+ (any
        # time Filter::Delay#delay= accepts: seconds, lengths like
        # `96.samples`, Durations, graph nodes), which keep their units when
        # the sample rate changes.  +:initial_buffer+ (any length) sizes the
        # starting buffer; it grows as needed.
        #
        # +:interpolation+ chooses how fractional delays are read: :linear,
        # :cubic, or :sinc (see MB::Sound::DelayLine).
        #
        # +:smoothing+ glides each tap's delay changes as for Filter::Delay
        # (true, a rate in seconds per second, or a Filter); off by default,
        # so delay jumps (e.g. a ramp restarting) stay jumps.
        def initialize(source, *delays, initial_buffer: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, smoothing: false)
          unless MB::Sound::DelayLine::INTERPOLATION.include?(interpolation)
            raise ArgumentError, "Unknown interpolation #{interpolation.inspect} (use one of #{MB::Sound::DelayLine::INTERPOLATION.keys.join(', ')})"
          end
          @interpolation = interpolation

          raise 'Delay audio source must respond to :sample' unless source.respond_to?(:sample)

          @graph_node_name = nil
          @named = false

          @sample_rate = source.sample_rate.to_f
          @source = source.get_sampler
          @sources = { input: @source }.freeze

          # Keeps track of which delays have already been processed, so we know
          # when a new graph frame has started and don't over-sample the input.
          @sampled = Set.new

          if delays.empty?
            raise ArgumentError, 'No delay taps were provided; give delay times (seconds, lengths, Durations, or graph nodes)'
          end

          @taps = delays.map.with_index { |d, idx|
            DelayTap.new(mtd: self, index: idx, delay: d, smoothing: smoothing)
          }

          longest = @taps.filter_map { |t| t.max_delay_samples(@sample_rate) }.max
          initial = MB::Sound::Length.samples(initial_buffer, sample_rate: @sample_rate)
          initial = 1.1 * longest if longest && initial < 1.1 * longest
          @line = MB::Sound::DelayLine.new(initial.ceil)
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
          self
        end
        alias at_rate sample_rate=

        # Do not use directly.  Called by DelayTap#sample to retrieve the
        # delayed output for a given tap.  The first tap sampled in each graph
        # frame reads the input and writes it to the shared delay line; every
        # tap then reads the line at its own delays.
        def internal_sample(tap, count, delays, state = nil)
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
            @audio_buf = @source.sample(delays.is_a?(Numeric) ? count : delays.length)
            return nil if @audio_buf.nil?
          end

          # Later taps may have longer delays (growing keeps the block)
          longest = delays.is_a?(Numeric) ? delays : delays_max(delays)
          @line.prepare(@audio_buf.length, longest.ceil, @audio_buf.class)
          @line.write(@audio_buf) unless @sampled.any?

          @sampled << tap.index

          length = delays.is_a?(Numeric) ? @audio_buf.length : MB::M.min(delays.length, @audio_buf.length)
          # Each tap reads into its own reused buffer
          out = (@tap_bufs ||= {})[tap.index]
          out = @tap_bufs[tap.index] = @line.buffer_class.zeros(length) unless out && out.class == @line.buffer_class && out.length == length
          @line.read(length, delays, interpolation: @interpolation, state: state, out: out)
        end

        private

        # delays.max.real without allocating for real buffers
        # (FastArithmetic.min_max gives Numo's max).
        def delays_max(delays)
          r = (@delay_range ||= [0.0, 0.0])
          MB::Sound::FastArithmetic.min_max(delays, r) ? r[1] : delays.max.real
        end
      end
    end
  end
end
