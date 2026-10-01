require_relative '../sequence/timeline_node'

module MB
  module Sound
    module GraphNode
      # Passes its source through for a length of time, then ends the stream
      # (a short last buffer, then nil), cutting the source off.  Ends sooner
      # if the source does.  Oscillators and constants play forever, so this
      # is how to cut a sound off at a fixed time; for a musical ending, use
      # an envelope (e.g. GraphNode#adsr).
      #
      # The length is in seconds, or a musical Sequence::Duration (e.g.
      # `2.bars`) that follows the tempo: it counts the timeline played from
      # this node's first sample, at the tempo of each buffer, so tempo
      # changes are followed and the end lands on the exact sample.  Like
      # tempo-synced LFOs, it doesn't count while the timeline is paused.
      #
      # Created with GraphNode#until.
      #
      # Example (bin/sound.rb):
      #     play 220.hz.ramp.at(-6.db).until(2)
      #     bg 220.hz.ramp.at(-6.db).until(2.bars)   # starts and ends on a bar
      #     # A triangle cut off mid-cycle, then 0.2 s for the filter to ring
      #     play 50.hz.triangle.until(3).and_then(silence(0.2)).filter(:lowpass, cutoff: 400, quality: 25)
      class TimeLimit
        include GraphNode
        include SampleRateHelper
        include Sequence::TimelineNode

        # The source node.
        attr_reader :source

        # The length: seconds (Numeric) or a Sequence::Duration.
        attr_reader :length

        def initialize(source, length)
          unless (length.is_a?(Numeric) || length.is_a?(Sequence::Duration)) && length.to_r >= 0
            raise ArgumentError, "Give #until a length in seconds or a Duration (e.g. 2.bars) >= 0 (got #{length.inspect})"
          end

          @source = source.get_sampler
          @length = length
          @sample_rate = @source.sample_rate.to_f
          @elapsed = 0 # samples, for seconds
          @remaining = length.to_r # whole notes, for Durations
          @node_type_name = 'Until'
        end

        # True if the length is musical (a Duration that follows the tempo).
        def musical?
          @length.is_a?(Sequence::Duration)
        end

        # Returns up to +count+ samples of the source, fewer at the end of
        # the time limit, then nil.
        def sample(count)
          remaining = musical? ? musical_samples_left : (@length * @sample_rate).round - @elapsed
          return nil if remaining <= 0

          count = remaining if count > remaining
          data = @source.sample(count)
          return nil if data.nil?

          if musical?
            @remaining -= data.length * whole_notes_per_sample unless timeline_paused?
          else
            @elapsed += data.length
          end

          data
        end

        # Changes the sample rate, keeping the elapsed time in seconds.
        def sample_rate=(rate)
          old_rate = @sample_rate
          super
          @elapsed = (@elapsed * @sample_rate / old_rate).round
          self
        end
        alias at_rate sample_rate=

        def sources
          { input: @source }
        end

        def to_s
          "#{super} -- #{musical? ? @length : "#{MB::M.sigfigs(@length, 4)}s"}"
        end

        private

        # Samples left at the current tempo (unlimited while paused).
        def musical_samples_left
          return Float::INFINITY if timeline_paused? && @remaining > 0

          (@remaining / whole_notes_per_sample).round
        end

        # Whole notes per sample at the current tempo, as a Rational.
        def whole_notes_per_sample
          transport.whole_notes_per_second / @sample_rate.to_r
        end

        # The length counts from this node's first sample, not the graph's
        # launch (so `a.until(1.bar).and_then(b.until(1.bar))` plays two
        # bars), so the timeline position isn't needed.
        def timeline_start(_time, _origin)
        end
      end
    end
  end
end
