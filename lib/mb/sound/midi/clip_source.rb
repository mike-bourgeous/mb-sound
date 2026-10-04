module MB
  module Sound
    module MIDI
      # A Source that plays a Sequence::Clip at the tempo of a Transport:
      # each clip event becomes a note-on and a note-off Event on
      # +:channel+, with the event's velocity (0..1, kept exact) and value
      # (usually a note number, but any Numeric or a Pitch is passed through
      # as the Event's note).  Note-offs have the default release velocity.
      #
      # Like ClipNode, it follows the timeline as a Sequence::TimelineNode:
      # looping clips play in phase with the transport's timeline, and
      # non-looping clips play from their start where the graph launched.
      # The tempo is read at each #read, and edges land at the same times as
      # ClipNode's: a reader at sample rate r that reads one buffer at a time
      # gets each edge on the same sample as a ClipNode would.
      #
      # Example:
      #     src = MB::Sound::MIDI::ClipSource.new(seq(C4, E4, G4).n8.loop)
      #     src.read(0, 0.5)   # C4 on at 0, off and E4 on at 0.25 (120 BPM)
      class ClipSource
        include Source
        include Sequence::TimelineNode

        # The Clip being played.
        attr_reader :clip

        # The MIDI channel (0-based) given to the clip's events.
        attr_reader :channel

        # The current clip position in whole notes (a Rational).
        attr_reader :clip_position

        def initialize(clip, channel: 0, transport: nil)
          raise ArgumentError, "Expected a Clip (got #{clip.class})" unless clip.is_a?(Sequence::Clip)
          @clip = clip
          @channel = channel
          @transport = transport
          @clip_position = 0r
          @origin = 0r
          @pending_swap = nil
          @node_type_name = 'MIDI Clip'
        end

        # Switches to playing +clip+ when the timeline reaches +time+ (whole
        # notes; at the start of the next read if nil), like
        # ClipNode#swap_clip.  The switch happens at the exact time rather
        # than the next sample, so for non-looping clips the new clip's
        # edges can land up to one sample earlier than ClipNode's.
        def swap_clip(clip, time: nil)
          raise ArgumentError, "Expected a Clip (got #{clip.class})" unless clip.is_a?(Sequence::Clip)
          @pending_swap = [clip, time&.to_r].freeze
          self
        end

        # The clip waiting to be swapped in by #swap_clip, or nil.
        def pending_clip
          @pending_swap&.first
        end

        def looping?
          @clip.looping?
        end

        # True once a non-looping clip has played to its end.
        def ended?
          !@clip.looping? && @clip_position >= @clip.length
        end

        # The stream time at which a non-looping clip ends (estimated at the
        # current tempo), or nil for looping clips.
        def music_end
          return nil if @clip.looping?
          position + (@clip.length - @clip_position) / transport.whole_notes_per_second
        end

        def to_s
          "#{super} #{@clip}"
        end

        private

        # Seeks to +time+ seconds into the clip at the current tempo.
        def seek_to(time)
          @clip_position = time * transport.whole_notes_per_second
        end

        # See ClipNode#timeline_start.
        def timeline_start(time, origin)
          @origin = @clip.looping? ? 0r : origin
          @clip_position = time - @origin
          jumped
        end

        def read_events(from, to)
          wnps = transport.whole_notes_per_second
          swap = @pending_swap

          if swap
            clip, time = swap
            start = @clip_position + @origin
            time ||= start
            stop = start + (to - from) * wnps

            if time < stop
              @pending_swap = nil
              split = time > start ? from + (time - start) / wnps : from
              out = split > from ? edges(from, split, wnps) : []
              @clip = clip
              @origin = clip.looping? ? 0r : MB::M.max(time, start)
              @clip_position = MB::M.max(time, start) - @origin
              @generation = generation + 1
              out << Jump.new(split)
              return out.concat(edges(split, to, wnps))
            end
          end

          edges(from, to, wnps)
        end

        # Converts the clip's edges for stream times [from, to) to Events and
        # advances the clip position.
        def edges(from, to, wnps)
          wn_from = @clip_position
          wn_to = wn_from + (to - from) * wnps
          @clip_position = wn_to

          @clip.edges(wn_from, wn_to).map { |time, type, event, _cycle|
            t = from + (time - wn_from) / wnps
            if type == :on
              Event.note_on(event.value, event.velocity, channel: @channel, time: t)
            else
              Event.note_off(event.value, channel: @channel, time: t)
            end
          }
        end
      end
    end
  end
end
