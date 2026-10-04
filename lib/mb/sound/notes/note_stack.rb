module MB
  module Sound
    class Notes
      # The held notes of a mono (last-note priority) reading of a stream:
      # the newest held note is on top, and releasing it uncovers the one
      # held before it.  Notes are counted per (channel, note), so
      # overlapping notes on one key (on, on, off, off) stay held until the
      # last note-off.  Used by the note nodes of Notes (gate, number, ...).
      class NoteStack
        # One held key: its +note+ (the event's note value), the +velocity+
        # of its latest note-on, and how many note-ons are unmatched.
        Entry = Struct.new(:key, :note, :velocity, :count)

        def initialize
          @entries = []
        end

        # Adds a note-on Event (moving its key to the top if already held).
        def note_on(event)
          key = [event.channel, event.note]
          idx = @entries.index { |e| e.key == key }
          entry = idx ? @entries.delete_at(idx) : Entry.new(key, event.note, event.velocity, 0)
          entry.count += 1
          entry.velocity = event.velocity
          @entries.push(entry)
          entry
        end

        # Removes one note-on of the note-off Event's key.  Returns true if
        # the key was held.
        def note_off(event)
          key = [event.channel, event.note]
          idx = @entries.rindex { |e| e.key == key }
          return false unless idx

          entry = @entries[idx]
          entry.count -= 1
          @entries.delete_at(idx) if entry.count <= 0
          true
        end

        # Forgets every held note.
        def clear
          @entries.clear
          self
        end

        # The newest held Entry, or nil.
        def top
          @entries.last
        end

        # True if any note is held.
        def held?
          !@entries.empty?
        end

        # The number of held keys.
        def length
          @entries.length
        end
      end
    end
  end
end
