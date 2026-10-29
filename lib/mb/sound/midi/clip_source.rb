module MB
  module Sound
    module MIDI
      # A Source that plays a Sequence::Clip at the tempo of a Transport:
      # each clip event becomes a note-on and a note-off Event on
      # +:channel+, with the event's velocity (0..1, kept exact) and value
      # (usually a note number, but any Numeric or a Pitch is passed through
      # as the Event's note).  Note-offs have the default release velocity.
      #
      # It follows the timeline as a Sequence::TimelineNode: looping clips
      # play in phase with the transport's timeline, launch-aligned looping
      # clips (Clip#loop with +align: :launch+) and non-looping clips play
      # from their start where the graph launched (or where #swap_clip
      # brought them in).  When the timeline jumps (seek, rewind), timeline
      # loops follow the new position; a launch-aligned loop keeps its
      # anchor, playing the same cycle phase relative to its launch point it
      # would have played without the jump (before the launch point, the
      # cycles leading up to it); a non-looping clip moves to the jump's
      # distance from the graph's launch (before it: silence until then).  The tempo is read
      # at each #read, so a reader at sample rate r that reads one buffer at
      # a time gets each edge on the sample where it falls at the tempo of
      # that buffer (the same samples as the old ClipNode renderers; see
      # spec/support/clip_node_reference.rb).  Clip#stream, Clip#notes, the
      # Clip output methods, and Clip#synth play clips through this class,
      # and Session#swap finds it in graphs to swap clips.
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

        # Read spans the clip's edges can't land in take a quiet path:
        # integer frame counts against the next possible edge's frame
        # (see #read_events).  Off only for specs comparing it with the
        # full read (MIDI::ClipSource.quiet_reads = false).
        class << self
          attr_accessor :quiet_reads
        end
        self.quiet_reads = true

        def initialize(clip, channel: 0, transport: nil)
          raise ArgumentError, "Expected a Clip (got #{clip.class})" unless clip.is_a?(Sequence::Clip)
          @clip = clip
          @channel = channel
          @transport = transport
          @clip_position = 0r
          @origin = 0r
          @graph_origin = nil
          @swap_anchor = nil
          @pending_swap = nil
          @early = true
          @ahead = 0r
          @node_type_name = 'MIDI Clip'

          # Set later by Source, TimelineNode, and the methods below (here so
          # every source has one instance variable layout; see
          # GraphNode::IvarPreset)
          @position = nil
          @generation = nil
          @jump_pending = nil
          @chase = nil
          @sounding = nil
          @timeline_paused = nil
          @timeline_launch = nil
          @flam_lead = nil
          @flam_rate = nil
          @ring_clip = nil
          @flam_start = nil
          @flam_to = nil
          @flam_queue = nil
          @flam_window = nil
          @fills_at = nil
          @clock = nil        # (clocked clips; see #clock_start)
          @clock_ctx = nil
          @clock_anchor = nil
          @clock_origin = nil
          @clock_scale = nil
          @clock_graph = nil
          @quiet_frame = nil  # (quiet reads; see #read_events)
          @quiet_rate = nil
          @quiet_wnps = nil
          @quiet_clip = nil
          @lazy_from = nil
        end

        # The current clip position in whole notes (a Rational).
        def clip_position
          return @clip_position unless @lazy_from
          # Quiet reads since stream time @lazy_from moved it at one tempo
          @clip_position + (position - @lazy_from) * @quiet_wnps
        end

        # Puts the clip playing now on +clock+ unless it has a clock of its own (see
        # Sequence::Clocked.apply, PlaybackMethods#bg's +clock:+).
        def reclock(clock)
          @clip = @clip.clocked(clock) unless @clip.clocking
          self
        end

        # Resyncs a clocked clip to its clock at timeline time +time+ (the
        # stream's next read starts there; see Session#render_player).
        def clock_resync(time)
          clock_start(time + @ahead, position, fresh: false) if @clock
          self
        end

        # The Clock the playing clip follows (see Clip#clocked), or nil
        # for clips on the session's timeline.
        def clock
          @clock
        end

        # How far ahead of the timeline this source plays, in whole notes
        # (0 by default; negative plays behind it).  Every timeline time
        # given to it (#start_at, #swap_clip, #ring_out) counts this much
        # later, so the clip's notes sound this much early, and a change
        # handed over at time t - ahead happens at clip time t.  Set by
        # Arrangement tracks with +lead:+ or +nudge:+ (a pad whose slow
        # attack should peak on the downbeat, drums pushed or pulled a
        # few ms).
        attr_reader :ahead

        # Sets #ahead (whole notes; Rational).
        def ahead=(whole_notes)
          raise ArgumentError, "ahead must be a number of whole notes (got #{whole_notes.inspect})" unless whole_notes.is_a?(Numeric) && whole_notes.real?
          @ahead = whole_notes.to_r
        end

        # The default flam spacing (seconds) when flam-marked note-ons play
        # early (see #play_flams_early), or nil (the default: they play on
        # their step).
        attr_reader :flam_lead

        # Plays flam-marked note-ons (Seq::Step#flam) early by their flam
        # spacing (+spacing+ seconds for marks without their own time),
        # rounded to whole samples at +sample_rate+, so a drum kit's grace
        # stroke (Drums::Flams plays it on the note-on and the main hit the
        # spacing later) comes before the step and the main hit lands on it
        # (drums-3, 2026-10-13: the maintainer heard the delayed main hits
        # as out of time).  The clip is read ahead by the longest spacing to
        # find them.  A flam within that spacing of a launch, a jump, or a
        # swap (where reading ahead couldn't see it) plays on its step with
        # the main hit late, as from live MIDI.  Set by drum kits for the
        # clips they play; nil turns it off.
        def play_flams_early(spacing, sample_rate: 48000)
          @flam_lead = spacing && MB::Sound::Length.seconds(spacing).to_f
          raise ArgumentError, "A flam spacing is over 0 seconds (got #{spacing.inspect})" if @flam_lead && !(@flam_lead > 0)
          @flam_rate = sample_rate.to_r
          reset_flams
          self
        end

        # See Sequence::TimelineNode#start_at; times count #ahead later.
        def start_at(time, origin: time, launch: origin, transport: nil)
          return super if @ahead.zero?
          super(time.to_r + @ahead, origin: origin.to_r + @ahead, launch: launch.to_r + @ahead, transport: transport)
        end

        # Switches to playing +clip+ when the timeline reaches +time+ (whole
        # notes; at the start of the next read if nil), keeping every node
        # reading this source.  A looping clip plays in phase with the
        # timeline; a non-looping clip plays from its start.  Notes in
        # progress get note-offs at the swap, and held values chase the new
        # clip's note (see Source#chase).  Replaces any earlier swap that
        # hasn't happened yet.  Used by Session#swap.  The switch happens at
        # the exact time rather than the next sample, so for non-looping
        # clips the new clip's edges can land up to one sample earlier than
        # the old ClipNode's did.
        def swap_clip(clip, time: nil)
          raise ArgumentError, "Expected a Clip (got #{clip.class})" unless clip.is_a?(Sequence::Clip)
          if @ring_clip
            # Ringing out: the clip to play again changes (see #ring_out)
            @ring_clip = clip
          else
            @pending_swap = [clip, time && time.to_r + @ahead].freeze
          end
          self
        end

        # The clip waiting to be swapped in by #swap_clip, or nil.
        def pending_clip
          @pending_swap&.first
        end

        # Stops sending notes from timeline position +time+ (notes in
        # progress get note-offs there), remembering the clip to play again
        # after #end_ring_out.  Used by Session when a player rings out (see
        # Session::Tails).
        def ring_out(time)
          @ring_clip ||= pending_clip || @clip
          @pending_swap = [Sequence::Clip.silent, time && time.to_r + @ahead].freeze
          self
        end

        # The clip silenced by #ring_out, or nil if not ringing out.
        attr_reader :ring_clip

        # Gives back the clip silenced by #ring_out: swapped in at +time+
        # (whole notes) if given (a ringing player coming back), else right
        # away for the next #start_at (a player that went to sleep).
        def end_ring_out(time: nil)
          clip = @ring_clip or return self
          @ring_clip = nil
          if time
            swap_clip(clip, time: time)
          else
            @pending_swap = nil
            @clip = clip
            reset_flams
          end
          self
        end

        def looping?
          @clip.looping?
        end

        # True once a non-looping clip has played to its end.
        def ended?
          # (quiet reads of a one-shot clip stop at its end: see #edges)
          !@clip.looping? && !@lazy_from && @clip_position > @clip.length
        end

        # True if this source plays a non-looping clip that has ended, or
        # will have ended by timeline position +time+ (whole notes, as given
        # to #swap_clip; nil: now), with no swap or ring-out waiting: a swap
        # landing then would never be read (the voices reading an ended clip
        # end for good; see Session#clips_over_by?).  Clocked clips are
        # estimated at the clock's current speed.
        def over_by?(time)
          return false if @ring_clip || @pending_swap || @clip.looping?
          return true if ended?
          return false if time.nil?
          t = transport
          remaining = (@clip.length - clip_position) / clip_wnps.to_r
          remaining <= (time.to_r - t.position) / t.whole_notes_per_second.to_r
        end

        # Like #over_by?, for a source not playing yet that starts its
        # one-shot clip from the beginning at timeline position +start+
        # (whole notes; nil: now): true if the clip will have ended by
        # +time+.  False for clocked clips (their speed isn't known yet).
        def over_from_by?(start, time)
          return false if @ring_clip || @pending_swap || @clip.looping? || @clip.clocking || time.nil?
          (start || transport.position).to_r + @clip.length <= time.to_r
        end

        # The stream time at which a non-looping clip ends (estimated at the
        # current tempo), or nil for looping clips.
        def music_end
          return nil if @clip.looping?
          position + (@clip.length - clip_position) / clip_wnps
        end

        def to_s
          "#{super} #{@clip}"
        end

        # The first event of the clip as a note-on (see Source#first_note).
        def first_note
          note_event(@clip.events.first, 0r)
        end

        private

        # The clip event at the current clip position as a note-on (see
        # Source#chase).
        def chase_event
          note_event(@clip.event_at(clip_position), position)
        end

        # True if the clip event at the current clip position starts right
        # there (see Source::Chase#starts).
        def chase_starts_note?
          pos = clip_position
          e = @clip.event_at(pos) or return false
          phase = @clip.looping? && @clip.length > 0 ? pos % @clip.length : pos
          e.start == phase
        end

        # A Source::Chase for the clip event at the current clip position
        # (see Source#chase), with the event before it (around the loop) as
        # +previous+ and the stream seconds since it started at the current
        # tempo as +elapsed+.
        def chase_at(time)
          pos = clip_position
          e = @clip.event_at(pos) or return nil
          looping = @clip.looping? && @clip.length > 0
          phase = looping ? pos % @clip.length : pos
          since = phase - e.start
          since += @clip.length if since < 0 && looping
          prev = @clip.event_before(pos)
          # (the event's length from here as its length hint, like a
          # note-on read partway through its note)
          event = note_event(e, time)&.with_length_hint(Sequence::Duration.new(MB::M.max(e.length - since, 0r)))
          Chase.new(
            generation: @generation, time: time, event: event, starts: since == 0,
            previous: note_event(prev, time), elapsed: since / transport.whole_notes_per_second
          )
        end

        # A note-on Event for the clip +event+ at stream +time+, or nil.
        def note_event(event, time)
          event && Event.note_on(event.value, event.velocity, channel: @channel, time: time, pitch: event.pitch, flam: event.flam)
        end

        # Seeks to +time+ seconds into the clip at the current tempo.
        def seek_to(time)
          set_clip_position(time * transport.whole_notes_per_second)
        end

        # Starts at timeline position +time+ for a graph launched at
        # +origin+ (see Sequence::TimelineNode#start_at): looping clips play
        # in phase with the timeline (clip position = +time+), non-looping
        # clips from their start at +origin+.
        def timeline_start(time, origin)
          # A new launch (rather than a seek of the same graph) forgets the
          # anchor of an earlier swap
          fresh = @graph_origin != origin
          @swap_anchor = nil if fresh
          @graph_origin = origin

          if @clip.clocking
            clock_start(time, position, launch: @swap_anchor || timeline_launch || origin, origin: origin, fresh: fresh || @clock_graph.nil?)
            return jumped
          end
          @clock = nil
          @clock_anchor = nil

          @origin = clip_origin(@clip, @swap_anchor || timeline_launch || origin, origin)
          position = time - @origin
          set_clip_position(wrap_position(position))
          # Keep clip position + origin on the timeline when the position
          # wrapped (fill lookups and swap times add them; until omnibus5 a
          # launch a fraction of a sample after its first sample counted a
          # whole loop late, so fills played a loop early: night_bus_flow's
          # turn fill a bar early in both drops after the 2/4 gap)
          @origin -= @clip_position - position if @clip_position != position
          jumped
        end

        # Where +clip+'s position 0 falls on the timeline for a clip
        # launched at +launch+ (exact) in a graph whose first sample starts
        # at +origin+: 0 for timeline loops, +launch+ for launch-aligned
        # loops (so loop edges stay on the musical grid), +origin+ for
        # non-looping clips (their first edge on the first sample).
        def clip_origin(clip, launch, origin)
          if clip.launch_aligned?
            launch
          elsif clip.looping?
            0r
          else
            origin
          end
        end

        # A launch-aligned loop before its anchor (after a rewind, or within
        # the sample before an off-sample launch) plays the cycles leading up
        # to it, so its position wraps into the loop.
        def wrap_position(position)
          position < 0 && @clip.launch_aligned? ? position % @clip.length : position
        end

        # Sets the clip position (ending quiet reads; see #read_events).
        def set_clip_position(pos)
          @clip_position = pos
          @lazy_from = nil
          @quiet_frame = nil
        end

        def read_events(from, to)
          # Quiet reads: a read ending at or before the frame of the next
          # possible edge (see #arm_quiet) returns nothing after comparing
          # integer frames of its end (at the rate of the stream time's
          # grid); the clip position catches up when it's next needed, at
          # the same tempo.  A new tempo or clip, a jump, or a pending swap
          # takes the full read.
          if (q = @quiet_frame) && !@early && @pending_swap.nil? && @clip.equal?(@quiet_clip) &&
              transport.whole_notes_per_second.equal?(@quiet_wnps)
            r = @quiet_rate
            d = to.denominator
            if r % d == 0 && to.numerator * (r / d) <= q
              @lazy_from ||= from
              return Stream::NO_EVENTS
            end
          end
          if @lazy_from
            @clip_position += (from - @lazy_from) * @quiet_wnps
            @lazy_from = nil
          end
          @quiet_frame = nil

          clock_resume(from) if @clip.clocking && @clock_anchor.nil?
          swap = @pending_swap

          if swap
            clip, time = swap
            split, swap_time = swap_point(from, to, time)
            if split
              out = split > from ? read_span(from, split) : []
              out = out.dup if out.frozen? # (no edges: Stream::NO_EVENTS)
              @pending_swap = nil
              apply_swap(clip, swap_time, split)
              @generation = generation + 1
              @chase = chase_at(split)
              out << Jump.new(split)
              @early = true
              reset_flams(split)
              return out.concat(read_span(split, to))
            end
          end

          read_span(from, to)
        end

        # The edges for stream times [from, to): on the clip's clock, or at
        # the transport's tempo.
        def read_span(from, to)
          @clock ? clock_edges(from, to) : edges(from, to, transport.whole_notes_per_second)
        end

        # Where a pending swap for timeline time +time+ (nil: now) lands in
        # the read [from, to): [stream time, timeline time], or nil if
        # after it.
        def swap_point(from, to, time)
          if @clock
            start = clock_timeline(from)
            time ||= start
            split = time > start ? clock_stream_of_timeline(time) : from
            return nil unless split < to
            [split, MB::M.max(time, start)]
          else
            wnps = transport.whole_notes_per_second
            start = @clip_position + @origin
            time ||= start
            stop = start + (to - from) * wnps
            return nil unless time < stop
            split = time > start ? from + (time - start) / wnps : from
            [split, MB::M.max(time, start)]
          end
        end

        # Switches to +clip+ at timeline time +swap_time+ (stream time
        # +split+), on its clock if it has one.
        def apply_swap(clip, swap_time, split)
          @clip = clip
          @swap_anchor = clip.launch_aligned? ? swap_time : nil
          if clip.clocking
            clock_rf = @clock ? clock_rf_of(split) : nil
            clock_start(swap_time, split, launch_rf: clock_rf, fresh: true, rf: clock_rf)
          else
            @clock = nil
            @clock_anchor = nil
            @origin = clip_origin(clip, swap_time, swap_time)
            set_clip_position(swap_time - @origin)
          end
        end

        # Records a content jump (see Source#jumped); the next read plays
        # notes humanized to just before the new position (see
        # Sequence::Clip#edges's +:early+).
        def jumped
          super
          @early = true
          reset_flams
        end

        # Forgets flams read ahead (at a jump or swap): early note-ons for
        # steps at or after stream time +from+ (all if nil) are dropped, and reading
        # ahead starts again from the next read's position.
        def reset_flams(from = nil)
          @quiet_frame = nil # (flams read ahead; see #arm_quiet)
          @flam_start = nil
          @flam_to = nil
          @flam_queue = from ? (@flam_queue || []).select { |_e, step| step < from } : []
        end

        # The longest flam spacing of the clip (seconds): #flam_lead or a
        # longer mark's own time.
        def flam_window
          return @flam_window[1] if @flam_window && @flam_window[0].equal?(@clip)
          own = @clip.events.filter_map { |e| e.flam.is_a?(Numeric) && e.flam > 0 ? e.flam.to_f : nil }
          (@flam_window = [@clip, [@flam_lead, *own].max])[1]
        end

        # The flam-marked note-ons of clip positions [@flam_to, +look_to+),
        # queued at their early times, and the queued ones before stream
        # time +to+ (no earlier than +from+), removed from the queue.
        def early_flams(from, to, wn_from, wnps, look_to, fills)
          if @flam_to < look_to
            @clip.edges(@flam_to, look_to, early: false, fills: fills).each do |time, type, event, _cycle|
              next unless type == :on && event.flam

              seconds = event.flam.is_a?(Numeric) && event.flam > 0 ? event.flam.to_f : @flam_lead
              lead = MB::M.max((seconds * @flam_rate).round, 1) / @flam_rate
              step = from + (time - wn_from) / wnps
              e = Event.note_on(event.value, event.velocity, channel: @channel, time: MB::M.max(step - lead, from), pitch: event.pitch, flam: event.flam)
              @flam_queue << [e, step]
            end
            @flam_queue = @flam_queue.each_with_index.sort_by { |(e, _step), i| [e.time, i] }.map(&:first)
            @flam_to = look_to
          end

          due = @flam_queue.take_while { |e, _step| e.time < to }
          @flam_queue = @flam_queue.drop(due.length)
          due.map(&:first)
        end

        # Whole notes of the clip per stream second now (the clock's or
        # the transport's).
        def clip_wnps
          return transport.whole_notes_per_second unless @clock && @clock_anchor
          rf = @clock_anchor[1]
          s = @clock.step(rf, @clock_ctx) * @clock_scale * @clock_ctx.clock_rate
          s > 0 ? s : transport.whole_notes_per_second
        end

        # The clock context: the Session rendering this source, else a
        # Clock::Free counting from the graph's start.
        def clock_context
          span = Session.span
          span ? span.session : (@clock_ctx.is_a?(Clock::Free) ? @clock_ctx : Clock::Free.new(transport: transport))
        end

        # The Clock for the playing clip (named clocks from the context's
        # Session).
        def resolve_clock(ctx)
          Clock.resolve(@clip.clocking, ctx)
        end

        # Starts (or resyncs) the playing clip on its clock: timeline time
        # +time+ is stream time +t+.  A fresh start (a launch, a swap)
        # fixes where clip position 0 falls on the clock: nowhere special
        # for looping clips following session time (clip position = clock
        # position), the launch for launch-aligned loops, the graph's first
        # sample for one-shot clips; a seek keeps it.
        def clock_start(time, t, launch: nil, origin: nil, fresh: true, launch_rf: nil, rf: nil)
          ctx = clock_context
          c = resolve_clock(ctx)
          if ctx.is_a?(Session)
            rf ||= ctx.run_frame_of(time)
          else
            rf ||= @clock_anchor ? clock_rf_of(t) : 0r
          end
          @clock_ctx = ctx
          @clock = c
          @clock_anchor = [t.to_r, rf.to_r, time.to_r].freeze
          @clock_scale = c.unit == :cycles ? @clip.length : 1r
          raise ArgumentError, 'A clip on a period clock needs a length' if @clock_scale <= 0

          if fresh || @clock_origin.nil?
            @clock_graph = @graph_origin
            @clock_origin =
              if @clip.launch_aligned? || !@clip.looping?
                at = launch_rf || (ctx.is_a?(Session) && launch ? ctx.run_frame_of(launch) : rf)
                at = rf if at > rf && !@clip.looping? # (a launch a fraction of a sample later)
                c.position(at, ctx) * @clock_scale
              else
                0r
              end
          end

          set_clip_position(c.position(rf, ctx) * @clock_scale - @clock_origin)
          @clip_position %= @clip.length if @clip.looping? && @clip_position < 0 && @clip.length > 0
        end

        # A clocked clip read before any #start_at (outside a Session):
        # its clock counts from this read.
        def clock_resume(from)
          span = Session.span
          span ? clock_start(span.pos, from, rf: span.run) : clock_start(0r, from, rf: 0r)
        end

        # The run frame of stream time +t+.
        def clock_rf_of(t)
          a = @clock_anchor
          a[1] + (t.to_r - a[0]) * @clock_ctx.clock_rate
        end

        # The stream time of run frame +rf+.
        def clock_stream_of(rf)
          a = @clock_anchor
          a[0] + (rf - a[1]) / @clock_ctx.clock_rate
        end

        # The session timeline position at stream time +t+.
        def clock_timeline(t)
          span = Session.span
          if span && span.session.equal?(@clock_ctx)
            span.pos + (clock_rf_of(t) - span.run) * span.per_sample
          else
            @clock_anchor[2] + (t.to_r - @clock_anchor[0]) * transport.whole_notes_per_second
          end
        end

        # The stream time of session timeline position +pos+ (in the span
        # being rendered).
        def clock_stream_of_timeline(pos)
          span = Session.span
          if span && span.session.equal?(@clock_ctx) && span.per_sample > 0
            clock_stream_of(span.run + (pos.to_r - span.pos) / span.per_sample)
          else
            @clock_anchor[0] + (pos.to_r - @clock_anchor[2]) / transport.whole_notes_per_second
          end
        end

        # Edges for stream times [from, to) on the clip's clock: each linear
        # piece of the clock at its own tempo, the clip position set from the
        # clock at each piece (exact Rationals, so the same at any buffer
        # size).
        def clock_edges(from, to)
          ctx = @clock_ctx
          rate = ctx.clock_rate
          a = clock_rf_of(from)
          b = clock_rf_of(to)
          out = []
          @clock.pieces(a, b, ctx).each do |r0, r1, pos0, step|
            t0 = r0 == a ? from.to_r : clock_stream_of(r0)
            t1 = r1 == b ? to.to_r : clock_stream_of(r1)
            set_clip_position(pos0 * @clock_scale - @clock_origin)
            @clip_position %= @clip.length if @clip.looping? && @clip_position < 0 && @clip.length > 0
            out.concat(edges(t0, t1, step * @clock_scale * rate))
          end
          out
        end

        # The sample rate whose frames quiet reads count (with the
        # denominator of the read's end time, so reads on any rate's grid
        # count whole frames; see #arm_quiet).
        QUIET_BASE_RATE = 48000

        # Arms quiet reads (see #read_events) after a full read ending at
        # stream time +to+, clip position +wn+, at +wnps+ whole notes per
        # second: finds the last frame, at a rate r on whose grid +to+
        # lies, that a read can end on before the next possible edge or
        # loop cycle (see Sequence::Clip#edge_horizon).  A read ending on
        # frame F covers stream times before F / r, so an edge at time t
        # is still ahead while F <= floor(t * r) (the frame it lands on,
        # the same rule as Notes' sample offsets), and a cycle starting at
        # time c is still unread while F <= ceil(c * r) - 1.
        def arm_quiet(to, wn, wnps)
          return unless wnps > 0
          edge, cap = @clip.edge_horizon(wn)
          return if edge.nil? && cap.nil?
          if @clip.controls? && (ctl = @clip.control_horizon(wn)) && (edge.nil? || ctl < edge)
            edge = ctl
          end

          r = QUIET_BASE_RATE.lcm(to.denominator)
          q = edge && ((to + (edge - wn) / wnps) * r).floor
          if cap
            c = ((to + (cap - wn) / wnps) * r).ceil - 1
            q = c if q.nil? || c < q
          end

          @quiet_frame = q
          @quiet_rate = r
          @quiet_wnps = wnps
          @quiet_clip = @clip
        end

        # Note Events +notes+ of stream times [from, to) (clip positions
        # [wn_from, wn_to) at +wnps+) with the clip's controller values
        # (Sequence::Clip#control_edges) merged in, a controller before the
        # notes at the same time (so a note starts with the value sent on
        # its step).  After a launch, seek, swap (+early+), or a skipped
        # span (Source#read past the position), each lane's value from
        # before the new position comes first, at +from+.
        def with_controls(notes, from, wn_from, wn_to, wnps, early)
          ctl = @clip.control_edges(wn_from, wn_to)
          fresh = early || @jump_pending
          chase = fresh ? @clip.control_chase(wn_from) : Sequence::Clip::EMPTY_CHASE
          return notes if ctl.empty? && chase.empty? && !fresh

          list = fresh ? @clip.controls.flat_map { |l| l.setup_events(channel: @channel, time: from) } : []
          chase.each { |lane, v| list << lane.event(v, channel: @channel, time: from) }
          return notes if list.empty? && ctl.empty?
          ctl.each { |time, lane, v| list << lane.event(v, channel: @channel, time: from + (time - wn_from) / wnps) }
          return list if notes.empty?

          # (both lists are sorted by time; controllers first at equal times)
          out = []
          i = j = 0
          while i < list.length || j < notes.length
            if j >= notes.length || (i < list.length && list[i].time <= notes[j].time)
              out << list[i]
              i += 1
            else
              out << notes[j]
              j += 1
            end
          end
          out
        end

        # Converts the clip's edges for stream times [from, to) to Events and
        # advances the clip position.
        def edges(from, to, wnps)
          wn_from = @clip_position
          wn_to = wn_from + (to - from) * wnps
          @clip_position = wn_to
          early = @early
          @early = false

          fills = @clock ? nil : (@fills_at ||= ->(pos) { transport.fills.names_at(pos + @origin) })

          # Flams at or after @flam_start play early (see #play_flams_early)
          if @flam_lead && @flam_start.nil?
            @flam_start = wn_from + flam_window * wnps
            @flam_to = @flam_start
          end
          start = @flam_lead && @flam_start

          found = @clip.edges(wn_from, wn_to, early: early, fills: fills)
          arm_quiet(to, wn_to, wnps) if @flam_lead.nil? && @clock.nil? && self.class.quiet_reads
          out = found.empty? ? Stream::NO_EVENTS : found.filter_map { |time, type, event, cycle|
            t = from + (time - wn_from) / wnps
            if type == :on
              next if start && event.flam && time >= start
              # The note's length from here (its note-on may have moved to
              # a read start), in whole notes so it follows the tempo
              hint = Sequence::Duration.new(MB::M.max(cycle * @clip.length + event.start + event.length - time, 0r))
              Event.note_on(event.value, event.velocity, channel: @channel, time: t, pitch: event.pitch, flam: event.flam, length_hint: hint)
            else
              Event.note_off(event.value, channel: @channel, time: t)
            end
          }
          out = with_controls(out, from, wn_from, wn_to, wnps, early) if @clip.controls?
          return out unless start

          # Not past a pending swap (its clip may have no flams there)
          look_to = wn_to + flam_window * wnps
          if (swap = @pending_swap)
            look_to = MB::M.min(look_to, swap[1] ? swap[1] - @origin : wn_to)
          end
          due = early_flams(from, to, wn_from, wnps, look_to, fills)
          return out if due.empty?
          (out + due).each_with_index.sort_by { |e, i| [e.time, i] }.map(&:first)
        end
      end
    end
  end
end
