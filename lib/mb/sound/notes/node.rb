module MB
  module Sound
    class Notes
      # Base class for the signal nodes of a Notes instance (and the shared
      # controller nodes of its stream; see Notes#cc).  Each node reads the
      # events for each buffer from its own MIDI::Stream::Reader, at its own
      # sample rate, and puts every event on its exact sample: the event at
      # Rational stream time t lands on sample floor((t - from) * rate) of
      # the buffer that starts at stream time +from+.  For a clip source
      # this is the sample on which the clip's edge falls at the transport's
      # tempo (see MIDI::ClipSource).
      #
      # When the stream's content jumps (MIDI::Stream::Reader#generation
      # changes: seeks, timeline jumps, clip swaps), the source sends
      # note-offs for sounding notes, and held values chase the note at the
      # new position (see MIDI::Source#chase) at the jump's sample.
      #
      # Ending (see #ended? and #sample): #ended? is true once the stream's
      # source has ended (e.g. a MIDI file or a non-looping clip has played
      # its last event) and every event has been read, so the script
      # runner's ringdown can tell the music has finished (like the old MIDI
      # DSL nodes).  Nodes for which #ends_graph? is true (gate, trigger,
      # choke) then return nil once the Notes instance is idle (every
      # envelope it made has finished; see Notes#idle?) or TAIL_SECONDS
      # later, ending the graph (envelopes end too; see
      # NoteEnvelope#sample).  Held values (note numbers, controllers) never
      # end, and an oscillator's ended key sync trigger only stops its
      # resets, so oscillators keep playing through an envelope's release.
      #
      # Subclasses implement #render(buf, items) (see Held and Impulse).
      class Node
        include GraphNode
        include GraphNode::SampleRateHelper

        # Seconds after the stream ends before #ends_graph? nodes return nil
        # even if envelopes are still sounding (the old MIDI file nodes'
        # limit).
        TAIL_SECONDS = MIDI::MIDIFile::TAIL_SECONDS

        # The MIDI::Stream this node reads.
        attr_reader :stream

        # The Notes instance this node belongs to (nil for shared controller
        # nodes; see Notes#cc).
        attr_reader :notes

        # Reads +stream+ (a MIDI::Stream) for the Notes instance +notes+ (or
        # nil for a node shared by several Notes instances).
        def initialize(stream, notes: nil, sample_rate: 48000)
          @stream = stream
          @notes = notes
          @reader = stream.reader
          @generation = @reader.generation
          @pending_chase = nil
          @sample_rate = sample_rate.to_f
          @buf = nil
          @tail = 0
        end

        # Returns +count+ samples (a buffer reused between calls), or nil if
        # the node has finished (see the class description).
        def sample(count)
          count = count.round
          return nil if finished?

          rate = @sample_rate.to_r
          from = @reader.cursor
          to = from + Rational(count) / rate
          events = @reader.events(from, to)
          chase = take_chase(to)

          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          render(@buf, items(events, chase, from, rate, count))

          @tail += count if ended?
          @buf
        end

        # True once the stream's source has ended and this node has read
        # every event (see the class description).
        def ended?
          @reader.ended?
        end

        # True if this node returns nil (ending the graph) once the stream
        # ends and the Notes instance is idle (see the class description).
        def ends_graph?
          false
        end

        def sources
          { stream: @stream }
        end

        def to_s
          "#{node_type_name}"
        end

        private

        # True if #sample should return nil (see the class description).
        def finished?
          return false unless ends_graph? && ended?
          (@notes.nil? || @notes.idle?) || @tail >= TAIL_SECONDS * @sample_rate
        end

        # Returns the Source::Chase to apply in the buffer ending at stream
        # time +to+, if the content jumped (see the class description).
        def take_chase(to)
          gen = @reader.generation
          if gen != @generation
            @generation = gen
            c = @stream.chase
            @pending_chase = c && c.generation == gen ? c : nil
          end

          c = @pending_chase
          return nil unless c && c.time < to

          @pending_chase = nil
          c
        end

        # Returns [sample offset, Event or Chase] pairs for the buffer, with
        # the chase after the note-offs sent at the jump and before any
        # later events or note-ons.
        def items(events, chase, from, rate, count)
          list = events.map { |e| [offset(e.time, from, rate, count), e] }

          if chase
            idx = events.index { |e| e.time > chase.time || (e.time >= chase.time && e.note_on?) } || events.length
            list.insert(idx, [offset(chase.time, from, rate, count), chase])
          end

          list
        end

        # The sample offset of stream time +time+ in the buffer.
        def offset(time, from, rate, count)
          off = ((time - from) * rate).floor
          off < 0 ? 0 : (off >= count ? count - 1 : off)
        end

        # Fills +buf+ from +items+ (see #items).
        def render(buf, items)
          raise NotImplementedError, "#{self.class} must implement #render"
        end

        # The note number of an event's note: a number, or a Pitch (a fixed
        # frequency like `440.hz` in a clip) as the note number of its
        # frequency in the current tuning when its event starts, so
        # converting back (Notes#freq) gives its frequency in any tuning.
        def number_of(note)
          (note.is_a?(MB::Sound::Pitch) ? MB::Sound.tuning.number_of(note.frequency) : note).to_f
        end

        # A node whose output holds a level between events.  Subclasses
        # implement #handle(event) to change state, #level for the output,
        # and may implement #chase(event) for content jumps.
        class Held < Node
          private

          def render(buf, items)
            start = 0
            items.each do |off, item|
              if off > start
                fill(buf, start, off)
                start = off
              end

              item.is_a?(MIDI::Source::Chase) ? chase(item.event) : handle(item)
            end

            fill(buf, start, buf.length) if start < buf.length
          end

          # Fills buf[from...to] with the current output.
          def fill(buf, from, to)
            buf[from...to] = level
          end

          def handle(event)
            raise NotImplementedError
          end

          def level
            raise NotImplementedError
          end

          # Jumps held values to the note-on +event+ after a content jump
          # (see the class description of Node).
          def chase(event)
          end
        end

        # A node whose output is 0 except for single-sample positive
        # impulses at some events.  Subclasses implement #impulse(event),
        # returning the impulse's value or nil.  The largest impulse wins
        # when several land on one sample.
        class Impulse < Node
          def ends_graph?
            true
          end

          private

          def render(buf, items)
            buf.fill(0)
            items.each do |off, item|
              next if item.is_a?(MIDI::Source::Chase)
              v = impulse(item)
              buf[off] = v if v && v > buf[off]
            end
          end

          def impulse(event)
            raise NotImplementedError
          end
        end
      end
    end
  end
end
