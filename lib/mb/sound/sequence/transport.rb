module MB
  module Sound
    module Sequence
      # Tempo and timeline for playing Clips in node graphs.
      #
      # Clip sources read the tempo on every buffer, so changing #bpm while
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

        # A meter change in the meter map (see #meter): from timeline
        # position +pos+ (whole notes), bars are +bar_length+ whole notes,
        # and the bar starting at +pos+ is bar number +bar+ (counting from
        # 1).
        Meter = Data.define(:pos, :bar_length, :bar) do
          def to_s
            "bar #{bar}: #{Transport.meter_label(bar_length)}"
          end
        end

        # A time signature label for a bar length in whole notes (3/4r ->
        # "3/4", 7/8r -> "7/8", 1 -> "4/4").
        def self.meter_label(bar_length)
          bar_length = bar_length.to_r
          return "#{(bar_length * 4).to_i}/4" if (bar_length * 4).denominator == 1
          "#{bar_length.numerator}/#{bar_length.denominator}"
        end

        # Incremented by #seek, so a Session can tell when the timeline
        # jumped.
        attr_reader :generation

        # The fills on this timeline (see FillMap), set by a playing Form
        # and read by clips with fill marks.
        attr_reader :fills

        def initialize(bpm: 120, bar_length: 1)
          @position = 0r
          @generation = 0
          @fills = FillMap.new
          self.bpm = bpm
          self.bar_length = bar_length
        end

        # The length of a bar in whole notes (1 for 4/4, 3/4r for 3/4) at
        # the current position (see #meter for meter changes), or at
        # timeline position +pos+ if given.
        def bar_length(pos = nil)
          meter_at(pos || @position).bar_length
        end

        # The meter map: Meter entries, earliest first (frozen).  Bar
        # numbers count through it, so a meter change doesn't renumber the
        # bars before it.
        def meters
          @meters
        end

        # Changes the meter from the bar line at timeline position +at+
        # (whole notes; the next bar line at or after the current position
        # by default) to bars of +bar_length+ whole notes (e.g. 7/8r), keeping
        # every bar number before it.  Meter changes after +at+ are
        # forgotten.  Returns the new Meter.
        def meter(bar_length, at: nil)
          bar_length = check_bar_length(bar_length)
          at = at.nil? ? next_bar_line(@position) : at.to_r
          b = bar_at(at)
          raise ArgumentError, "Meter changes go on bar lines (#{at} is bar #{b.to_f.round(3)})" unless b.denominator == 1
          entry = Meter.new(pos: at, bar_length: bar_length, bar: b.to_i)
          kept = @meters.reject { |m| m.pos >= at }
          @meters = (kept + [entry]).freeze
          entry
        end

        # The Meter in effect at timeline position +pos+.
        def meter_at(pos)
          pos = pos.to_r
          @meters.reverse_each.find { |m| m.pos <= pos } || @meters.first
        end

        # The bar position of timeline position +pos+, counting from 1 (a
        # Rational: 9 is the start of bar 9, 9.5 halfway through it), through
        # the meter map.  Positions before 0 count back in the first meter.
        def bar_at(pos)
          m = meter_at(pos)
          m.bar + (pos.to_r - m.pos) / m.bar_length
        end

        # The timeline position (whole notes) of bar position +bar+
        # (counting from 1; fractions are parts of that bar), through the
        # meter map.
        def bar_position(bar)
          bar = bar.to_r
          m = @meters.reverse_each.find { |e| e.bar <= bar } || @meters.first
          m.pos + (bar - m.bar) * m.bar_length
        end

        # The first bar line at or after timeline position +pos+ whose bar
        # number is 1 more than a multiple of +every+ (so every: 4 gives
        # bars 1, 5, 9, ...).
        def next_bar_line(pos, every = 1)
          every = every.to_r
          b = bar_at(pos)
          n = ((b - 1) / every).ceil * every + 1
          n = n.ceil if n.denominator != 1 && every.denominator == 1
          bar_position(n)
        end

        # The length in whole notes of +bars+ bars (a number) starting at
        # timeline position +pos+, through the meter map.
        def bars_length(pos, bars)
          bar_position(bar_at(pos) + bars.to_r) - pos.to_r
        end


        # Changes the tempo in quarter notes per minute.
        def bpm=(bpm)
          raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.finite? && bpm > 0
          @bpm = bpm
        end

        # Plays songs at +bpm+ instead of their own tempo (for a script's
        # --bpm option): sets the tempo now, and #scaled_bpm turns the first
        # tempo a song asks for into +bpm+ and scales later ones by the same
        # ratio, so tempo changes keep their proportions.
        def override_bpm(bpm)
          self.bpm = bpm
          @bpm_override = bpm
          @bpm_scale = nil
        end

        # Returns +bpm+ adjusted for #override_bpm (unchanged without an
        # override).  Used by SequenceMethods#bpm.
        def scaled_bpm(bpm)
          return bpm unless @bpm_override

          @bpm_scale ||= @bpm_override.to_f / bpm
          bpm * @bpm_scale
        end

        # Changes the bar length in whole notes (e.g. 3/4r for 3/4 time).
        #
        # This sets one meter for the whole timeline (the meter map has only
        # this entry afterwards); use #meter to change meter partway through
        # a song without renumbering the bars before the change.
        def bar_length=(length)
          @meters = [Meter.new(pos: 0r, bar_length: check_bar_length(length), bar: 1)].freeze
        end

        # Validates a bar length, returning it as a Rational.
        def check_bar_length(length)
          raise ArgumentError, "Bar length must be a positive number of whole notes (got #{length.inspect})" unless length.is_a?(Numeric) && length.to_r > 0
          length.to_r
        end
        private :check_bar_length

        # The number of whole notes that play per second at the current tempo,
        # as an exact Rational.
        def whole_notes_per_second
          # Cached (Rationals are immutable) so readers every buffer don't
          # allocate; any change to @bpm is seen
          unless @wnps && @wnps_bpm.eql?(@bpm)
            @wnps_bpm = @bpm
            @wnps = @bpm.to_r / 240
          end
          @wnps
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

        # The current bar number, counting from 1 (through the meter map).
        def bar
          bar_at(@position).floor
        end

        # The current quarter-note beat within the bar, counting from 1.
        def beat
          ((@position - bar_position(bar)) * 4).floor + 1
        end

        def to_s
          "Transport(#{@bpm} BPM, bar #{bar} beat #{beat})"
        end
      end
    end
  end
end
