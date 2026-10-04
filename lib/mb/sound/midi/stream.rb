module MB
  module Sound
    module MIDI
      # Reads a MIDI Source once for any number of readers, like a Tee does
      # for samples.  Each Reader has its own cursor in Rational seconds of
      # stream time; when a reader asks for events past what has been read,
      # the stream reads the source up to there, and it drops events once
      # every reader has passed them.  Readers may run at different sample
      # rates or buffer sizes, since they ask in seconds.
      #
      # Transforms (#channel, #transpose, #sustain, #velocity_curve,
      # #bend_range) return new Streams that read this one through their own
      # reader, so the original stream is unchanged and each transform runs
      # once for all of its readers.
      #
      # The root stream (the one reading a Source directly) keeps track of
      # each channel's pitch bend range from RPN 0 messages (2 semitones
      # until one arrives) and stores it in every :bend Event's +bend_range+
      # (see Event#bend_semitones and #bend_range).
      #
      # Streams take part in graph traversal (#sources, #graph, #graphviz) so
      # MIDI nodes show up in graph views and Session finds a ClipSource's
      # timeline, but they are not GraphNodes: they have no audio output and
      # no sample rate (so sample rate changes pass them by), and the audio
      # DSL methods don't apply to them.
      #
      # Example:
      #     stream = MB::Sound::MIDI::Stream.new(MB::Sound::MIDI::FileSource.new('song.mid'))
      #     bass = stream.channel(1).transpose(-1.oct).reader
      #     bass.next(800r / 48000)   # events for the first 800-sample buffer
      class Stream
        include GraphNode::Nameable
        include GraphNode::Traversable

        # One consumer's view of a Stream, with its own cursor.  Create with
        # Stream#reader.
        class Reader
          # The Stream being read.
          attr_reader :stream

          # Stream time (Rational seconds) up to which this reader has read.
          attr_reader :cursor

          def initialize(stream, cursor)
            @stream = stream
            @cursor = cursor.to_r
          end

          # Returns the events with times in [+from+, +to+) seconds and moves
          # the cursor to +to+.  +from+ may be after the cursor (skipping
          # events) but not before it.  Late events from a live source can
          # have times before +from+; they are moved to the time they
          # arrived (see Stream).  The Array is frozen (readers of the same
          # range may share it).
          def events(from, to)
            @stream.read_for(self, from.to_r, to.to_r)
          end

          # Returns the events in the next +duration+ seconds (e.g.
          # `count.to_r / sample_rate`) and advances the cursor.
          def next(duration)
            events(@cursor, @cursor + duration.to_r)
          end

          # True once the source has ended and this reader has read every
          # event.
          def ended?
            @stream.ended_for?(self)
          end

          # The stream's Stream#generation, which changes when the content
          # jumps (seek, restart, timeline jumps, clip swaps).
          def generation
            @stream.generation
          end

          # The stream time of the last event, or nil (see Source#music_end).
          def music_end
            @stream.music_end
          end

          # Stops following the stream, so it no longer keeps events for
          # this reader.
          def close
            @stream.remove_reader(self)
            self
          end

          # Used by Stream.
          def cursor=(time)
            @cursor = time
          end
        end

        # Keeps each channel's pitch bend range from RPN 0 (MSB = semitones,
        # LSB = cents) and adds it to :bend Events.  Used by root streams
        # and Stream#bend_range.
        class BendTracker
          def initialize(range)
            @default = range
            reset
          end

          # Forgets RPN selections and per-channel ranges.
          def reset
            @ranges = Array.new(16) { @default }
            @rpn = Array.new(16) { [127, 127] }
          end

          # Returns +event+, with the bend range added to bend events, after
          # following its RPN messages.
          def process(event)
            ch = event.channel
            return event unless ch && ch < 16

            case event.type
            when :bend
              return event.with(bend_range: @ranges[ch])

            when :cc
              case event.note
              when 101 then @rpn[ch] = [event.raw, @rpn[ch][1]]
              when 100 then @rpn[ch] = [@rpn[ch][0], event.raw]
              when 99, 98 then @rpn[ch] = [127, 127] # NRPN: data entry no longer goes to an RPN
              when 121 then @rpn[ch] = [127, 127] # Reset controllers sets the RPN to null (RP-15)
              when 6
                if @rpn[ch] == [0, 0]
                  cents = (@ranges[ch] * 100) % 100
                  @ranges[ch] = event.raw + Rational(cents, 100)
                end
              when 38
                @ranges[ch] = @ranges[ch].floor + Rational(event.raw, 100) if @rpn[ch] == [0, 0]
              end
            end

            event
          end
        end

        # Returns a Stream reading +obj+: a Source, a Stream (returned as-is),
        # a Sequence::Clip (ClipSource), a MIDIFile, a MIDI filename
        # (FileSource), or a live MIDI::Input (LiveSource).
        def self.for(obj)
          case obj
          when Stream then obj
          when Source then new(obj)
          when Input then new(LiveSource.new(obj))
          when Sequence::Clip then new(ClipSource.new(obj))
          when MIDIFile, String then new(FileSource.new(obj))
          else raise ArgumentError, "Cannot make a MIDI stream from #{obj.inspect}"
          end
        end

        # Returns a Stream of live MIDI input: a LiveSource reading a new
        # MIDI::Input connected to +:connect+ (part of a source's name, or nil
        # for a port to connect to later), with +options+ for LiveSource.new
        # (+:timing+, +:output+, +:latency+) and MIDI::Input.new.  Close it
        # with `stream.source.close`.
        #
        #     MB::Sound::MIDI::Stream.live(connect: 'Launchkey', output: out)
        def self.live(connect: nil, **options)
          new(LiveSource.new(connect: connect, **options))
        end

        # The Source (or transform) this stream reads.
        attr_reader :source

        # Stream time (Rational seconds) up to which the source has been
        # read.
        attr_reader :read_to

        # +source+ is a Source.  Pass +:bend_range+ (an Interval or
        # semitones) to change the default bend range of a root stream.
        def initialize(source, bend_range: Event::DEFAULT_BEND_RANGE)
          @source = source
          @read_to = source.position
          @log = []
          @readers = ObjectSpace::WeakMap.new
          @bends = source.is_a?(Transform) ? nil : BendTracker.new(Interval.semitones(bend_range))
        end

        # Returns a new Reader starting at +:at+ seconds, or by default where
        # the slowest current reader is (or where the source has been read
        # to, if there are no readers).
        def reader(at: nil)
          at ||= min_cursor || @read_to
          Reader.new(self, at).tap { |r| @readers[r] = true }
        end

        # Counts content jumps (see Source#generation).
        def generation
          @source.generation
        end

        # Restarts the root source (see Source#restart).  Every stream
        # reading that source sees the jump.
        def restart
          @source.restart
          self
        end

        # Seeks the root source to +time+ seconds of content (see
        # Source#seek).
        def seek(time)
          @source.seek(time)
          self
        end

        # True once the source has ended and every reader has read every
        # event.
        def ended?
          @source.ended? && (@log.empty? || @log.last.time < (min_cursor || @read_to))
        end

        # The stream time of the last event, or nil (see Source#music_end).
        def music_end
          @source.music_end
        end

        # The note to chase after the latest content jump, or nil (see
        # Source#chase; transforms pass it through).
        def chase
          @source.chase
        end

        # The first note of the content, or nil (see Source#first_note).
        def first_note
          @source.first_note
        end

        # The number of events read from the source and not yet passed by
        # every reader.
        def pending_count
          @log.length
        end

        # Returns a stream with only events on +channels+ (an Integer from 0
        # to 15, or an Array or Range of them).  Channels are 0-based, like
        # Manager's +:channel+ (MIDI channel 10, drums, is 9).  System and
        # sysex events pass through.
        def channel(channels)
          Stream.new(Transform::Channel.new(self, channels))
        end

        # Returns a stream with note numbers (including poly pressure)
        # shifted by +interval+ (an Interval or semitones, e.g. `7.st`,
        # `-1.oct`, or 12).  Notes outside 0..127 or between semitones are
        # kept but have no MIDI bytes.
        def transpose(interval)
          Stream.new(Transform::Transpose.new(self, interval))
        end

        # Returns a stream with piano pedals applied to the notes, the only
        # place sustain is handled in the new MIDI design:
        # - Sustain (CC 64 >= 64) holds note-offs until the pedal lifts.
        # - Sostenuto (CC 66 >= 64) holds only the notes sounding (keys down
        #   or held by sustain) when it went down.
        # - Soft (CC 67 >= 64) multiplies note-on velocities by +:soft+
        #   (0.7 by default, about -3 dB for linear velocity).
        # A note struck again while it is held gets its held note-off just
        # before the new note-on.  All sound off (CC 120) and reset
        # controllers (CC 121) release every held note at once (121 also
        # lifts the pedals).  The pedal CCs pass through unchanged.
        def sustain(soft: Transform::Sustain::SOFT_VELOCITY)
          Stream.new(Transform::Sustain.new(self, soft: soft))
        end

        # Returns a stream with note-on velocities (0..1) passed through a
        # curve: an exponent (1 is linear, 2 softer, 0.5 louder) or a block
        # (or Proc) from velocity to velocity.  Results are clamped to 0..1.
        #
        #     stream.velocity_curve(2)
        #     stream.velocity_curve { |v| 0.3 + 0.7 * v }
        def velocity_curve(curve = 1, &block)
          Stream.new(Transform::VelocityCurve.new(self, block || curve))
        end

        # Returns a stream whose :bend events have a bend range of +interval+
        # (an Interval or semitones, e.g. `12.st`) until an RPN 0 message on
        # their channel sets another.  See Event#bend_semitones.
        def bend_range(interval)
          Stream.new(Transform::BendRange.new(self, interval))
        end

        def sources
          @source.is_a?(Transform) ? @source.sources : { source: @source }
        end

        def to_s
          @source.is_a?(Transform) ? "MIDI #{@source}" : "MIDI Stream"
        end

        def to_s_graphviz
          "#{to_s}\n#{name_or_id}"
        end

        # Used by Reader#events.
        def read_for(reader, from, to)
          raise ArgumentError, "MIDI read must not end (#{to}) before it starts (#{from})" if to < from
          raise ArgumentError, "MIDI reader already read up to #{reader.cursor} (asked from #{from})" if from < reader.cursor

          # Readers asking for the range just read (e.g. the nodes of one
          # Notes instance, each reading the same buffer) share its events.
          # Still valid: later fills only add events at or after +to+, and
          # drops only remove events before the slowest reader's cursor.
          last = @last_read
          if last && last[0] == from && last[1] == to
            reader.cursor = to
            return last[2]
          end

          fill(to)

          start = @log.bsearch_index { |e| e.time >= from } || @log.length
          stop = @log.bsearch_index { |e| e.time >= to } || @log.length
          events = @log[start...stop].freeze
          @last_read = [from, to, events]

          reader.cursor = to
          drop
          events
        end

        # Used by Reader#ended?.
        def ended_for?(reader)
          @source.ended? && (@log.empty? || @log.last.time < reader.cursor)
        end

        # Used by Reader#close.
        def remove_reader(reader)
          @readers.delete(reader)
          drop
        end

        private

        # Reads the source up to +to+ seconds.
        def fill(to)
          return if to <= @read_to

          from = @read_to
          events = @source.read(from, to)
          @read_to = to

          return if events.empty?

          # Late events (from live sources) play where they arrived
          events = events.map { |e| e.time < from ? e.at(from) : e }
          events = events.each_with_index.sort_by { |e, idx| [e.time, idx] }.map(&:first) unless sorted?(events)
          events = events.map { |e| @bends.process(e) } if @bends

          @log.concat(events)
        end

        def sorted?(events)
          events.each_cons(2).all? { |a, b| a.time <= b.time }
        end

        # The earliest reader cursor, or nil if there are no readers.
        def min_cursor
          @readers.keys.map(&:cursor).min
        end

        # Drops events that every reader has passed.
        def drop
          return if @log.empty?

          horizon = min_cursor || @read_to
          count = @log.bsearch_index { |e| e.time >= horizon } || @log.length
          @log.shift(count) if count > 0
        end
      end
    end
  end
end
