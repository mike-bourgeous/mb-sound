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
      class TempoNode
        include GraphNode
        include GraphNode::SampleRateHelper
        include GraphNode::Ports
        include TimelineNode

        port :jumps, '1 on the first sample after the timeline jumped (start, seek, resume) in :hz mode, else 0; none while freewheeling'
        port :jump_phase, 'On jump samples, the timeline position in cycles of the duration (0...1, double precision); 0 elsewhere'

        MODES = [:hz, :seconds].freeze

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

          whole_notes && whole_notes.to_f * 240.0 / SLOWEST_BPM
        end

        # The Duration this node's output is based on.
        attr_reader :duration

        # :hz or :seconds (see the class description).
        attr_reader :mode

        def initialize(duration, mode:, transport: nil, sample_rate: 48000)
          raise ArgumentError, "Mode must be one of #{MODES.inspect} (got #{mode.inspect})" unless MODES.include?(mode)
          raise ArgumentError, "Expected a Duration (got #{duration.inspect})" unless duration.is_a?(Duration)
          raise ArgumentError, 'Duration must be longer than zero' unless duration.whole_notes > 0

          @duration = duration
          @mode = mode
          @transport = transport
          @sample_rate = sample_rate.to_f
          @freewheel = false
          @pending_jump = nil
          @buf = nil
          @node_type_name = "Tempo #{mode == :hz ? 'Hz' : 'seconds'}"
          @graph_node_name = duration.to_s
        end

        # Makes this node ignore the timeline (see the class description), or
        # follow it again if +free+ is false.  Returns self.
        def freewheel(free = true)
          @freewheel = !!free
          self
        end

        # True if this node ignores the timeline (see #freewheel).
        def freewheel?
          @freewheel
        end

        # The current output value: Hz (:hz) or seconds (:seconds) at the
        # transport's current tempo, ignoring pauses.
        def value
          wnps = transport.whole_notes_per_second
          @mode == :hz ? (wnps / @duration.whole_notes).to_f : (@duration.whole_notes / wnps).to_f
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
          {}
        end

        private

        def sample_main(count)
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          if @mode == :hz && timeline_paused? && !@freewheel
            @buf.fill(0)
          else
            @buf.fill(value)
          end
        end

        # The ports for the frame just computed: a jump on its first sample
        # if the timeline jumped since the last frame (see the class
        # description), else shared frozen zeros (so readers can skip
        # buffers they have seen).
        def compute_ports(count)
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

          return if @freewheel || @mode != :hz || @ports.nil?
          cycles = time / @duration.whole_notes
          @pending_jump = (cycles - cycles.floor).to_f
        end
      end
    end
  end
end
