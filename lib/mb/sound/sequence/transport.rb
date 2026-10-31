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

        # A key change in the key map (see #key_at): from timeline position
        # +pos+ (whole notes) the session key is +key+ (a MusicalKey).
        KeyEntry = Data.define(:pos, :key)

        def initialize(bpm: 120, bar_length: 1)
          @position = 0r
          @generation = 0
          @fills = FillMap.new
          @keys = [KeyEntry.new(pos: -Float::INFINITY, key: MusicalKey.default)].freeze
          @tempo_map = nil
          @tempo_quiet = nil # (the seek generation the map went quiet in; see #settle_tempo)
          @wnps = @wnps_bpm = @per_frame_cache = nil # (see #whole_notes_per_second, #whole_notes_per_frame)
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
          @meters[meter_index(pos.to_r)]
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


        # Sets the tempo in quarter notes per minute (a number or a Tempo)
        # everywhere: the tempo map becomes this one constant tempo (for a
        # fresh timeline: a new transport, a take replay's start, a
        # script's --bpm; songs and the console change the tempo through
        # SequenceMethods#bpm, a journaled change that lands where the
        # timeline is).
        def bpm=(bpm)
          bpm = bpm.bpm if bpm.is_a?(MB::Sound::Tempo)
          raise ArgumentError, "BPM must be a positive number (got #{bpm.inspect})" unless bpm.is_a?(Numeric) && bpm.finite? && bpm > 0
          @bpm = bpm
          @tempo_map = nil # (built on first use: most transports never ramp)
        end

        # The tempo map (Sequence::TempoMap): the tempo as a function of
        # timeline position, the history of the changes made so far
        # included (seeks read it at their target; see #seek).  A constant
        # tempo is a map of one step.
        def tempo_map
          @tempo_map ||= TempoMap.constant(@bpm)
        end

        # Replaces the tempo map with +map+ (a TempoMap, e.g. from a MIDI
        # file's tempo events: TempoMap.steps(pairs), or a take's start
        # state).  Sets the tempo to the map's tempo at the current
        # position.
        def tempo_map=(map)
          raise ArgumentError, "Expected a Sequence::TempoMap (got #{map.inspect})" unless map.is_a?(TempoMap)
          @tempo_map = map.static? ? nil : map
          @tempo_quiet = nil
          bpm = map.bpm_at(@position)
          @bpm = bpm.is_a?(Rational) && bpm.denominator == 1 ? bpm.to_i : bpm
        end

        # Changes the map from timeline position +at+ (whole notes; the
        # current position by default) to +segment+ (see TempoMap#with):
        # what the Session's journaled :tempo changes call.  Returns the
        # new map.
        def tempo_change(at: nil)
          at = at.nil? ? @position : at.to_r
          map = yield(tempo_map, at)
          @tempo_map = map.static? ? nil : map
          @tempo_quiet = nil
          set_cell_bpm(map.bpm_at(@position)) unless map.varying_at?(@position)
          map
        end

        # True unless the tempo stays one constant from here on (the
        # Session then splits spans into tempo cells; see TempoMap).
        def tempo_moves?
          map = @tempo_map
          return false if map.nil? || map.static?
          @tempo_quiet != @generation
        end

        # Marks a tempo map that no longer moves from the current position
        # on (a ramp finished, nothing after it) for the constant-tempo
        # path, until the map changes or the timeline jumps (the map stays:
        # seeks back read it).  Called by Session between spans.
        def settle_tempo
          return unless tempo_moves?
          @tempo_quiet = @generation if @tempo_map.quiet_after?(@position)
        end

        # Sets the tempo of the span about to render (a Rational BPM from
        # the tempo map) without changing the map.  Called by Session.
        def set_cell_bpm(bpm)
          bpm = bpm.to_i if bpm.is_a?(Rational) && bpm.denominator == 1
          @bpm = bpm unless @bpm == bpm && @bpm.class == bpm.class
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
            @wnps = TempoMap.whole_notes_per_second(@bpm)
          end
          @wnps
        end

        # Converts a number of whole notes to Float seconds at the current
        # tempo.
        def seconds(whole_notes)
          whole_notes.to_f / whole_notes_per_second
        end

        # The time math at the current (cell) tempo, for everything outside
        # Transport and TempoMap (design/notes/tempo_sync.md, "Time math").
        # Each keeps its arguments' types: exact for Rationals, and for
        # Floats the same operations in the same order as the inline copies
        # they replaced, so results are bit for bit the same.

        # Seconds that +whole_notes+ last at the current tempo (exact for a
        # Rational; see #seconds for Float seconds of any number).
        def seconds_of(whole_notes)
          whole_notes / whole_notes_per_second
        end

        # Whole notes that pass in +seconds+ at the current tempo.
        def whole_notes_of(seconds)
          seconds * whole_notes_per_second
        end

        # Frames at +rate+ (samples per second) that +whole_notes+ last at
        # the current tempo (unrounded; pass a Rational rate for an exact
        # result).
        def frames_of(whole_notes, rate)
          whole_notes / whole_notes_per_second * rate
        end

        # Whole notes per frame at +rate+ at the current tempo (exact; kept
        # until the tempo or the rate changes, so readers every buffer don't
        # allocate).
        def whole_notes_per_frame(rate)
          wnps = whole_notes_per_second
          c = @per_frame_cache
          return c[2] if c && c[0].equal?(wnps) && c[1] == rate
          (@per_frame_cache = [wnps, rate, wnps / rate.to_r].freeze)[2]
        end

        # The timeline position +offset+ frames after +from+, at
        # +per_frame+ whole notes per frame (see #whole_notes_per_frame):
        # within one span of constant tempo, as Session renders.
        def self.position_at(from, offset, per_frame)
          from + offset * per_frame
        end

        # The frame offset after +from+ (floored) holding position +pos+, at
        # +per_frame+ whole notes per frame: the inverse of .position_at
        # (an edge on an exact frame lands on that frame).
        def self.frame_at(pos, from, per_frame)
          ((pos - from) / per_frame).floor
        end

        # Moves the timeline forward by +whole_notes+.  Called by Session.
        def advance(whole_notes)
          @position += whole_notes
        end

        # Moves the timeline forward by +whole_notes+, the span from +from+
        # to +to+ that Session rendered: to +to+ itself while the position
        # is still +from+ (the same value as #advance, without adding).
        def advance_span(from, to, whole_notes)
          @position = @position.equal?(from) ? to : @position + whole_notes
        end

        # The index in @meters of the Meter in effect at +pos+ (a Rational).
        def meter_index(pos)
          i = @meters.length - 1
          i -= 1 while i > 0 && @meters[i].pos > pos
          i
        end
        private :meter_index

        # Jumps the timeline to +whole_notes+ from the start.  Background
        # players jump with it on their next buffer.  See
        # SequenceMethods#seek for seeking by bar number.
        #
        # The key in effect stays: the key map collapses to it (a key set
        # live isn't undone by jumping back before it; sections that set a
        # key set it again as they play).
        #
        # The tempo map is read at the new position (tempo-2, maintainer
        # 2026-10-30: "the tempo at a seek target is what the ramp reaches
        # there, so seeks and takes agree"): a seek into a ramp plays the
        # ramp on from there, a seek back before a tempo change plays the
        # tempo before it, and the change again where it happened.  A
        # followed source in effect there is read on the next tempo cell.
        def seek(whole_notes)
          current = key_at(@position)
          @keys = [KeyEntry.new(pos: -Float::INFINITY, key: current)].freeze unless @keys.length == 1 && @keys[0].key == current
          pos = whole_notes.to_r
          map = @tempo_map
          if map && !map.static?
            seg = map.segment_at(pos)
            set_cell_bpm(seg.bpm_at(pos)) unless seg.is_a?(TempoMap::Follow)
          end
          @position = pos
          @generation += 1
          self
        end

        # Moves the timeline back to the start as a reset (SequenceMethods#
        # rewind; not a journaled seek): the tempo in effect stays, the
        # map's history is dropped (a ramp in progress stops where it is; a
        # followed source stays followed), so `bpm 140; rewind` plays at
        # 140 from the start.
        def rewind
          map = @tempo_map
          if map && !map.static?
            seg = map.segment_at(@position)
            @tempo_map = seg.is_a?(TempoMap::Follow) ? TempoMap.new([seg.with(pos: -Float::INFINITY)]) : nil
            @tempo_quiet = nil
          end
          seek(0)
        end

        # The session key (a MusicalKey) at the current position, or at
        # timeline position +pos+.
        def key(pos = nil)
          key_at(pos || @position)
        end

        # The key in effect at timeline position +pos+ (whole notes),
        # through the key map (see #key_change).
        def key_at(pos)
          list = @keys
          return list[0].key if list.length == 1
          pos = pos.to_r
          (list.reverse_each.find { |e| e.pos <= pos } || list.first).key
        end

        # The key map: KeyEntry rows, earliest first (frozen).
        def keys
          @keys
        end

        # Changes the key to +key+ (a MusicalKey) from timeline position +at+
        # (now by default), forgetting key changes at or after it (like
        # #meter).  The Session's `key`/`mode` commands call this when their
        # journaled change lands.  Returns the KeyEntry.
        def key_change(key, at: nil)
          raise ArgumentError, "Expected a MusicalKey (got #{key.inspect})" unless key.is_a?(MusicalKey)
          at = at.nil? ? @position : at.to_r
          entry = KeyEntry.new(pos: at, key: key)
          @keys = (@keys.reject { |e| e.pos >= at } + [entry]).freeze
          entry
        end

        # Sets the key everywhere (the key map holds only +key+): for a
        # fresh timeline (spec setup, a take replay's start).
        def reset_key(key = MusicalKey.default)
          @keys = [KeyEntry.new(pos: -Float::INFINITY, key: key)].freeze
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
