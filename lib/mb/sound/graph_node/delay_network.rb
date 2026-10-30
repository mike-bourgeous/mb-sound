require 'forwardable'

module MB
  module Sound
    module GraphNode
      # A network of delay lines with regenerating taps (delay-fx-1): each
      # line has an input (a graph node, or none), each tap reads one line at
      # its own delay time, and a gain matrix feeds every tap back into every
      # line, one sample at a time in C (MB::Sound::FastDelay.network, exact
      # Ruby mirror MB::Sound::DelayLine.network_ruby).  Covers:
      #
      # - multitap feedback (one line, N taps, a 1 x N gain row):
      #   `sig.multitap(t1, t2, feedback: [g1, g2])`;
      # - ping-pong and cross-feedback (two lines, a 2 x 2 matrix):
      #   `sig.ping_pong(1.n8, feedback: 0.6)` (see DelayMethods#ping_pong).
      #
      # Each sample writes every line's input, reads every tap (delays count
      # from the sample being written, as for Filter::Delay's feedback, so a
      # tap at 0 reads the input itself), then adds each gain times its tap
      # to what its line got.  Delay times are anything Filter::Delay
      # accepts (seconds, lengths, Durations, graph nodes), smoothed when
      # +:smoothing+ is given; gains are numbers or graph nodes (per sample).
      # The output is the same at any buffer size.
      #
      # When every input has ended (nil or a short buffer), the network
      # rings out: silence goes in and the taps play until what the lines
      # get back has stayed below -90 dB (MB::Sound::QuietRun#advance) for the
      # longest delay plus the interpolation reach, ending on that exact
      # sample (with no feedback, one longest delay after the input, as for
      # MultitapDelay).  A loop gain of 1 or more never ends.
      #
      # Every tap must be read in turn every buffer (as a Session does): the
      # first tap read in a buffer runs the whole network.  A plan boundary.
      class DelayNetwork
        include SampleRateHelper
        include MultiOutput
        node_traits memory: :long

        # One output tap of a DelayNetwork.
        class Tap
          extend Forwardable

          include GraphNode
          include SampleRateHelper
          include NodeOutput
          node_traits memory: :none

          # The delay time node (if any) and the network.
          attr_reader :sources

          # The index of this tap in its network, and the line it reads.
          attr_reader :index, :line

          def_delegators :@network, :sample_rate

          # Called by DelayNetwork for each tap.
          def initialize(network:, index:, line:, delay:, smoothing: false)
            @owner = network
            @network = network
            @index = index
            @line = line
            @graph_node_name = "Tap #{index}"

            @time = MB::Sound::Length::Source.new(delay)
            check_rate(@time.node, index) if @time.node?

            @sources = {
              **(@time.node? ? { delay: @time.node } : {}),
              delay_network: @network,
            }.freeze

            @read_state = []
            @smoothing = smoothing
            @smoother = MB::Sound::DelayLine.smoother(smoothing, network.sample_rate)
            @smoother_started = false
          end

          # The longest delay in samples at +sample_rate+, if known.
          def max_delay_samples(sample_rate)
            @time.max_samples(sample_rate)
          end

          # Returns +count+ samples of this tap (see DelayNetwork).
          def sample(count)
            @network.internal_sample(self, count)
          end

          # Do not use directly: the delays for this buffer (a Numeric or a
          # per-sample NArray in samples, smoothed if smoothing is on), or
          # nil if the delay time node ended.
          def network_delays(count)
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
            delays
          end

          # Do not use directly: this tap's read state ([previous delay]).
          def network_read_state
            @read_state
          end

          # Changes the sample rate of the whole network and its upstream
          # nodes.
          def sample_rate=(new_rate)
            old_rate = @network.sample_rate
            super
            @network.sample_rate = new_rate
            @smoother = MB::Sound::DelayLine.rescale_smoother(@smoother, @smoothing, old_rate, @network.sample_rate)
            self
          end
          alias at_rate sample_rate=
        end

        # The output taps (Tap nodes), in order.
        attr_reader :taps

        # Line inputs, gain nodes (GraphNode compatibility).
        attr_reader :sources

        # The network's name (see #named).
        attr_reader :graph_node_name

        attr_reader :sample_rate

        # How fractional delays are read (see MB::Sound::DelayLine).
        attr_reader :interpolation

        # The gain matrix: one row per line, one entry per tap (numbers,
        # graph nodes, or nil).
        attr_reader :gains

        # Creates a network of +inputs.length+ delay lines (+inputs+: graph
        # nodes, or nil for a line fed only by the gains) read by +taps+
        # (pairs of [line index, delay time]), with +gains+ (one Array per
        # line, one gain per tap: numbers, graph nodes, or nil/0 for none).
        # +:smoothing+ and +:interpolation+ are as for MultitapDelay;
        # +:initial_buffer+ (any length) sizes each line's starting buffer.
        def initialize(inputs:, taps:, gains:, initial_buffer: 1, interpolation: MB::Sound::DelayLine::DEFAULT_INTERPOLATION, smoothing: false, sample_rate: nil)
          unless MB::Sound::DelayLine::INTERPOLATION.include?(interpolation)
            raise ArgumentError, "Unknown interpolation #{interpolation.inspect} (use one of #{MB::Sound::DelayLine::INTERPOLATION.keys.join(', ')})"
          end
          raise ArgumentError, 'A delay network needs at least one line (inputs:) and one tap (taps:)' if inputs.empty? || taps.empty?
          raise ArgumentError, "A delay network takes at most 64 lines and 64 taps (got #{inputs.length} and #{taps.length})" if inputs.length > 64 || taps.length > 64
          if inputs.none? { |i| i.respond_to?(:sample) }
            raise ArgumentError, 'A delay network needs at least one input node'
          end
          unless gains.is_a?(Array) && gains.length == inputs.length && gains.all? { |r| r.is_a?(Array) && r.length == taps.length }
            raise ArgumentError, "The gain matrix needs #{inputs.length} rows (one per line) of #{taps.length} gains (one per tap)"
          end

          @interpolation = interpolation
          @graph_node_name = nil
          @named = false

          first = inputs.find { |i| i.respond_to?(:sample) }
          @sample_rate = (sample_rate || first.sample_rate).to_f

          @inputs = inputs.map.with_index { |inp, j|
            next nil if inp.nil?
            raise ArgumentError, "Delay network input #{j} must be a graph node or nil (got #{inp.inspect})" unless inp.respond_to?(:sample)

            inp = inp.get_sampler
            check_rate(inp, "input #{j}")
            inp
          }

          @gains = gains.map.with_index { |row, j|
            row.map.with_index { |g, t| gain_value(g, j, t) }.freeze
          }.freeze

          srcs = {}
          @inputs.each_with_index { |inp, j| srcs[:"input_#{j}"] = inp if inp }
          @gains.each_with_index { |row, j|
            row.each_with_index { |g, t| srcs[:"gain_#{j}_#{t}"] = g if g.respond_to?(:sample) }
          }
          @sources = srcs.freeze

          @taps = taps.map.with_index { |(line, time), t|
            unless line.is_a?(Integer) && line >= 0 && line < @inputs.length
              raise ArgumentError, "Delay network tap #{t} reads line #{line.inspect} (lines are 0...#{@inputs.length})"
            end
            Tap.new(network: self, index: t, line: line, delay: time, smoothing: smoothing)
          }

          longest = @taps.filter_map { |t| t.max_delay_samples(@sample_rate) }.max
          initial = MB::Sound::Length.samples(initial_buffer, sample_rate: @sample_rate)
          initial = 1.1 * longest if longest && initial < 1.1 * longest
          @lines = @inputs.map { MB::Sound::DelayLine.new(initial.ceil) }
          @longest = longest.to_f

          @sampled = Set.new
          @outs = nil
          @results = nil
          @in_bufs = Array.new(@inputs.length)
          @ended = @inputs.map(&:nil?)
          @ring = nil
          @ring_done = false
          @tail_start = 0
          @delays = Array.new(@taps.length)
          @gain_values = @gains.map { |row| Array.new(row.length) }
          @states = @taps.map(&:network_read_state)
          @tap_lines = @taps.map(&:line)
        end

        # Sets the network's name (shown in graphs).
        def named(s)
          @graph_node_name = s&.to_s
          @named = true
          self
        end

        # True if #named gave the network a name.
        def named?
          @named
        end

        def sample_rate=(new_rate)
          super
          @sample_rate = sample_rate.to_f
          self
        end
        alias at_rate sample_rate=

        # True once the network has rung out after its inputs ended.
        def rung_out?
          @ring_done
        end

        # Do not use directly.  Called by Tap#sample: the first tap read in a
        # graph frame runs the network for every tap; each tap returns its
        # own output.
        def internal_sample(tap, count)
          if @sampled.include?(tap.index)
            if @sampled.length < @taps.length
              warn "Delay network tap #{tap} on #{self} sampled again with #{@sampled.length} of #{@taps.length} sampled"
            end
            @sampled.clear
            @results = nil
          end

          if @sampled.empty?
            @results = run(count)
          end
          @sampled << tap.index
          @results&.[](tap.index)
        end

        private

        # A gain: nil/false/0 for none, a Float, or a graph node.
        def gain_value(g, j, t)
          case g
          when nil, false then nil
          when Numeric
            raise ArgumentError, "Delay network gains must be real (gain #{j}, #{t}: #{g.inspect})" unless g.real?
            g == 0 ? nil : g.to_f
          else
            raise ArgumentError, "Delay network gain #{j}, #{t} must be a number or a graph node (got #{g.inspect})" unless g.respond_to?(:sample)
            g = g.get_sampler
            check_rate(g, "gain #{j}, #{t}")
            g
          end
        end

        # Runs one frame of up to +count+ samples, returning the taps'
        # outputs (an Array), or nil once the network has ended.
        def run(count)
          return nil if @ring_done

          # Delay times first (a delay node that ends ends the network)
          n = count
          @taps.each_with_index do |tap, t|
            d = tap.network_delays(count)
            return finish if d.nil?

            n = d.length if d.respond_to?(:length) && d.length < n
            @delays[t] = d
          end

          @gains.each_with_index do |row, j|
            row.each_with_index do |g, t|
              if g.respond_to?(:sample)
                v = g.sample(n)
                return finish if v.nil?

                n = v.length if v.length < n
                @gain_values[j][t] = v
              else
                @gain_values[j][t] = g
              end
            end
          end

          # Inputs: ended inputs read as silence; the tail starts once they
          # have all ended
          was_ringing = @ended.all?
          start = 0
          @inputs.each_with_index do |inp, j|
            if @ended[j]
              @in_bufs[j] = nil
              next
            end

            buf = inp.sample(n)
            if buf.nil? || buf.length < n
              @ended[j] = true
              len = buf ? buf.length : 0
              padded = (@pad_bufs ||= {})[j]
              padded = @pad_bufs[j] = Numo::SFloat.zeros(n) unless padded && padded.length == n
              padded.fill(0)
              padded[0...len] = buf[0...len] if len > 0
              buf = padded
              start = len if len > start
            else
              buf = Numo::SFloat.cast(buf) unless buf.is_a?(Numo::SFloat)
            end
            @in_bufs[j] = buf
          end
          start = 0 if was_ringing

          longest = @longest
          @delays.each do |d|
            m = d.is_a?(Numeric) ? d.to_f : delays_max(d)
            longest = m if m.finite? && m > longest
          end
          @longest = longest

          @tap_lines.each_with_index do |j, t|
            d = @delays[t]
            dm = d.is_a?(Numeric) ? d.to_f : delays_max(d)
            dm = 0.0 unless dm.finite?
            @lines[j].prepare(n, dm.ceil)
          end
          @lines.each { |l| l.prepare(n, 0) }

          @outs = nil unless @outs && @outs[0].length == n
          @outs ||= @taps.map { Numo::SFloat.zeros(n) }

          delays = @delays.map { |d| d.is_a?(Numo::NArray) ? d[0...n] : d }
          gains = @gain_values.map { |row| row.map { |g| g.is_a?(Numo::NArray) ? g[0...n] : g } }
          MB::Sound::DelayLine.network(@lines, @in_bufs, @tap_lines, delays, gains, n, interpolation: @interpolation, states: @states, outs: @outs)

          return @outs unless @ended.all?

          keep = ring_out(n, start)
          return @outs if keep.nil?

          @ring_done = true
          return nil if keep == 0

          @outs.map { |o| o[0...keep] }
        end

        # Tracks the tail over the block just run (its samples from +start+
        # on came after every input ended): returns nil to keep going, or
        # the number of samples to keep.
        def ring_out(n, start)
          @ring ||= MB::Sound::QuietRun.new(0) # (the ring-out form: QuietRun#advance)
          len = n - start
          return nil if len <= 0

          written = nil
          @lines.each do |l|
            w = l.past(len, len).abs
            written = written.nil? ? w : Numo::SFloat.maximum(written, w)
          end
          window = (@longest.finite? ? @longest.ceil : 0) + MB::Sound::DelayLine::MARGIN
          keep = @ring.advance(written, len, window)
          keep.nil? ? nil : start + keep
        end

        def finish
          @ring_done = true
          nil
        end

        # delays.max.real without allocating for real buffers.
        def delays_max(delays)
          r = (@delay_range ||= [0.0, 0.0])
          MB::Sound::FastArithmetic.min_max(delays, r) ? r[1] : delays.max.real
        end
      end
    end
  end
end
