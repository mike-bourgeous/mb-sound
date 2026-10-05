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
        #
        # Buffers without events (most of them) take a fast path: nodes whose
        # output is constant until the next event (see #steady_buffer)
        # return one frozen buffer for as long as their value holds, so
        # consumers must not modify it (see GraphNode::Tee; with
        # Tee.shared_check on, a modified buffer raises or warns).
        def sample(count)
          count = count.round
          return nil if finished?

          from = @reader.cursor
          to = from + step(count)
          events = @reader.events(from, to)
          chase = take_chase(to)

          out = (events.empty? && chase.nil? && Notes.fast_paths && steady_buffer(count))
          unless out
            @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
            uniform = render(@buf, items(events, chase, from, @rate_r, count))

            # Events that left the output constant (e.g. note events seen by
            # a controller) give the constant buffer too
            out = uniform.is_a?(Float) && Notes.fast_paths ? constant_buffer(count, uniform) : @buf
          end

          @tail += count if ended?
          out
        end

        # The stream time (Rational seconds) this node has read up to.
        def cursor
          @reader.cursor
        end

        # The stream time this node will have read up to after its next
        # +count+ samples.
        def next_cursor(count)
          @reader.cursor + step(count.round)
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

        # The length of +count+ samples in Rational seconds at the node's
        # sample rate (cached for the last count and rate).
        def step(count)
          if count != @step_count || @sample_rate != @step_rate
            @step_count = count
            @step_rate = @sample_rate
            @rate_r = @sample_rate.to_r
            @step = Rational(count) / @rate_r
          end
          @step
        end

        # Returns a frozen buffer of +count+ samples for a buffer without
        # events, or nil to render it with #render.  Subclasses return
        # constant buffers (see Held and Impulse).
        def steady_buffer(count)
          nil
        end

        # Returns a frozen buffer of +count+ samples of +value+, reusing the
        # last one while the value and count are the same.  With
        # GraphNode::Tee.shared_check on, checks that no consumer changed a
        # reused buffer (consumers must copy frozen buffers before changing
        # them; Numo allows in-place arithmetic on frozen arrays).
        #
        # Nodes with several outputs (see EnvelopeInputs) pass a +slot+ name
        # for each output's buffer.
        def constant_buffer(count, value, slot = nil)
          return slot_buffer(slot, count, value) if slot

          buf = @steady
          if buf && buf.length == count && @steady_value == value
            return buf unless GraphNode::Tee.shared_check && !steady_intact?(buf, value)
          end

          @steady_value = value
          @steady = Numo::SFloat.new(count).fill(value).freeze
        end

        # #constant_buffer for the output +slot+.
        def slot_buffer(slot, count, value)
          entry = (@slots ||= {})[slot] ||= [nil, nil]
          buf = entry[0]
          if buf && buf.length == count && entry[1] == value
            return buf unless GraphNode::Tee.shared_check && !steady_intact?(buf, value)
          end

          entry[1] = value
          entry[0] = Numo::SFloat.new(count).fill(value).freeze
        end

        # Returns true if no consumer changed the reused frozen buffer +buf+
        # of #constant_buffer, else raises (or with :warn, warns and returns
        # false, so the caller makes a new buffer).
        def steady_intact?(buf, value)
          return true if buf.eq(buf[0]).all? && buf[0] == Numo::SFloat[value][0]

          message = "A node downstream of #{self} modified its frozen constant buffer (copy a frozen input before modifying it)"
          raise GraphNode::Tee::SharedBufferModified, message unless GraphNode::Tee.shared_check == :warn

          warn message
          false
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

        # Fills +buf+ from +items+ (see #items).  Returns the buffer's value
        # if every sample is the same Float, else nil (or anything else).
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

          # Returns the value of the whole buffer if every #fill wrote the
          # same one (only the default #fill tracks this; see Node#render).
          def render(buf, items)
            @first_fill = nil
            @uniform = true

            start = 0
            items.each do |off, item|
              if off > start
                fill(buf, start, off)
                start = off
              end

              item.is_a?(MIDI::Source::Chase) ? chase(item.event) : handle(item)
            end

            fill(buf, start, buf.length) if start < buf.length

            @uniform ? @first_fill : nil
          end

          # Fills buf[from...to] with the current output.
          def fill(buf, from, to)
            value = level
            if @first_fill.nil?
              @first_fill = value
            elsif value != @first_fill
              @uniform = false
            end

            buf[from...to] = value
          end

          def steady_buffer(count)
            value = steady_level
            value.nil? ? nil : constant_buffer(count, value)
          end

          # The output for a whole buffer without events if it is constant,
          # else nil (#fill is then called).  #level by default.
          def steady_level
            level
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

          # Returns 0.0 if no event gave an impulse (see Node#render).
          def render(buf, items)
            buf.fill(0)
            quiet = 0.0
            items.each do |off, item|
              next if item.is_a?(MIDI::Source::Chase)
              v = impulse(item)
              if v && v > buf[off]
                buf[off] = v
                quiet = nil
              end
            end
            quiet
          end

          def impulse(event)
            raise NotImplementedError
          end

          def steady_buffer(count)
            constant_buffer(count, 0.0)
          end
        end
      end
    end
  end
end
