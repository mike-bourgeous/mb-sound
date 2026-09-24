module MB
  module Sound
    # Methods included in MB::Sound for building musical sequences.  See
    # MB::Sound::Sequence.
    module SequenceMethods
      # Returns a Sequence::Seq that plays the given +items+ one after
      # another.  Items may be Notes (C4), note lengths (C4.n8), numbers (MIDI
      # note numbers or other values), nil or #rest for a rest, or other
      # clips.  Steps without a length can be given one all at once:
      #
      #     seq(C4, E4, G4.n4).n8     # two eighth notes and a quarter note
      #     seq(C4.n8.d, E4.n16, rest.n4, seq(G4, A4).n16 * 2)
      def seq(*items, seed: 0)
        Sequence::Seq.new(items, seed: seed)
      end

      # Returns a one-step rest with its length unset (e.g. `rest.n8`).
      def rest
        Sequence::Seq.new([nil])
      end

      # Parses step-sequencer strings with steps of 1/+division+ whole notes
      # (an Integer note division or Rational whole notes).  One character is
      # one step: x = hit, X = accent, 1-9 = velocity, ? = 50% chance, . =
      # rest, and | or space are ignored.  See Sequence::Grid::SYMBOLS.
      #
      # With a single String, returns a Seq.  With named rows, returns a
      # Sequence::Kit whose rows are Seqs; names are General MIDI drum names
      # (Sequence::Grid::GM_DRUMS), Notes, or numbers, unless given in +:map+.
      #
      #     grid(16, 'x...x...')
      #     grid(16, kick: 'x...x...x...x.x.', snare: '....x.......x...', hat: 'x.x.x.x.x.x.x.xX')
      def grid(division, pattern = nil, value: Sequence::Grid::GM_DRUMS[:kick], map: {}, seed: 0, **rows)
        if pattern
          raise ArgumentError, 'Pass either a single pattern or named rows, not both' if rows.any?
          Sequence::Grid.parse(division, pattern, value: value, seed: seed)
        else
          raise ArgumentError, 'Pass a pattern String or named rows' if rows.empty?
          Sequence::Kit.new(rows.to_h { |name, pat|
            [name, Sequence::Grid.parse(division, pat, value: Sequence::Grid.row_value(name, map), seed: seed)]
          })
        end
      end

      # Returns the default Sequence::Transport, which sets the tempo for
      # clips played in node graphs.
      def transport
        Sequence.transport
      end

      # Sets the default tempo in quarter notes per minute, or returns it if
      # +beats_per_minute+ is nil.  Clips that are already playing change
      # speed right away.
      def bpm(beats_per_minute = nil)
        Sequence.transport.bpm = beats_per_minute if beats_per_minute
        Sequence.transport.bpm
      end
    end
  end
end
