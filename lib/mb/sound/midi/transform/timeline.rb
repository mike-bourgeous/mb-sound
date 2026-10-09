module MB
  module Sound
    module MIDI
      class Transform
        # Mixin for transforms that need the session timeline or tempo:
        # those that make events later (Scheduled: echo, strum, humanize)
        # and those that step on a musical grid (the arpeggiator, input
        # quantize).  It makes the transform a Sequence::TimelineNode, so a
        # Session finds it in the graph (Stream#sources lists it), gives it
        # the session's Transport (a render's own tempo too), and tells it
        # where the timeline is when the graph starts and when the timeline
        # jumps.
        #
        # Stream time (seconds since the stream started) maps to timeline
        # positions (whole notes) through an anchor: the stream time and
        # timeline position of the last #start_at (or stream time at
        # creation and timeline 0 without a Session, so a clip and a grid
        # played with #play or baked line up from 0), advanced at the end
        # of every read at the tempo of that read, like ClipSource.
        module Timeline
          include Sequence::TimelineNode

          # The timeline position (whole notes) at stream +time+ (seconds),
          # at the current tempo from the last read on.
          def timeline_at(time)
            timeline_anchor
            @timeline_wn + (time - @timeline_time) * transport.whole_notes_per_second
          end

          # The stream time (seconds) at which the timeline reaches +wn+
          # whole notes at the current tempo.
          def stream_time_at(wn)
            timeline_anchor
            @timeline_time + (wn - @timeline_wn) / transport.whole_notes_per_second
          end

          # Converts a length to Rational seconds at the current tempo: a
          # Duration (whole notes at the tempo), a Length, or seconds.
          # Samples are counted at 48 kHz (streams have no sample rate).
          def seconds_of(length)
            case length
            when Sequence::Duration then length.whole_notes / transport.whole_notes_per_second
            when Length then Sequence::Duration.rational(length.to_seconds(transport: transport))
            when Numeric then Sequence::Duration.rational(length)
            else raise ArgumentError, "Expected a length of time (seconds, a Length, or a Duration such as 1.n16; got #{length.inspect})"
            end
          end

          private

          def timeline_anchor
            return if @timeline_time
            @timeline_time = position
            @timeline_wn = 0r
          end

          def timeline_start(time, _origin)
            @timeline_time = position
            @timeline_wn = time
            timeline_jumped(time)
          end

          # Called after the timeline jumped (or a Session started the
          # graph) to +time+ whole notes at the next read's start.
          def timeline_jumped(time)
          end

          # Moves the anchor to stream time +to+ (the end of a read).
          def advance_timeline(to)
            timeline_anchor
            @timeline_wn = timeline_at(to)
            @timeline_time = to
          end
        end
      end
    end
  end
end
