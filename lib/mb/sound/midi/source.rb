module MB
  module Sound
    module MIDI
      # Shared behavior for MIDI event sources (FileSource, ClipSource, and
      # later a live source), which a Stream reads.  Sources have no clocks:
      # whoever reads them says how far to read, in Rational seconds of
      # stream time (time since the stream started), so the reader's
      # position is the clock.
      #
      # Including classes implement #read_events(from, to), returning the
      # Events with times in [from, to) in time order, and may override
      # #ended?, #music_end, and #seek_to (see below).
      #
      # #seek and #restart move the source's content (the file or clip
      # position) while stream time keeps counting: after `seek(t)`, the
      # content at +t+ plays at the source's current #position.  They
      # increment #generation, so streams and transforms can tell that the
      # content jumped.
      #
      # A live source may return events slightly before +from+ (late
      # events); Stream moves those to +from+.
      module Source
        include GraphNode::Nameable
        include GraphNode::Traversable

        # Stream time (Rational seconds) up to which this source has been
        # read.
        def position
          @position ||= 0r
        end

        # Counts #seek and #restart calls, so readers can tell when the
        # content jumped.
        def generation
          @generation ||= 0
        end

        # Returns the Events with stream times in [+from+, +to+), in time
        # order, and moves the #position to +to+.  Reading from after the
        # position skips the events in between (a jump; see below); reading
        # from before it starts at the position (events are never returned
        # twice).
        #
        # Sources keep note-ons and note-offs balanced: when the content
        # jumps (#seek, #restart, skipping, a timeline jump or clip swap),
        # notes still sounding get note-offs at the jump, and note-offs for
        # notes that aren't sounding (e.g. notes that started before a seek
        # point) are left out.
        def read(from, to)
          from = from.to_r
          to = to.to_r
          raise ArgumentError, "MIDI read must not end (#{to}) before it starts (#{from})" if to < from

          if from > position
            read_events(position, from)
            @position = from
            @jump_pending = true
          end

          from = position
          return [] if to <= from

          events = read_events(from, to)
          @position = to

          if balance_notes?
            events.unshift(Jump.new(from)) if @jump_pending
            events = balance(events)
          end
          @jump_pending = false

          events
        end

        # Plays the content from +time+ seconds (from the start of the file
        # or clip) at the current #position.  Negative times delay the start.
        def seek(time)
          seek_to(time.to_r)
          jumped
          self
        end

        # Plays the content from the start at the current #position.
        def restart
          seek(0)
        end

        # True once the source has been read past its last event (always
        # false for looping and live sources).
        def ended?
          false
        end

        # The stream time (Rational seconds) of the last event, or nil for
        # looping and live sources.  Sources whose tempo can change give the
        # time at the current tempo.
        def music_end
          nil
        end

        def to_s
          node_type_name
        end

        def node_type_name
          @node_type_name ||= "MIDI #{self.class.name.rpartition('::').last}"
        end

        private

        # A marker that #read_events may return among its events where the
        # content jumps in the middle of a read (e.g. a clip swap), so notes
        # sounding at that +time+ get note-offs.
        Jump = Data.define(:time)

        # Records a content jump at the current position: increments the
        # #generation and sends note-offs for sounding notes at the next
        # read.
        def jumped
          @generation = generation + 1
          @jump_pending = true
        end

        # Whether #read keeps notes balanced (see #read); transforms read
        # balanced streams and don't need to.
        def balance_notes?
          true
        end

        # Drops note-offs for notes that aren't sounding, and replaces Jump
        # markers with note-offs for every sounding note.
        def balance(events)
          @sounding ||= {}
          out = []

          events.each do |e|
            if e.is_a?(Jump)
              @sounding.each do |(channel, note), count|
                count.times { out << Event.note_off(note, channel: channel, time: e.time) }
              end
              @sounding.clear
            elsif e.type == :note_on
              key = [e.channel, e.note]
              @sounding[key] = (@sounding[key] || 0) + 1
              out << e
            elsif e.type == :note_off
              key = [e.channel, e.note]
              count = @sounding[key]
              next unless count

              count > 1 ? @sounding[key] = count - 1 : @sounding.delete(key)
              out << e
            else
              out << e
            end
          end

          out
        end

        # Returns the Events in [from, to) of stream time, where +from+ is
        # always the current #position.  Implemented by including classes.
        def read_events(from, to)
          raise NotImplementedError, "#{self.class} must implement #read_events"
        end

        # Moves the content so that content time +time+ is at #position.
        def seek_to(time)
          raise NotImplementedError, "#{self.class} does not support seeking"
        end
      end
    end
  end
end
