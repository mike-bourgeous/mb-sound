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

        # The current clip position in whole notes (a Rational).
        attr_reader :clip_position

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
          !@clip.looping? && @clip_position > @clip.length
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

        # The first event of the clip as a note-on (see Source#first_note).
        def first_note
          note_event(@clip.events.first, 0r)
        end

        private

        # The clip event at the current clip position as a note-on (see
        # Source#chase).
        def chase_event
          note_event(@clip.event_at(@clip_position), position)
        end

        # True if the clip event at the current clip position starts right
        # there (see Source::Chase#starts).
        def chase_starts_note?
          e = @clip.event_at(@clip_position) or return false
          phase = @clip.looping? && @clip.length > 0 ? @clip_position % @clip.length : @clip_position
          e.start == phase
        end

        # A Source::Chase for the clip event at the current clip position
        # (see Source#chase), with the event before it (around the loop) as
        # +previous+ and the stream seconds since it started at the current
        # tempo as +elapsed+.
        def chase_at(time)
          e = @clip.event_at(@clip_position) or return nil
          looping = @clip.looping? && @clip.length > 0
          phase = looping ? @clip_position % @clip.length : @clip_position
          since = phase - e.start
          since += @clip.length if since < 0 && looping
          prev = @clip.event_before(@clip_position)
          Chase.new(
            generation: @generation, time: time, event: note_event(e, time), starts: since == 0,
            previous: note_event(prev, time), elapsed: since / transport.whole_notes_per_second
          )
        end

        # A note-on Event for the clip +event+ at stream +time+, or nil.
        def note_event(event, time)
          event && Event.note_on(event.value, event.velocity, channel: @channel, time: time, pitch: event.pitch, flam: event.flam)
        end

        # Seeks to +time+ seconds into the clip at the current tempo.
        def seek_to(time)
          @clip_position = time * transport.whole_notes_per_second
        end

        # Starts at timeline position +time+ for a graph launched at
        # +origin+ (see Sequence::TimelineNode#start_at): looping clips play
        # in phase with the timeline (clip position = +time+), non-looping
        # clips from their start at +origin+.
        def timeline_start(time, origin)
          # A new launch (rather than a seek of the same graph) forgets the
          # anchor of an earlier swap
          @swap_anchor = nil if @graph_origin != origin
          @graph_origin = origin

          @origin = clip_origin(@clip, @swap_anchor || timeline_launch || origin, origin)
          position = time - @origin
          @clip_position = wrap_position(position)
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

        def read_events(from, to)
          wnps = transport.whole_notes_per_second
          swap = @pending_swap

          if swap
            clip, time = swap
            start = @clip_position + @origin
            time ||= start
            stop = start + (to - from) * wnps

            if time < stop
              split = time > start ? from + (time - start) / wnps : from
              out = split > from ? edges(from, split, wnps) : []
              @pending_swap = nil
              @clip = clip
              swap_time = MB::M.max(time, start)
              @swap_anchor = clip.launch_aligned? ? swap_time : nil
              @origin = clip_origin(clip, swap_time, swap_time)
              @clip_position = swap_time - @origin
              @generation = generation + 1
              @chase = chase_at(split)
              out << Jump.new(split)
              @early = true
              reset_flams(split)
              return out.concat(edges(split, to, wnps))
            end
          end

          edges(from, to, wnps)
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

        # Converts the clip's edges for stream times [from, to) to Events and
        # advances the clip position.
        def edges(from, to, wnps)
          wn_from = @clip_position
          wn_to = wn_from + (to - from) * wnps
          @clip_position = wn_to
          early = @early
          @early = false

          fills = @fills_at ||= ->(pos) { transport.fills.names_at(pos + @origin) }

          # Flams at or after @flam_start play early (see #play_flams_early)
          if @flam_lead && @flam_start.nil?
            @flam_start = wn_from + flam_window * wnps
            @flam_to = @flam_start
          end
          start = @flam_lead && @flam_start

          out = @clip.edges(wn_from, wn_to, early: early, fills: fills).filter_map { |time, type, event, cycle|
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
