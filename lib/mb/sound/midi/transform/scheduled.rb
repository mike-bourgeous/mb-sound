module MB
  module Sound
    module MIDI
      class Transform
        # Base class for transforms that send events later than they
        # arrive (echo, strum, humanize, input quantize, the arpeggiator):
        # the future-event pattern of the MIDI transforms proposal.
        #
        # Subclasses handle each input event (#input_event, or #process for
        # transforms with their own clock) by scheduling output events
        # (#schedule_on, #schedule_off, #schedule) at their time or later.
        # Every read sends the queued events due before its end, in time
        # order, and keeps the rest, so readers never see an event before
        # its time and readers at any rate or buffer size get the same
        # events.
        #
        # No stuck notes (user decision 1, 2026-10-09): every output
        # note-on has an id, and a ledger of sounding notes decides which
        # note-offs go out, so the output is always balanced:
        # - +overlap: :retrigger+ (default) - a key (channel, note) belongs
        #   to its newest note-on: a note-on on a sounding key sends a
        #   note-off first, and the older note's own note-off is dropped
        #   later.  A synth plays the new note on another voice while the
        #   old one releases (voices permitting), so nothing is cut short
        #   beyond its release.
        # - +overlap: :stack+ - notes on the same key overlap: each note-on
        #   goes out, and each note-off ends one of them.  The Allocator
        #   gives every stacked note its own voice (ending them oldest
        #   first), like Synth's +retrigger: :ring+ for bells.
        # Both: a note-off due at the same time as its own note-on goes
        # out right after it; notes still sounding when the input has ended
        # and nothing is queued get note-offs; +jump: :cut+ drops the queue
        # and releases everything at a content jump (seek, restart, clip
        # swap), while +jump: :ring+ (default) keeps queued events, so
        # echoes ring on through jumps like an audio delay's (the source's
        # own note-offs at the jump close the played notes, which end
        # their echo chains as usual).
        #
        # Scheduled transforms are TimelineNodes (see Transform::Timeline),
        # so they get the Session's Transport for Durations.
        class Scheduled < Transform
          include Timeline

          # Choices for +:overlap+ (see the class description).
          OVERLAPS = [:retrigger, :stack].freeze

          # Choices for +:jump+ (see the class description).
          JUMPS = [:ring, :cut].freeze

          # How same-key notes overlap (:retrigger or :stack).
          attr_reader :overlap

          # What happens to queued events at a content jump (:ring or :cut).
          attr_reader :jump_mode

          def initialize(parent, overlap: :retrigger, jump: :ring, transport: nil)
            super(parent)
            raise ArgumentError, "overlap must be one of #{OVERLAPS.map(&:inspect).join(', ')} (got #{overlap.inspect})" unless OVERLAPS.include?(overlap)
            raise ArgumentError, "jump must be one of #{JUMPS.map(&:inspect).join(', ')} (got #{jump.inspect})" unless JUMPS.include?(jump)

            @overlap = overlap
            @jump_mode = jump
            @transport = transport

            @queue = [] # [time, order, sequence number, event, id]; note-offs sort first
            @sequence = 0
            @next_id = 0
            @sounding = {} # [channel, note] => Array of ids (oldest first)
            @pending = {}  # id => true for note-ons not sent yet
            @early_off = {} # id => true for note-offs that came before their note-on
          end

          # True once the input has ended and every queued event has been
          # sent (sounding notes get note-offs then; see #read_events).
          def ended?
            @input.ended? && @queue.empty? && @sounding.empty?
          end

          # The parent's music end plus #tail_seconds, or nil.
          def music_end
            m = super
            m && m + tail_seconds
          end

          # The number of events waiting in the queue.
          def pending_count
            @queue.length
          end

          # The number of output notes sounding (sent and not ended).
          def sounding_count
            @sounding.sum { |_, ids| ids.length }
          end

          private

          # How long after the input's last event this transform may still
          # send events (seconds), for #music_end.  Override.
          def tail_seconds
            0
          end

          # Unlike stateless transforms, this runs every read (queued events
          # come due without input).
          def read_events(from, to)
            events = @input.events(from, to)
            out = []

            if @parent.generation != @seen_generation
              @seen_generation = @parent.generation
              out.concat(jump(from))
            end

            process(events, from, to)
            flush(to, out)

            # Once the input is over and nothing is queued, nothing can
            # end the notes still sounding (e.g. a held key whose note-off
            # never came): release them so they can't hang
            release_all(MB::M.max(from, out.last&.time || from), out) if @input.ended? && @queue.empty?

            advance_timeline(to)

            out.empty? ? Stream::NO_EVENTS : out
          end

          # Handles one read's input events (in time order).  Override for
          # transforms with clocks; by default calls #input_event for each.
          def process(events, _from, _to)
            events.each { |e| input_event(e) }
          end

          # Handles one input event.  By default passes it through at its
          # time (note events through the ledger with new ids would need
          # matching; subclasses handle notes).
          def input_event(event)
            schedule(event)
          end

          # Returns a new note id.
          def new_id
            @next_id += 1
          end

          # Schedules a note-on +event+ (at its time) with +id+ (a new one
          # by default); returns the id.
          def schedule_on(event, id = new_id)
            @pending[id] = true
            schedule(event, id)
            id
          end

          # Schedules the note-off +event+ of the note with +id+.
          def schedule_off(event, id)
            schedule(event, id)
          end

          # Inserts +event+ into the time-sorted queue (note-offs before
          # other events at the same time, then first scheduled first).
          def schedule(event, id = nil)
            order = event.type == :note_off ? 0 : 1
            item = [event.time, order, (@sequence += 1), event, id]
            last = @queue.last
            if last.nil? || last[0] < item[0] || (last[0] == item[0] && last[1] <= order)
              @queue << item
            else
              idx = @queue.bsearch_index { |q| q[0] > item[0] || (q[0] == item[0] && (q[1] > order || (q[1] == order && q[2] > item[2]))) } || @queue.length
              @queue.insert(idx, item)
            end
            id
          end

          # Sends the queued events before +to+ into +out+.
          def flush(to, out)
            while (q = @queue.first) && q[0] < to
              @queue.shift
              emit(q[3], q[4], out)
            end
          end

          # Sends a queued event through the ledger (see the class
          # description).
          def emit(event, id, out)
            case event.type
            when :note_on
              key = [event.channel, event.note]
              @pending.delete(id)
              ids = (@sounding[key] ||= [])
              if @overlap == :retrigger && !ids.empty?
                out << Event.note_off(event.note, channel: event.channel, time: event.time)
                ids.clear
              end
              ids << id
              out << event

              if @early_off.delete(id)
                ids.delete(id)
                @sounding.delete(key) if ids.empty?
                out << Event.note_off(event.note, channel: event.channel, time: event.time)
              end

            when :note_off
              if id && @pending.key?(id)
                @early_off[id] = true
                return
              end

              key = [event.channel, event.note]
              ids = @sounding[key]
              if ids && (id ? ids.delete(id) : ids.shift)
                @sounding.delete(key) if ids.empty?
                out << event
              end

            else
              out << event
            end
          end

          # At a content jump: +jump: :cut+ drops queued notes and releases
          # every sounding note at +from+; :ring keeps them (see the class
          # description).  Returns the events to send at +from+.
          def jump(from)
            return [] if @jump_mode == :ring

            @queue.reject! { |q| q[3].note? }
            @pending.clear
            @early_off.clear
            cut_state
            out = []
            release_all(from, out)
            out
          end

          # Forgets subclass state for a +jump: :cut+.  Override.
          def cut_state
          end

          # Sends note-offs at +time+ for every sounding note.
          def release_all(time, out)
            @sounding.each do |(channel, note), ids|
              ids.length.times { out << Event.note_off(note, channel: channel, time: time) }
            end
            @sounding.clear
          end
        end
      end
    end
  end
end
