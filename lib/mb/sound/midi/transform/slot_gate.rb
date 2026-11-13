module MB
  module Sound
    module MIDI
      class Transform
        # The notes a rack slot's content hears (GraphNode::Slot with a
        # notes input; racks R3): the slot's input stream, gated by note
        # ownership around a swap ("patch persist"), so the content playing
        # before the swap keeps the notes it started (their note-offs, poly
        # pressure) and rings out, while every note starting on or after the
        # swap goes to the new content.  Channel-wide events (controllers,
        # bend, the sustain pedal) reach both.
        #
        # Modes: :all (the slot's only content: everything passes), :old
        # (handed over at parent time #switch: note-ons from then on are
        # dropped, with their note-offs), :new (a content waiting to start:
        # nothing passes until it starts, then notes from #switch on).
        #
        # A content built ahead of its swap reads this stream from where it
        # was built; #start shifts it so its next read reads the parent from
        # the slot's current time (+shift+: parent time minus this stream's
        # time; event times are given in this stream's time).
        #
        # Walks of a content's graph end here (#sources is empty): the Slot
        # lists its input instead, so a content's timeline nodes, knobs, and
        # slots never include the player's own clips.
        class SlotGate < Transform
          # :all, :old, or :new (see the class description).
          attr_reader :mode

          # The parent stream time where this content's notes stop (:old)
          # or start (:new), or nil.
          attr_reader :switch

          # Parent stream time minus this stream's time.
          attr_reader :shift

          def initialize(parent, mode: :all)
            raise ArgumentError, "Slot gate modes are :all, :old, :new (got #{mode.inspect})" unless %i[all old new].include?(mode)
            super(parent)
            @mode = mode
            @switch = nil
            @shift = 0r
            @owned = Hash.new(0)
            @node_type_name = 'slot gate'
          end

          # This content stops taking notes that start at parent time +time+
          # or later (it keeps the notes it started; see the class
          # description).
          def hand_over(time)
            @mode = :old
            @switch = time.to_r
            self
          end

          # This content starts on parent time +time+ (its first frame: a
          # content starting inside the slot's buffer is read from there):
          # its next read reads the parent from +time+, and notes starting
          # there or later are its own.
          def start(time)
            @shift = time.to_r - position
            @mode = :new
            @switch = time.to_r
            self
          end

          # Notes this content started that are still sounding (for specs).
          def owned_count
            @owned.values.sum
          end

          def sources
            {}
          end

          private

          def read_events(from, to)
            s = @shift
            events = @input.events(from + s, to + s)
            gen = @parent.generation
            return Stream::NO_EVENTS if events.empty? && gen == @seen_generation
            @seen_generation = gen if gen != @seen_generation

            out = []
            events.each do |e|
              next unless keep?(e)
              out << (s.zero? ? e : e.with(time: e.time - s))
            end
            out
          end

          # True if event +e+ (in parent time) reaches this content, keeping
          # count of the notes it owns.
          def keep?(e)
            case e.type
            when :note_on
              mine = case @mode
                     when :all then true
                     when :old then e.time < @switch
                     else !@switch.nil? && e.time >= @switch
                     end
              @owned[[e.channel, e.note]] += 1 if mine
              mine
            when :note_off
              key = [e.channel, e.note]
              n = @owned[key]
              return @mode == :all if n <= 0 # (an :all content passes stray note-offs, as the stream gives them)
              n == 1 ? @owned.delete(key) : @owned[key] = n - 1
              true
            when :poly_pressure
              @mode == :all || @owned[[e.channel, e.note]] > 0
            else
              @mode != :new || (!@switch.nil? && e.time >= @switch)
            end
          end
        end
      end
    end
  end
end
