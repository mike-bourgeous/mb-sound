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
      # +flam+ is nil, true, or seconds: a flam mark (Seq::Step#flam; drum
      # kits play a grace stroke, then the hit that long later, true for
      # the kit's own spacing).
      Event = Struct.new(:start, :length, :value, :velocity, :probability, :accented, :slid, :condition, :fill_mark, :pitch, :flam, keyword_init: true) do
        # True if the event plays when the fills named +names+ (an Array,
        # empty outside fills) are playing (see +fill_mark+).
        def plays_in_fill?(names)
          return true if fill_mark.nil?
          mode, name = fill_mark
          active = name ? names.include?(name) : !names.empty?
          mode == :fill ? active : !active
        end

        # True for values Event#to_s prints as note names: Integers from
        # 12 (C0) to 127 (G9).  Lower ones are more often semitone or
        # degree offsets (a transpose clip) than notes below 16 Hz.
        def self.note_value?(v)
          v.is_a?(Integer) && v >= 12 && v <= 127
        end

        # The name of MIDI note +number+ (an Integer 0..127), e.g. "Fs2",
        # as MB::Sound::Note spells it (the constant you would type).
        def self.note_name(number)
          (@note_names ||= Array.new(128) { |n| MB::Sound::Note.new(n).name.freeze }.freeze)[number]
        end

        # The time at which the event ends, in whole notes.
        def end_time
          start + length
        end

        # Returns a copy of this event with the given attributes changed.
        def with(**changes)
          dup.tap { |e| changes.each { |k, v| e[k] = v } }
        end

        # The event as text, e.g. "C4@1/4+n8 v1.0 !": the value (a note
        # name for note numbers, see Event.note_value?), @ the start in
        # whole notes, + the length, then velocity and marks.  +names:+
        # nil decides per value; true or false names every Integer value
        # or none (Clip#to_s decides once per clip, so a clip of
        # semitone offsets like seq(0, 7, 12) prints numbers throughout).
        def to_s(names: nil)
          t = start.denominator == 1 ? start.numerator : start
          v = value
          text = if v.is_a?(MB::Sound::Pitch)
                   v.to_s
                 elsif v.is_a?(Numeric)
                   (names.nil? ? Event.note_value?(v) : names && v.is_a?(Integer) && v.between?(0, 127)) ? Event.note_name(v) : MB::M.sigfigs(v, 6)
                 else
                   v.inspect
                 end
          s = "#{text}@#{t}+#{Duration.format(length)}"
          s << " v#{MB::M.sigfigs(velocity, 3)}" if velocity != Clip::DEFAULT_VELOCITY
          s << " p#{probability}" if probability
          s << " #{condition[1]}:#{condition[0]}" if condition
          s << " #{fill_mark[0]}#{fill_mark[1] ? ":#{fill_mark[1]}" : ''}" if fill_mark
          s << ' !' if accented
          s << ' ~' if slid
          s << " pitch#{pitch >= 0 ? '+' : ''}#{MB::M.sigfigs(pitch, 4)}" if pitch
          s << (flam == true ? ' flam' : " flam#{MB::M.sigfigs(flam * 1000, 3)}ms") if flam
          s
        end

        def inspect
          "#<Event #{self}>"
        end
      end
    end
  end
end
