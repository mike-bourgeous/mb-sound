module MB
  module Sound
    module MIDI
      # Turns the notes of a finite MIDI source (e.g. a FileSource) into a
      # list of Hashes with start, key release, and pedal release times, for
      # tools that show or analyze whole files (bin/midi/midi_roll.rb; see
      # FileSource#notes).  Pedals come from the Stream's sustain transform
      # (Stream#sustain), the same pedal handling synths use.
      #
      # Each note:
      #
      #     {
      #       channel: 0..15,        # 0-based
      #       number: 0..127,        # note number
      #       on_velocity: 1..127,   # raw note-on velocity (before the soft pedal)
      #       off_velocity: 0..127,  # raw release velocity
      #       on_time: Float,        # seconds from the start of the source
      #       off_time: Float,       # when the key was released
      #       sustain_time: Float,   # when the sound was released: off_time, or
      #                              # later if a pedal held the note
      #     }
      #
      # A note-on of a key that is still sounding (held down, or held by a
      # pedal) ends the earlier note at that time.  Notes still held down at
      # the end end at +:end_time+; notes still held by a pedal end at the
      # last event (where the sustain transform lets them go).
      module NoteList
        # Returns the notes of +source+ (anything MIDI::Stream.for accepts;
        # it is read from its current position to +:end_time+ seconds),
        # sorted by start time, then channel, note number, and release time.
        def self.notes(source, end_time:)
          stream = Stream.for(source)
          raw_reader = stream.reader
          pedaled_reader = stream.sustain.reader

          from = raw_reader.cursor
          to = MB::M.max(end_time.to_r, from) + 1
          keys = pair(raw_reader.events(from, to), end_time)
          sounds = pair(pedaled_reader.events(from, to), end_time)
          raw_reader.close
          pedaled_reader.close

          keys.flat_map { |key, list|
            released = sounds[key] || []
            list.each_with_index.map { |n, idx|
              n.merge(sustain_time: MB::M.max(released[idx]&.dig(:off_time) || n[:off_time], n[:off_time]))
            }
          }.sort_by { |n| [n[:on_time], n[:channel], n[:number], n[:off_time], n[:sustain_time]] }
        end

        # Returns the minimum, median, and maximum note number of +notes+
        # (Hashes with :number and :channel, or note numbers), or 64 for each
        # if there are none.  Only notes on +:channel+ (0-based) if given.
        def self.stats(notes, channel: nil)
          numbers = notes.filter_map { |n|
            next n if n.is_a?(Integer)
            n[:number] if channel.nil? || n[:channel] == channel
          }.sort

          [
            numbers[0] || 64,
            numbers[numbers.length / 2] || 64,
            numbers[-1] || 64,
          ]
        end

        # Pairs note-ons with note-offs per [channel, note] (a new note-on
        # ends a sounding note of the same key; unmatched note-offs are
        # ignored).  Returns { [channel, note] => [note Hash, ...] } in
        # note-on order.
        def self.pair(events, end_time)
          open = {}
          out = Hash.new { |h, k| h[k] = [] }

          events.each do |e|
            next unless e.channel && (e.type == :note_on || e.type == :note_off)

            key = [e.channel, e.note]
            t = e.time.to_f

            if (n = open.delete(key))
              n[:off_velocity] = e.type == :note_off ? e.raw : n[:on_velocity]
              n[:off_time] = t
            end

            next unless e.type == :note_on

            n = { channel: e.channel, number: e.note, on_velocity: e.raw, off_velocity: nil, on_time: t, off_time: nil }
            open[key] = n
            out[key] << n
          end

          open.each_value do |n|
            n[:off_velocity] ||= n[:on_velocity]
            n[:off_time] ||= end_time.to_f
          end

          out
        end
        private_class_method :pair
      end
    end
  end
end
