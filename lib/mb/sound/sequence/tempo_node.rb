module MB
  module Sound
    module Sequence
      # A graph node whose output follows the tempo of a Transport: the
      # frequency in Hz of one cycle per +duration+ (mode :hz), or the length
      # of +duration+ in seconds (mode :seconds).  The output changes when
      # the tempo changes (at buffer boundaries).
      #
      # Usually created by Duration#hz (a Pitch whose frequency follows the
      # tempo, and the basis of Duration#lfo) or by delay methods given a
      # Duration.
      #
      # In :hz mode, tones made from the pitch lock their phases to the
      # timeline through two ports (see GraphNode::Ports) that they read as
      # inputs (Tone#follow_timeline): whenever the timeline jumps (the
      # graph starts, or the timeline is seeked or resumed), #jumps is 1 on
      # the first sample after the jump and #jump_phase holds the timeline
      # position there in cycles of +duration+, so each cycle of the tone
      # starts on a multiple of +duration+ from the start of the timeline,
      # plus the tone's own phase offset (see Tone#with_phase).  While the
      # timeline is paused (see TimelineNode#pause_timeline) the output is
      # 0, so the tones stop moving.  A freewheeling node (see #freewheel)
      # ignores the timeline: it gives no jumps and keeps running while the
      # timeline is paused, but its frequency still follows the tempo.
      #
      # With a +count+ node (reese-params-2: GraphNode#bars, a param or
      # knob read live), the length is +count+ times +duration+ on every
      # sample (`lfo_bars.bars` is 1.bar times the knob), so a tone made
      # from it integrates the moving frequency with no phase jump: its
      # phase stays locked to the timeline while the count is steady, and
      # after the count moves it keeps its place in the cycle (it is not
      # pulled back onto the grid) until the timeline jumps again, where
      # the jump phase is the timeline position in cycles of the count's
      # value on that sample.  A steady count gives the exact samples of
      # the Duration it stands for (2.0 times 1.bar plays like 2.bars).
      # Counts below MIN_COUNT (and NaN) read as MIN_COUNT.
      class TempoNode
        include GraphNode
        include GraphNode::SampleRateHelper
        include GraphNode::Ports
        include TimelineNode
        node_traits memory: :none, timeline: true

        port :jumps, '1 on the first sample after the timeline jumped (start, seek, resume) in :hz mode, else 0; none while freewheeling'
        port :jump_phase, 'On jump samples, the timeline position in cycles of the duration (0...1, double precision); 0 elsewhere'

        MODES = [:hz, :seconds].freeze

        # The smallest +count+ read (see the class description): a cycle
        # this many times the duration.
        MIN_COUNT = 1.0 / 256

        # The slowest tempo that delay buffers are sized for when given
        # Durations (see .max_seconds).  Delays grow their buffers if needed
        # at slower tempos.
        SLOWEST_BPM = 40

        # Converts a delay time for delay methods: a Duration becomes a
        # :seconds TempoNode, a graph node that outputs musical time (e.g.
        # `2.bars.lfo.at(3.n16..5.n16)`; see Tone#musical_time?) is scaled
        # from whole notes to seconds at the current tempo, and anything else
        # (a number of seconds or a node that outputs seconds) is returned
        # unchanged.
        def self.seconds_source(time)
          case
          when time.is_a?(Duration)
            TempoNode.new(time, mode: :seconds)
          when time.respond_to?(:musical_time?) && time.musical_time?
            time * TempoNode.new(1.whole, mode: :seconds)
          else
            time
          end
        end

        # Returns the longest a delay +time+ (as for .seconds_source) could
        # be in seconds at SLOWEST_BPM, or nil if it isn't musical time.
        def self.max_seconds(time)
          whole_notes = case
                        when time.is_a?(Duration)
                          time.whole_notes
                        when time.respond_to?(:musical_time?) && time.musical_time?
                          [time.range.begin.abs, time.range.end.abs].max
                        end

          whole_notes && TempoMap.seconds_at(whole_notes.to_f, SLOWEST_BPM)
        end

        # The Duration this node's output is based on.
        attr_reader :duration

        # :hz or :seconds (see the class description).
        attr_reader :mode

        # The node giving how many times +duration+ the length is (see the
        # class description), or nil for +duration+ itself.
        attr_reader :count

        # The NodeDuration this node was made from (NodeDuration#hz), for
        # graph export, or nil.
        attr_reader :origin

        def initialize(duration, mode:, transport: nil, sample_rate: 48000, count: nil, origin: nil)
          raise ArgumentError, "Mode must be one of #{MODES.inspect} (got #{mode.inspect})" unless MODES.include?(mode)
          raise ArgumentError, "Expected a Duration (got #{duration.inspect})" unless duration.is_a?(Duration)
          Length.check_time(duration, 'A tempo-synced length')
          raise ArgumentError, "A tempo-synced length must be longer than zero (got #{duration})" unless duration.whole_notes > 0

          raise ArgumentError, "A tempo length's count must be a graph node (got #{count.inspect})" unless count.nil? || count.respond_to?(:sample)

          @duration = duration
          @count = count
          @count_input = count&.get_sampler
          @origin = origin
          @mode = mode
          @transport = transport
          @sample_rate = sample_rate.to_f
          @freewheel = false
          @pending_jump = nil
          @steady = nil
          @node_type_name = "Tempo #{mode == :hz ? 'Hz' : 'seconds'}"
          @graph_node_name = duration.to_s

          # Set later (here so every TempoNode has one instance variable
          # layout; see GraphNode::IvarPreset)
          @parent = nil
          @timeline_paused = nil
          @timeline_launch = nil
          @value_wnps = nil
          @value_duration = nil
          @value_mode = nil
          @value = nil
          @start_callbacks = nil
          @steady_value = nil
          @quiet = nil
          @count_last = nil
          @count_values = nil
          @count_wnps = nil
          @count_whole_notes = nil
          @moving = nil
          @pending_time = nil
          @first_count = nil
        end

        # Makes this node ignore the timeline (see the class description), or
        # follow it again if +free+ is false.  Returns self.
        def freewheel(free = true)
          @freewheel = !!free
          self
        end

        # True if this node ignores the timeline (see #freewheel), or the
        # node it was scaled from (see #scaled) does.
        def freewheel?
          @freewheel || (!@parent.nil? && @parent.freewheel?)
        end

        # The node this one was made from by #scaled, or nil.
        attr_reader :parent

        # Returns a TempoNode in the same mode and on the same transport for
        # this duration divided by +ratio+ (in :hz mode, +ratio+ times the
        # frequency), e.g. for Pitch#transpose of a tempo-synced pitch: its
        # tones stay locked to the timeline (a cycle of the new duration
        # starts at every multiple of it from the start of the timeline),
        # and it freewheels while this node does.  The ratio is used exactly
        # (Float#to_r), so small detunes of short durations keep their
        # size.
        def scaled(ratio)
          raise ArgumentError, "The ratio must be a positive number (got #{ratio.inspect})" unless ratio.is_a?(Numeric) && ratio > 0

          node = TempoNode.new(Duration.new(@duration.whole_notes / ratio.to_r, label: "#{@duration} / #{MB::M.sigfigs(ratio, 6)}"), mode: @mode, transport: @transport, sample_rate: @sample_rate, count: @count)
          node.instance_variable_set(:@parent, self)
          node
        end

        # The current output value: Hz (:hz) or seconds (:seconds) at the
        # transport's current tempo, ignoring pauses (with a +count+, at its
        # last value read).
        def value
          return count_value(@count_last || 1.0) if @count

          wnps = transport.whole_notes_per_second

          # Cached while the tempo (Transport caches its Rational), length,
          # and mode stay the same
          unless @value_wnps.equal?(wnps) && @value_duration.equal?(@duration) && @value_mode == @mode
            @value_wnps = wnps
            @value_duration = @duration
            @value_mode = @mode
            seconds = TempoMap.seconds_for(@duration.whole_notes, wnps)
            @value = @mode == :hz ? (1 / seconds).to_f : seconds.to_f
          end

          @value
        end

        # Calls the block with this node whenever it lines up with the
        # timeline (see TimelineNode#start_at), e.g. so a delay can jump to
        # its tempo-synced time instead of gliding from zero.  Returns self.
        def on_start(&block)
          (@start_callbacks ||= []) << block
          self
        end

        # Returns +count+ samples of the current value (see #value), or zeros
        # in :hz mode while the timeline is paused (unless freewheeling).
        def sample(count)
          return sample_main(count) if @ports.nil?

          port_frame(count) { sample_main(count) }
        end

        def sources
          @count_input ? { count: @count_input } : {}
        end

        # Plan layer: the value read every block as a param (Plan::Op::Param,
        # like a Constant's), while no port is in use.
        include Plan::Describable

        def plan_describe(p)
          p.param(self, complex: false)
        end

        def plan_unsupported_reason
          return 'ports (timeline jumps) in use' if @ports
          return 'a moving length (count:)' if @count

          nil
        end

        # For plans: this block's value (#sample's, as a number).
        def plan_param(count)
          @mode == :hz && timeline_paused? && !freewheel? ? 0.0 : value
        end

        # For plans: a tempo is never complex.
        def plan_complex?
          false
        end

        # For plan listings.
        def value_string
          "#{MB::M.sigfigs(value, 5)} #{@mode == :hz ? 'Hz' : 's'} (#{@count ? "#{MB::M.sigfigs(@count_last || 1.0, 5)} × " : ''}#{@duration})"
        end

        private

        # Returns one frozen buffer while the value and count stay the same
        # (like GraphNode::Constant), so a steady tempo allocates nothing;
        # consumers must copy a frozen input before changing it.
        def sample_main(count)
          return sample_counted(count) if @count

          v = @mode == :hz && timeline_paused? && !freewheel? ? 0.0 : value
          buf = @steady
          return buf if buf && buf.length == count && @steady_value.eql?(v)

          @steady_value = v
          @steady = Numo::SFloat.new(count).fill(v).freeze
        end

        # #sample_main with a +count+ node (see the class description): the
        # steady frozen buffer while the count holds one value in this frame
        # (#count_value, the same number a Duration of that length gives),
        # else the value of each sample's count (#count_values).  The count
        # is read while paused too, so it stays in step.
        def sample_counted(count)
          c = @count_input.sample(count)
          c = nil if c && c.length != count
          paused = @mode == :hz && timeline_paused? && !freewheel?
          if c.nil? || paused || c.min == c.max
            b = c ? c[0] : (@count_last || 1.0)
            @count_last = b
            @first_count = b
            v = paused ? 0.0 : count_value(b)
            buf = @steady
            return buf if buf && buf.length == count && @steady_value.eql?(v)

            @steady_value = v
            return @steady = Numo::SFloat.new(count).fill(v).freeze
          end

          @count_last = c[-1]
          @first_count = c[0]
          @moving = Numo::SFloat.zeros(count) if @moving.nil? || @moving.length != count
          count_values(c, @moving)
        end

        # The output for one +b+ (a count): Hz or seconds of +b+ times the
        # duration at the transport's tempo, computed as #value computes a
        # Duration's (exact Rationals unless the tempo is a Float), so a
        # steady count of 2.0 times 1.bar gives 2.bars' samples.  Cached for
        # the last few counts at one tempo.
        def count_value(b)
          b = b.to_f
          b = MIN_COUNT unless b >= MIN_COUNT
          wnps = transport.whole_notes_per_second
          unless @count_values && @count_wnps.equal?(wnps) && @count_whole_notes.equal?(@duration.whole_notes)
            @count_wnps = wnps
            @count_whole_notes = @duration.whole_notes
            @count_values = {}
          end
          @count_values[b] ||= begin
            @count_values.shift if @count_values.length >= 16
            seconds = TempoMap.seconds_for(b.to_r * @duration.whole_notes, wnps)
            @mode == :hz ? (1 / seconds).to_f : seconds.to_f
          end
        end

        # Writes each sample's #count_value for the counts +c+ into +out+
        # (an SFloat) without a Ruby call per sample: the same formula in
        # doubles, checked to round to the same float32 within twice its
        # worst error; the rare samples that might not are computed exactly
        # (#count_value), so every sample matches #count_value at any buffer
        # size.
        def count_values(c, out)
          b = Numo::DFloat.cast(c)
          b[~(b >= MIN_COUNT)] = MIN_COUNT
          wnps = transport.whole_notes_per_second.to_f
          seconds = (b * @duration.whole_notes.to_f) / wnps
          d = @mode == :hz ? 1.0 / seconds : seconds
          lo = Numo::SFloat.cast(d * (1 - 4e-15))
          hi = Numo::SFloat.cast(d * (1 + 4e-15))
          out[true] = Numo::SFloat.cast(d)
          (lo.ne(hi)).where.each { |i| out[i] = count_value(c[i]) }
          out
        end

        # The ports for the frame just computed: a jump on its first sample
        # if the timeline jumped since the last frame (see the class
        # description), else shared frozen zeros (so readers can skip
        # buffers they have seen).
        def compute_ports(count)
          if @pending_time
            # (with a count: the position in cycles of the count's value on
            # the jump's sample)
            first = (@first_count || 1.0).to_f
            first = MIN_COUNT unless first >= MIN_COUNT
            cycles = @pending_time / (first.to_r * @duration.whole_notes)
            @pending_jump = (cycles - cycles.floor).to_f
            @pending_time = nil
          end
          if @pending_jump
            store_port(:jumps, Numo::SFloat.zeros(count).tap { |j| j[0] = 1 })
            store_port(:jump_phase, Numo::DFloat.zeros(count).tap { |p| p[0] = @pending_jump })
            @pending_jump = nil
          else
            @quiet = [Numo::SFloat.zeros(count).freeze, Numo::DFloat.zeros(count).freeze] if @quiet.nil? || @quiet[0].length != count
            store_port(:jumps, @quiet[0])
            store_port(:jump_phase, @quiet[1])
          end
        end

        # Notes a jump of the timeline for the ports (see the class
        # description): the phase of a cycle of the duration at +time+.
        def timeline_start(time, _origin)
          @start_callbacks&.each { |c| c.call(self) }

          return if freewheel? || @mode != :hz || @ports.nil?
          return @pending_time = time if @count

          cycles = time / @duration.whole_notes
          @pending_jump = (cycles - cycles.floor).to_f
        end
      end
    end
  end
end
