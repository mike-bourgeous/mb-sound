module MB
  module Sound
    module Sequence
      # Tempo for playing Clips in a node graph.  ClipNodes read the tempo on
      # every buffer, so changing #bpm while playing changes the speed of all
      # clips using this transport.
      #
      # Each ClipNode counts its own time from when it starts playing, so
      # nodes created from the same transport stay in sync as long as they
      # are part of the same graph.
      class Transport
        # Tempo in quarter notes per minute.
        attr_reader :bpm

        def initialize(bpm: 120)
          self.bpm = bpm
        end

        # Changes the tempo in quarter notes per minute.
        def bpm=(bpm)
          raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.finite? && bpm > 0
          @bpm = bpm
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

        def to_s
          "Transport(#{@bpm} BPM)"
        end
      end
    end
  end
end
