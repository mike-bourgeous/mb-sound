module MB
  module Sound
    module Sequence
      # A single note or hit within a Clip.
      #
      # +start+ and +length+ are Rational numbers of whole notes from the start
      # of the clip.  +value+ is usually a MIDI note number, but may be any
      # Numeric (e.g. a filter cutoff for a control sequence).  +velocity+
      # ranges from 0 to 1.  +probability+ is the chance from 0 to 1 that the
      # event plays in any given loop cycle (nil means always).  +accented+
      # and +slid+ are true for notes marked as accented or slid in a Seq (see
      # Seq::Step#accent and #slide): a slid note overlaps the next one, and
      # Clip#legato leaves it alone.  +condition+ is nil (every cycle) or
      # [n, from]: the event plays every +n+th loop cycle starting with
      # cycle +from+ (counting from 1; Elektron's "from:n" trig condition;
      # see Seq::Step#every and Clip#every).  +fill_mark+ is nil (plays in and
      # out of fills) or [mode, name]: mode :fill plays only during fills
      # (only fill +name+ if given), :nofill only outside them (outside fill
      # +name+ if given); fills come from a playing song form (see
      # Seq::Step#fill, Clip#fill, and FillMap).  +pitch+ is nil or a pitch
      # mark in semitones (Seq::Step#pitch; samplers play the note's slice
      # that much higher; Clip#transpose moves it instead of +value+).
      Event = Struct.new(:start, :length, :value, :velocity, :probability, :accented, :slid, :condition, :fill_mark, :pitch, keyword_init: true) do
        # True if the event plays when the fills named +names+ (an Array,
        # empty outside fills) are playing (see +fill_mark+).
        def plays_in_fill?(names)
          return true if fill_mark.nil?
          mode, name = fill_mark
          active = name ? names.include?(name) : !names.empty?
          mode == :fill ? active : !active
        end

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
          s = "#{value.is_a?(Numeric) ? MB::M.sigfigs(value, 6) : (value.is_a?(MB::Sound::Pitch) ? value.to_s : value.inspect)}@#{t}+#{Duration.format(length)}"
          s << " v#{MB::M.sigfigs(velocity, 3)}" if velocity != Clip::DEFAULT_VELOCITY
          s << " p#{probability}" if probability
          s << " #{condition[1]}:#{condition[0]}" if condition
          s << " #{fill_mark[0]}#{fill_mark[1] ? ":#{fill_mark[1]}" : ''}" if fill_mark
          s << ' !' if accented
          s << ' ~' if slid
          s << " pitch#{pitch >= 0 ? '+' : ''}#{MB::M.sigfigs(pitch, 4)}" if pitch
          s
        end
      end
    end
  end
end
