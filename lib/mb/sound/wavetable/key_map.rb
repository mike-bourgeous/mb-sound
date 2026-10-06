module MB
  module Sound
    class Wavetable
      # Key zones: tables for ranges of notes, like a sampler's multisample
      # map or the SQ-80's 8-semitone wave zones.  Give it to a tone in place
      # of a table (`v.hz.wavetable(map)`; see Tone#wavetable): the tone
      # picks the zone from its pitch (in the session tuning) when it starts
      # and at every reset (key sync, e.g. each note of a synth voice), or at
      # the start of every buffer if it has no reset input.  Notes below the
      # first zone or above the last use the nearest zone, as do notes in
      # gaps.
      #
      #     map = Wavetable::KeyMap.new(C1...C3 => :saw, C3..C8 => :square)
      #     map = Wavetable::KeyMap.zones([:saw, :square, :triangle], from: C2, size: 8)
      class KeyMap
        # Consecutive zones of +size+ semitones starting at +from+ (a note
        # number or a Note), one per table (anything Wavetable.[] accepts).
        def self.zones(tables, from: 36, size: 8)
          start = note_number(from)
          new(tables.each_with_index.to_h { |t, i| [(start + i * size)...(start + (i + 1) * size), t] })
        end

        # A Note, Pitch, or number as a (fractional) note number.
        def self.note_number(v)
          return v.number.to_f if v.respond_to?(:number)
          return MB::Sound.tuning.number_of(v.frequency) if v.respond_to?(:frequency)

          Float(v)
        end

        # [low, high, table] for each zone, sorted by note (high is
        # exclusive for begin...end ranges).
        attr_reader :zones

        # +zones+ is a Hash (or Array of pairs) of note Ranges (note numbers
        # or Notes) to tables (anything Wavetable.[] accepts).
        def initialize(zones)
          raise ArgumentError, 'A key map needs at least one zone' if zones.empty?

          @zones = zones.map { |range, table|
            raise ArgumentError, "Key zones must be Ranges of notes (got #{range.inspect})" unless range.is_a?(Range)

            low = range.begin.nil? ? -Float::INFINITY : KeyMap.note_number(range.begin)
            high = range.end.nil? ? Float::INFINITY : KeyMap.note_number(range.end)
            high += 1 unless range.end.nil? || range.exclude_end?
            [low, high, Wavetable[table]].freeze
          }.sort_by(&:first).freeze

          kinds = @zones.map { |z| z[2].complex? }.uniq
          raise ArgumentError, 'Key zones must be all real or all complex tables' if kinds.length > 1
        end

        # The tables of the zones, in note order.
        def tables
          @zones.map(&:last)
        end

        # True if the zones' tables are complex.
        def complex?
          @zones[0][2].complex?
        end

        # The table for +note+ (a fractional note number).
        def table_for(note)
          best = nil
          best_dist = nil
          @zones.each do |low, high, table|
            return table if note >= low && note < high

            dist = note < low ? low - note : note - high
            if best_dist.nil? || dist < best_dist
              best = table
              best_dist = dist
            end
          end
          best
        end

        # The table for a frequency in Hz (in the session tuning).
        def table_for_frequency(hz)
          table_for(MB::Sound.tuning.number_of(hz))
        end

        def to_s
          'KeyMap(' + @zones.map { |low, high, t| "#{low}...#{high} => #{t.name || t}" }.join(', ') + ')'
        end
      end
    end
  end
end
