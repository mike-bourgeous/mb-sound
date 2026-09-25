module MB
  module Sound
    module Sequence
      # Tempo and timeline for playing Clips in node graphs.
      #
      # ClipNodes read the tempo on every buffer, so changing #bpm while
      # playing changes the speed of all clips using this transport.
      #
      # The #position is a musical timeline in whole notes, advanced by a
      # Session while anything plays in the background (see
      # PlaybackMethods#bg).  Looping clips in a session play in phase with
      # this timeline, so clips started at different times stay in sync.
      # Graphs played with #play instead count their own time from zero.
      class Transport
        # Tempo in quarter notes per minute.
        attr_reader :bpm

        # The current timeline position in whole notes (a Rational).
        attr_reader :position

        # The length of a bar in whole notes (1 for 4/4, 3/4r for 3/4).
        attr_reader :bar_length

        # Incremented by #seek, so a Session can tell when the timeline
        # jumped.
        attr_reader :generation

        def initialize(bpm: 120, bar_length: 1)
          self.bpm = bpm
          self.bar_length = bar_length
          @position = 0r
          @generation = 0
        end

        # Changes the tempo in quarter notes per minute.
        def bpm=(bpm)
          raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.finite? && bpm > 0
          @bpm = bpm
        end

        # Changes the bar length in whole notes (e.g. 3/4r for 3/4 time).
        def bar_length=(length)
          length = length.to_r
          raise ArgumentError, "Bar length must be positive (got #{length.inspect})" unless length > 0
          @bar_length = length
        end

        # The number of whole notes that play per second at the current tempo,
        # as an exact Rational.
        def whole_notes_per_second
          @bpm.to_r / 240
        end

        # Converts a number of whole notes to seconds at the current tempo.
        def seconds(whole_notes)
          whole_notes.to_f / whole_notes_per_second
        end

        # Moves the timeline forward by +whole_notes+.  Called by Session.
        def advance(whole_notes)
          @position += whole_notes
        end

        # Jumps the timeline to +whole_notes+ from the start.  Background
        # players jump with it on their next buffer.  See
        # SequenceMethods#seek for seeking by bar number.
        def seek(whole_notes)
          @position = whole_notes.to_r
          @generation += 1
          self
        end

        # Jumps the timeline back to the start.
        def rewind
          seek(0)
        end

        # Returns the first timeline position at or after the current position
        # that is a multiple of +grid+ whole notes.
        def next_boundary(grid)
          grid = grid.to_r
          (@position / grid).ceil * grid
        end

        # The current bar number, counting from 1.
        def bar
          (@position / @bar_length).floor + 1
        end

        # The current quarter-note beat within the bar, counting from 1.
        def beat
          ((@position % @bar_length) * 4).floor + 1
        end

        def to_s
          "Transport(#{@bpm} BPM, bar #{bar} beat #{beat})"
        end
      end
    end
  end
end
