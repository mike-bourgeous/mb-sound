module MB
  module Sound
    module Sequence
      # A single note or hit within a Clip.
      #
      # +start+ and +length+ are Rational numbers of whole notes from the start
      # of the clip.  +value+ is usually a MIDI note number, but may be any
      # Numeric (e.g. a filter cutoff for a control sequence).  +velocity+
      # ranges from 0 to 1.  +probability+ is the chance from 0 to 1 that the
      # event plays in any given loop cycle (nil means always).
      Event = Struct.new(:start, :length, :value, :velocity, :probability, keyword_init: true) do
        # The time at which the event ends, in whole notes.
        def end_time
          start + length
        end

        # Returns a copy of this event with the given attributes changed.
        def with(**changes)
          dup.tap { |e| changes.each { |k, v| e[k] = v } }
        end

        def to_s
          t = start.denominator == 1 ? start.numerator : start
          s = "#{value.is_a?(Numeric) ? MB::M.sigfigs(value, 6) : value.inspect}@#{t}+#{Duration.format(length)}"
          s << " v#{MB::M.sigfigs(velocity, 3)}" if velocity != Clip::DEFAULT_VELOCITY
          s << " p#{probability}" if probability
          s
        end
      end
    end
  end
end
