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
      # Without envelopes or a quiet check (Notes#grid_end?: a bare
      # `clip.notes.gate.filter(...)` or `hit.trigger.ping(...)`), those
      # nodes end on the first point of their END_GRID (every 800 samples
      # of their own output, counted from their first sample) at or after
      # the sample following the stream's last event (TAIL_SECONDS later
      # if a note is still held then), returning a short last buffer, so a
      # graph ends on the same sample at any buffer size: where a run of
      # 800-sample buffers ended it before.  Before fixes-12 (2026-10-14)
      # they ended at the first buffer start after the stream's end, so a
      # filter ringing on a gate was cut a buffer-size-dependent number of
      # samples after the last note (at full level for a 50 Hz lowpass on
      # a gate).  Graphs with envelopes still end at a buffer start (an
      # envelope's idle sample isn't known before it renders).
      #
      # Subclasses implement #render(buf, items) (see Held and Impulse).
      class Node
        include GraphNode
        include GraphNode::SampleRateHelper
        node_traits memory: :short

        # Seconds after the stream ends before #ends_graph? nodes return nil
        # even if envelopes are still sounding (the old MIDI file nodes'
        # limit).
        TAIL_SECONDS = MIDI::MIDIFile::TAIL_SECONDS

        # The grid (samples of a node's own output) on which #ends_graph?
        # nodes of a Notes without envelopes end (see the class
        # description; the same 800 as Synth::SKIP_GRID).
        END_GRID = 800

        # The MIDI::Stream this node reads.
        attr_reader :stream

        # The Notes instance this node belongs to (nil for shared controller
        # nodes; see Notes#cc).
        attr_reader :notes

        # Reads +stream+ (a MIDI::Stream) for the Notes instance +notes+ (or
        # nil for a node shared by several Notes instances).
        def initialize(stream, notes: nil, sample_rate: 48000)
          @smoother = nil
          @jumps = nil
          @stream = stream
          @notes = notes
          @reader = stream.reader
          @generation = @reader.generation
          @pending_chase = nil
          @sample_rate = sample_rate.to_f
          @buf = nil
          @tail = 0
          @frames_read = 0
          @grid_end = nil
          @grid_generation = nil
          @carried = false # (#skip_start_chase!)

          # Set later (here so every node has one instance variable layout;
          # see GraphNode::IvarPreset)
          @smooth_follow = nil
          @smooth_generation = nil
          @step_count = nil
          @step_rate = nil
          @rate_r = nil
          @step = nil
          @steady_value = nil
          @steady = nil
          @slots = nil
          @first_fill = nil
          @uniform = nil
          @render_offset = nil
          @plan_jumps = nil
          @plan_lists = nil
          @plan_recorder = nil
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
          step(count)
          to = @stream.advance(from, count, @sample_rate)
          events = @reader.events(from, to)
          chase = take_chase(to)

          out = (events.empty? && chase.nil? && Kernels.notes_fast? && steady_buffer(count))
          unless out
            @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
            uniform = render(@buf, items(events, chase, from, @rate_r, count))

            # Events that left the output constant (e.g. note events seen by
            # a controller) give the constant buffer too
            out = uniform.is_a?(Float) && Kernels.notes_fast? ? constant_buffer(count, uniform) : @buf
          end

          out = smooth_output(out) if @smoother

          @tail += count if ended?
          out = end_on_grid(out, from, to, count) if ends_graph?
          out
        end

        # The smoothing time of this node's output (seconds or a Length; see
        # Notes::Smoother and Notes.control_smoothing; a Range for adaptive
        # smoothing; the current global default for nodes that follow it),
        # or nil if it steps on exact samples.
        def smooth_time
          return Notes.smoothing(nil, Notes.public_send(@smooth_follow)) if @smooth_follow

          @smoother&.length
        end

        # The stream time (Rational seconds) this node has read up to.
        def cursor
          @reader.cursor
        end

        # The stream time this node will have read up to after its next
        # +count+ samples.
        def next_cursor(count)
          count = count.round
          step(count)
          @stream.advance(@reader.cursor, count, @sample_rate)
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

        # Port type of the output (see GraphNode::Traversable#port_type).
        def port_type
          :control
        end

        def sources
          { stream: @stream }
        end

        def to_s
          "#{node_type_name}"
        end

        # Skips the chase of the stream's notes when the node first reads
        # (Session::Carry: the node took the state of a node in the graph it
        # replaces, so it holds those notes already; the new stream's start
        # would chase the notes in progress, moving a released voice's
        # pitch).  Only the first block: later jumps chase as usual.
        def skip_start_chase!
          @carried = true
          self
        end

        private

        # Smooths the output as the +:smooth+ option +smooth+ says (see
        # Notes.smoothing) with a Notes::Smoother.  For controller nodes (see
        # ChannelNode).  With nil or true, the node follows the global
        # default named by +default+ (:control for Notes.control_smoothing,
        # :bend for Notes.bend_smoothing; nil for no smoothing, as switches
        # have) live: it keeps a smoother (passing its input through while
        # the default is false) whose length follows the default.
        def smooth_with(smooth, default)
          if (smooth.nil? || smooth == true) && default
            @smooth_follow = default == :bend ? :bend_smoothing : :control_smoothing
            @smooth_generation = Notes.smoothing_generation
            @smoother = Smoother.new(Notes.smoothing(nil, Notes.public_send(@smooth_follow)), sample_rate: @sample_rate)
          else
            length = Notes.smoothing(smooth, false)
            @smoother = length ? Smoother.new(length, sample_rate: @sample_rate) : nil
          end
        end

        # Applies a change of the global default this node follows (see
        # #smooth_with) to its smoother.
        def follow_smoothing
          gen = Notes.smoothing_generation
          return if gen == @smooth_generation

          @smooth_generation = gen
          @smoother.length = Notes.smoothing(nil, Notes.public_send(@smooth_follow))
        end

        # Returns the smoothed +out+ (see #smooth_with), with jumps at the
        # offsets #smooth_jump recorded.
        def smooth_output(out)
          follow_smoothing if @smooth_follow
          @smoother.sample_rate = @sample_rate if @smoother.sample_rate != @sample_rate
          out = @smoother.process(out, out.frozen? ? out[0] : nil, @jumps)
          @jumps&.clear
          out
        end

        # Makes the smoothed output jump to the new value at the event being
        # handled instead of gliding (see Held#render).
        def smooth_jump
          (@jumps ||= []) << @render_offset if @smoother
        end

        # True if #sample should return nil (see the class description).
        # +skipping+ is true for #advance (a Synth lane skipped while idle,
        # whose envelopes don't render, so they can't decide an end on the
        # grid): it ends as before, when the Notes is idle at a buffer start
        # (the lane is silent then, so where doesn't change its output).
        def finished?(skipping = false)
          return false unless ends_graph?
          if grid_end?
            return false if @grid_end.nil? || @reader.generation != @grid_generation
            return @frames_read >= @grid_end
          end

          unless skipping || @notes.nil?
            e = @notes.grid_end_frame
            return true if e && @frames_read >= e
          end

          return false unless ended?
          return true if @tail >= TAIL_SECONDS * @sample_rate
          # The Notes' envelopes end it on their grid (see
          # NoteEnvelope#sample; fixes-13)
          return false if !skipping && @notes&.envelope_end?

          @notes.nil? || @notes.idle?
        end

        # True if this #ends_graph? node ends on its END_GRID (see the
        # class description): its Notes has no envelopes and no quiet check.
        def grid_end?
          !@notes.nil? && @notes.grid_end?
        end

        # Counts the frames of a buffer an #ends_graph? node of a Notes
        # without envelopes read (from stream time +from+ to +to+, +count+
        # samples; Notes with envelopes never switch to the
        # grid, since envelopes are only added), and
        # once its stream's last event has been read, works out the
        # END_GRID point where it ends (see the class description).
        # Returns +out+, cut short if the node ends inside the buffer (nil
        # if it ends at its start).  Also called (with nil) for planned
        # blocks, which never hold a stream's end (Plan's #plan_finished?).
        def end_on_grid(out, from, to, count)
          start = @frames_read
          @frames_read += count
          return envelope_end(out, start) unless grid_end?

          gen = @reader.generation
          if @grid_end && gen != @grid_generation
            @grid_end = nil # a seek or a restart: the stream goes on
          end

          if @grid_end.nil?
            last = @stream.music_end
            return out if last.nil? || last >= to

            over = start
            over += [[((last - from) * step_rate).floor, 0].max, count - 1].min + 1 if last >= from
            target = over
            target = grid_ceil(over) + (TAIL_SECONDS * @sample_rate).round if end_held?
            @grid_end = grid_ceil(target)
            @grid_generation = gen
          end

          return out if out.nil? || @grid_end >= @frames_read
          return nil if @grid_end <= start

          out[0...(@grid_end - start)]
        end

        # Cuts +out+ (a buffer read from frame +start+ of the node's output)
        # at the frame where the envelopes of the node's Notes ended it (see
        # NoteEnvelope#sample), if they did: nil if it starts there, short
        # if inside.  Nodes read in the same buffer before the envelope that
        # decided gave a full buffer; arithmetic (stop_early) cuts the graph
        # at the shortest input, so the graph still ends there.
        def envelope_end(out, start)
          e = @notes&.grid_end_frame
          return out if e.nil? || out.nil? || e >= @frames_read
          return nil if e <= start

          out[0...(e - start)]
        end

        # +frames+ rounded up to the END_GRID.
        def grid_ceil(frames)
          (frames + END_GRID - 1) / END_GRID * END_GRID
        end

        # The node's sample rate as a Rational (see #step).
        def step_rate
          @rate_r || @sample_rate.to_r
        end

        # True if a note is still held after the stream's last event, for
        # #end_on_grid: Gate nodes know from their NoteStack.  Trigger and
        # choke nodes don't follow held notes (their planned blocks only
        # see note-ons or chokes), so with a note left hanging they end on
        # the grid after the stream's last event, where a gate waits
        # TAIL_SECONDS.
        def end_held?
          false
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

        # Applies a Source::Chase: #chase for a note sounding at the jump,
        # #chase_start for one starting right at it (its note-on follows).
        def chase_item(c)
          c.starts ? chase_start(c.event) : chase(c.event)
        end

        # A chased note that starts right at the jump (see #chase_item).
        # The same as #chase unless a node treats the note-on that follows
        # as a first note (Glide).
        def chase_start(event)
          chase(event)
        end

        # Returns the Source::Chase to apply in the buffer ending at stream
        # time +to+, if the content jumped (see the class description).
        def take_chase(to)
          gen = @reader.generation
          carried = @carried
          @carried = false
          if gen != @generation
            # (a node holding a replaced graph's notes doesn't chase its new
            # stream's start, Session::Carry, but does chase a jump after it
            # in the same block: a clip swap landing with the rebuild, carry-1)
            start = carried && gen == @generation + 1
            @generation = gen
            c = @stream.chase
            @pending_chase = c && c.generation == gen && !start ? c : nil
          end

          c = @pending_chase
          return nil unless c && c.time < to

          @pending_chase = nil
          c
        end

        # What #items returns for a buffer without events (frozen).
        NO_ITEMS = [].freeze

        # Returns [sample offset, Event or Chase] pairs for the buffer, with
        # the chase after the note-offs sent at the jump and before any
        # later events or note-ons.
        def items(events, chase, from, rate, count)
          return NO_ITEMS if events.empty? && chase.nil?

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

              @render_offset = off
              item.is_a?(MIDI::Source::Chase) ? chase_item(item) : handle(item)
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

            buf[from...to] = value unless Kernels.fill_range(buf, from, to, value)
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
            BufferHelper.zero(buf)
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
