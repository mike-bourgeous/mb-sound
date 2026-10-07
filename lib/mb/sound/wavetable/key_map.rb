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
      # With +normalize: :loudness+, each zone's table is scaled so it plays
      # as loud as the others at the middle of its zone (perceived loudness,
      # see Loudness; sample-mode tables at their pitch there): the level
      # stays put as a scale crosses zones of different tables.  The zones
      # meet at the mean loudness of the tables as given.
      #
      #     map = Wavetable::KeyMap.new(C1...C3 => :saw, C3..C8 => :square)
      #     map = Wavetable::KeyMap.zones([:saw, :square, :triangle], from: C2, size: 8)
      #     map = Wavetable::KeyMap.zones([:sine, :organ, :saw, :pulses], from: C2, size: 12, normalize: :loudness)
      class KeyMap
        # Consecutive zones of +size+ semitones starting at +from+ (a note
        # number or a Note), one per table (anything Wavetable.[] accepts);
        # +normalize+ as for #initialize.
        def self.zones(tables, from: 36, size: 8, normalize: nil)
          start = note_number(from)
          new(tables.each_with_index.to_h { |t, i| [(start + i * size)...(start + (i + 1) * size), t] }, normalize: normalize)
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

        # How the zones' tables were scaled (nil or :loudness).
        attr_reader :normalize

        # +zones+ is a Hash (or Array of pairs) of note Ranges (note numbers
        # or Notes) to tables (anything Wavetable.[] accepts).  +normalize:
        # :loudness+ matches the zones' perceived loudness (see the class
        # description).
        def initialize(zones = nil, normalize: nil, **braceless)
          # KeyMap.new(C1...C3 => :saw, ...) passes the zones as keywords
          raise ArgumentError, 'Give the zones as a Hash or as keywords, not both' if zones && !braceless.empty?

          zones ||= braceless
          raise ArgumentError, 'A key map needs at least one zone' if zones.empty?
          raise ArgumentError, "Unknown normalize #{normalize.inspect} (nil or :loudness)" unless normalize.nil? || normalize == :loudness

          @zones = zones.map { |range, table|
            raise ArgumentError, "Key zones must be Ranges of notes (got #{range.inspect})" unless range.is_a?(Range)

            low = range.begin.nil? ? -Float::INFINITY : KeyMap.note_number(range.begin)
            high = range.end.nil? ? Float::INFINITY : KeyMap.note_number(range.end)
            high += 1 unless range.end.nil? || range.exclude_end?
            [low, high, Wavetable[table]].freeze
          }.sort_by(&:first).freeze

          kinds = @zones.map { |z| z[2].complex? }.uniq
          raise ArgumentError, 'Key zones must be all real or all complex tables' if kinds.length > 1

          @normalize = normalize
          match_loudness if normalize == :loudness
        end

        # The perceived loudness in dB of each zone's table at the middle of
        # its zone (see Loudness; the power mean of a cycle table's frames).
        def zone_loudness
          @zones.map { |low, high, table| KeyMap.table_db(table, KeyMap.zone_pitch(low, high)) }
        end

        # The pitch (Hz, equal temperament) at the middle of a zone from note
        # +low+ to +high+ (either may be infinite).
        def self.zone_pitch(low, high)
          note = if low.finite? && high.finite?
                   (low + high) / 2.0
                 elsif low.finite?
                   low + 6
                 elsif high.finite?
                   high - 6
                 else
                   60.0
                 end
          440.0 * 2**((note - 69) / 12.0)
        end

        # The perceived loudness in dB of +table+ played at +pitch+ Hz.
        def self.table_db(table, pitch)
          if table.mode == :cycle
            spectra = table.derivative_spectra
            power = Array.new(spectra.shape[0]) { |r| Loudness.frame_power(spectra[r, true], pitch) }.sum / spectra.shape[0]
            power > 0 ? 10 * Math.log10(power) : -Float::INFINITY
          else
            table.loudness([pitch])[0]
          end
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

        private

        # Scales the zones' tables to their mean loudness (see #initialize).
        def match_loudness
          dbs = zone_loudness
          finite = dbs.select(&:finite?)
          return if finite.empty?

          target = finite.sum / finite.length
          @zones = @zones.each_with_index.map { |(low, high, table), i|
            next [low, high, table].freeze unless dbs[i].finite?

            [low, high, table.scaled(10**((target - dbs[i]) / 20.0))].freeze
          }.freeze
        end
      end
    end
  end
end
