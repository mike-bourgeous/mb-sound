module MB
  module Sound
    module Sequence
      # A musical length stored as an exact Rational number of whole notes
      # (e.g. 1/4r for a quarter note), usually created with the Numeric
      # methods in NumericDurations (e.g. `3.n16`, `2.bars`, `1.beat.dotted`).
      # Durations can be compared, added, and scaled, and are accepted
      # anywhere a musical length is (launch points, fades, sequence lengths,
      # scheduling).
      #
      # The class methods are helpers for methods that accept a duration as
      # an Integer note division (4 for a quarter note, 6 for a half note
      # triplet, 16 for a sixteenth note), a Rational/Float fraction of a
      # whole note (3/8r for a dotted quarter), or a Duration.
      #
      # Example (bin/sound.rb):
      #     3.n16                  # => 3 × n16
      #     1.n8.dotted == 3.n16   # => true
      #     2.bars + 1.beat        # => 9 × n4
      class Duration
        include Comparable

        # Note divisions that get predefined n* methods (e.g. Note#n4 or
        # Numeric#n4).  Any other division is available with #n(k).
        DIVISIONS = [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32, 64, 128].freeze

        # Long names for common note lengths, as note divisions.
        NAMES = {
          whole: 1,
          half: 2,
          quarter: 4,
          eighth: 8,
          sixteenth: 16,
          thirty_second: 32,
          sixty_fourth: 64,
        }.freeze

        # Multipliers for dotted, double-dotted, and triplet durations.
        DOTTED = 3/2r
        DOUBLE_DOTTED = 7/4r
        TRIPLET = 2/3r

        # The length of a step whose duration was never set.
        DEFAULT = 1/4r

        # Converts a duration argument to a Rational number of whole notes.
        # See the Duration class description.
        def self.whole_notes(duration)
          case duration
          when Duration
            duration.whole_notes

          when Integer
            raise ArgumentError, "Note division must be positive (got #{duration})" unless duration > 0
            Rational(1, duration)

          when Rational
            raise ArgumentError, "Duration must be positive (got #{duration})" unless duration > 0
            duration

          when Float
            raise ArgumentError, "Duration must be positive and finite (got #{duration})" unless duration.finite? && duration > 0
            rational(duration)

          else
            raise ArgumentError, "Duration must be a Duration (e.g. 3.n16 or 2.bars), an Integer note division, or a Rational/Float fraction of a whole note (got #{duration.inspect})"
          end
        end

        # Converts a number of bars, or a Duration, to a number of bars with
        # +bar_length+ whole notes per bar.  Other values (e.g. nil) are
        # returned unchanged.  Used by methods that count in bars, like fades
        # and ScheduleMethods#every.
        def self.bars(value, bar_length)
          value.is_a?(Duration) ? value.whole_notes / bar_length.to_r : value
        end

        # Converts a Numeric to an exact Rational, turning Floats into the
        # simplest Rational within one millionth (e.g. 0.85 becomes 17/20).
        # Used wherever Floats are accepted for musical amounts (durations,
        # legato fractions, fade lengths).
        def self.rational(value)
          value.is_a?(Float) ? value.rationalize(Rational(1, 1_000_000)) : value.to_r
        end

        # Formats a duration in whole notes for display, e.g. "n4" for 1/4r
        # or "3/8" for a dotted quarter.
        def self.format(whole_notes)
          if whole_notes.numerator == 1
            "n#{whole_notes.denominator}"
          else
            whole_notes.to_s
          end
        end

        # The length in whole notes (a Rational).
        attr_reader :whole_notes

        # Creates a Duration of +whole_notes+ (converted to a Rational; Floats
        # are rationalized as in .rational).  +:label+ is used by #to_s
        # instead of the default description (e.g. "2 bars").
        def initialize(whole_notes, label: nil)
          raise ArgumentError, "Duration must be a Numeric number of whole notes (got #{whole_notes.inspect})" unless whole_notes.is_a?(Numeric)
          @whole_notes = Duration.rational(whole_notes)
          raise ArgumentError, "Duration must not be negative (got #{whole_notes})" if @whole_notes < 0
          @label = label
        end

        # Returns this duration stretched by 3/2.  Also available as #d.
        def dotted
          modified(DOTTED, 'dotted')
        end
        alias d dotted

        # Returns this duration stretched by 7/4.  Also available as #dd.
        def double_dotted
          modified(DOUBLE_DOTTED, 'double dotted')
        end
        alias dd double_dotted

        # Returns this duration shrunk to 2/3 (a triplet).  Also available as
        # #t.
        def triplet
          modified(TRIPLET, 'triplet')
        end
        alias t triplet

        # Returns a Pitch (like Numeric#hz) that completes one cycle per this
        # duration, following the tempo of the Session playing it (or
        # Sequence.transport); oscillators made from it have their phases
        # locked to the timeline (see TempoNode).  Waveform methods like
        # #triangle and #ramp work as on any Pitch; see #lfo for modulation.
        #
        # Example (bin/sound.rb):
        #     bg 110.hz.ramp.at(1).fm(1.beat.hz.at(20))
        def hz
          Pitch.new(TempoNode.new(self, mode: :hz))
        end

        # Returns a tempo-synced LFO (see #hz and Tone#lfo) that completes one
        # cycle per this duration, locked to the timeline: a 4-bar LFO starts
        # each cycle every 4 bars from the start of the timeline.  It swings
        # over -1..1 unless #at is called, plays forever, and freezes while
        # the timeline is paused.  Call #freewheel to let it run free of the
        # timeline (it still follows the tempo).
        #
        # Example (bin/sound.rb):
        #     cutoff = 4.bars.lfo.triangle.at(200..2000)
        #     bg :pad, 110.hz.ramp.at(1).filter(:lowpass, cutoff: cutoff, quality: 4)
        def lfo
          hz.lfo
        end

        # Returns a delay Filter with this length as its delay time, following
        # the tempo, to apply with GraphNode#filter (e.g.
        # `sig.filter(3.n16.delay(feedback: -6.db, dry: 1))`).  Takes the
        # same options as GraphNode#delay, which is usually simpler:
        # `sig.delay(3.n16, feedback: -6.db, dry: 1)`.
        def delay(**options)
          GraphNode::DelayMethods.delay_filter(self, **options)
        end

        # Returns the length in seconds at the tempo of +transport+ right
        # now.  The result doesn't follow later tempo changes.
        def seconds(transport = Sequence.transport)
          transport.seconds(@whole_notes).to_f
        end

        def +(other)
          Duration.new(@whole_notes + other_whole_notes(other))
        end

        def -(other)
          Duration.new(@whole_notes - other_whole_notes(other))
        end

        # Scales the duration by a number (e.g. `3.n16 * 2`).
        def *(other)
          raise ArgumentError, "Durations can only be multiplied by numbers (got #{other.inspect})" unless other.is_a?(Numeric)
          Duration.new(@whole_notes * Duration.rational(other))
        end

        # Divides by a number, returning a Duration, or by another Duration,
        # returning their ratio as a Rational (e.g. `1.bar / 1.n16` is 16).
        def /(other)
          if other.is_a?(Duration)
            @whole_notes / other.whole_notes
          else
            Duration.new(@whole_notes / Duration.rational(other))
          end
        end

        # Allows e.g. `2 * 3.n16`.
        def coerce(other)
          raise TypeError, "#{other.class} can't be coerced into a Duration" unless other.is_a?(Numeric)
          [Scalar.new(other), self]
        end

        # Compares durations by length.  Numbers are compared as whole notes.
        def <=>(other)
          case other
          when Duration then @whole_notes <=> other.whole_notes
          when Numeric then @whole_notes <=> other
          end
        end

        def hash
          @whole_notes.hash
        end

        def eql?(other)
          other.is_a?(Duration) && other.whole_notes == @whole_notes
        end

        # The length in whole notes.
        def to_r
          @whole_notes
        end

        # The length in whole notes, as a Float.
        def to_f
          @whole_notes.to_f
        end

        # A friendly description like "3 × n16", "2 bars", or "dotted n8".
        def to_s
          @label || default_label
        end

        def inspect
          "#<Duration #{self} (#{@whole_notes} whole notes)>"
        end

        # A number on the left of Duration arithmetic (see #coerce).
        Scalar = Struct.new(:value) do
          def *(duration)
            duration * value
          end

          def +(duration)
            raise TypeError, "Can't add a number to a Duration; use a Duration (e.g. 1.n4)"
          end
          alias_method :-, :+

          def /(duration)
            raise TypeError, "Can't divide a number by a Duration"
          end
        end

        private

        def modified(factor, name)
          Duration.new(@whole_notes * factor, label: "#{name} #{self}")
        end

        def other_whole_notes(other)
          raise ArgumentError, "Can only add or subtract Durations (got #{other.inspect}; use e.g. 1.n4)" unless other.is_a?(Duration)
          other.whole_notes
        end

        def default_label
          return '0' if @whole_notes == 0
          num = @whole_notes.numerator
          den = @whole_notes.denominator
          num == 1 ? "n#{den}" : "#{num} × n#{den}"
        end
      end
    end
  end
end
