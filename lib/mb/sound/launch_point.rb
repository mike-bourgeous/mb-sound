module MB
  module Sound
    # When a change to what plays lands on the timeline: the +at:+, +on:+,
    # and +in:+ keywords of #bg, #swap, #resume, #master, #mute and the
    # other mute/solo commands, #go, #undo, and their Session methods
    # (maintainer decision, 2026-10-10: alignment and placement get their
    # own words, and plain numbers are bars everywhere):
    #
    #     go :drop, on: :bar             # alignment: the next grid line
    #     go :drop, on: 4                # the next 4-bar line
    #     go :drop, in: 2.bars           # relative placement: two bars from now
    #     go :drop, at: bar(33)          # absolute placement: bar 33
    #     go :drop, in: 2.bars, on: :beat   # two bars from now, then the next beat
    #
    # - +on:+ aligns forward to a grid: :now, :beat (quarter notes), :bar,
    #   :clip (every looping clip of the graph back at its start), a number
    #   of bars (0 is :now), or a Duration or Length (e.g. 1.n4, 2.beats).
    # - +in:+ places the change that far from now (Session#now: a scheduled
    #   block's time inside one): a number of bars, or a Duration or Length.
    # - +at:+ places it at an absolute timeline position: bar(n) (see
    #   ScheduleMethods#bar; bars count from 1).  The launch-point Symbols
    #   are also accepted as aliases of +on:+ (`at: :bar` reads fine).  A
    #   plain number is an error (it used to mean a note grid in #bg and
    #   bars in the Set), with a message suggesting the new forms, and so
    #   are Durations and Lengths (`at: 32.bars` would be bar 33; write
    #   bar(33)).  A position that has already passed is an error too (in
    #   live mode it warns and lands now).
    #
    # The time starts from now, adds +in:+ (or jumps to +at:+), then aligns
    # forward to +on:+, or without +on:+ to the alignment the command would
    # have had anyway (maintainer, 2026-10-10: "Tracks should keep the same
    # time alignment they would have otherwise"): #bg, #swap, #resume, and
    # #master align to :now if nothing plays, else :bar; Set tracks to
    # their +q:+ (else the scene's, else the set's #quant); mutes and solos
    # don't align (right away, or exactly at +in:+/+at:+); #undo aligns to
    # :bar.  Errors go through MB::Sound.live_error, so a live set skips the
    # command with a warning.
    #
    # +in+ is a Ruby keyword, so methods that take +in:+ read it (with the
    # others) through LaunchPoint.of(binding).
    class LaunchPoint
      # Launch points for +on:+ (and +at:+ as aliases).
      ALIGNMENTS = [:now, :beat, :bar, :clip].freeze

      # An absolute timeline position given as a bar number (counting from
      # 1, like ScheduleMethods#at_bar) and a quarter-note beat within it
      # (counting from 1).  Made by ScheduleMethods#bar.
      Bar = Data.define(:bar, :beat) do
        def initialize(bar:, beat: 1)
          raise ArgumentError, "Bar must be a number of at least 1 (got #{bar.inspect})" unless bar.is_a?(Numeric) && bar >= 1
          raise ArgumentError, "Beat must be a number of at least 1 (got #{beat.inspect})" unless beat.is_a?(Numeric) && beat >= 1
          super
        end

        # The position in whole notes with +bar_length+ whole notes per
        # bar (the same arithmetic as ScheduleMethods#at_bar).
        def whole_notes(bar_length)
          return bar_length.bar_position(bar) + (beat.to_r - 1) / 4 if bar_length.is_a?(Sequence::Transport)
          (bar.to_r - 1) * bar_length + (beat.to_r - 1) / 4
        end

        def to_s
          beat == 1 ? "bar(#{bar})" : "bar(#{bar}, beat: #{beat})"
        end
        alias_method :inspect, :to_s
      end

      # Reads the +at+, +on+, and +in+ keyword parameters of the method
      # whose binding is +b+ (the one place that reads the +in+ keyword),
      # and returns a LaunchPoint, or nil if they are invalid in live mode
      # (see MB::Sound.live_error; the caller skips the command).  An +at+
      # that is already a LaunchPoint (passed along by a console method) is
      # returned as is.
      def self.of(b)
        build(at: b.local_variable_get(:at), on: b.local_variable_get(:on), offset: b.local_variable_get(:in))
      end

      # A LaunchPoint aligning to +q+ (a track's or scene's +q:+, or the
      # set's #quant): the same values as +on:+.
      def self.on(q)
        build(at: nil, on: q, offset: nil)
      end

      # Validates and builds a LaunchPoint (see .of).
      def self.build(at:, on:, offset:)
        if at.is_a?(LaunchPoint)
          return at if on.nil? && offset.nil?
          return error('Give on:/in: either to the LaunchPoint or the command, not both')
        end

        if at.is_a?(Symbol)
          return error("Unknown launch point #{at.inspect} (use #{ALIGNMENTS.map(&:inspect).join(', ')}, or a note length with on:)") unless ALIGNMENTS.include?(at)
          return error("at: #{at.inspect} is an alignment like on:; give one of them, not both") unless on.nil?
          on, at = at, nil
        end

        if at.is_a?(Numeric)
          return error(
            "A plain number in at: is ambiguous (at: #{at.inspect}); write on: 1.n4 (or another note length) " \
            "for a note grid, on: #{at.inspect} for the next #{at.inspect}-bar line, in: #{at.inspect} " \
            "for #{at.inspect} bars from now, or at: bar(#{at.inspect}) for bar #{at.inspect}"
          )
        end

        if at.is_a?(Length)
          return error("at: takes bar positions, not lengths (at: #{at.inspect}); write at: bar(n) or bar(n, beat: b) (bars count from 1), or in: #{at.inspect} for that long from now")
        end

        unless at.nil? || at.is_a?(Bar)
          return error("at: must be bar(n) (or bar(n, beat: b)) or one of #{ALIGNMENTS.map(&:inspect).join(', ')} (got #{at.inspect})")
        end

        return error('Give at: (an absolute position) or in: (an offset from now), not both') if at && offset

        unless offset.nil? || (length_like?(offset) && !Length.negative?(offset)) || (offset.is_a?(Numeric) && offset >= 0)
          hint = offset.is_a?(Bar) ? ' (bar(n) is a position; use at:)' : ''
          return error("in: must be a number of bars (at least 0), a Duration, or a Length (got #{offset.inspect})#{hint}")
        end

        on = :now if on.is_a?(Numeric) && on == 0
        if on.is_a?(Symbol)
          return error("Unknown launch point #{on.inspect} (use #{ALIGNMENTS.map(&:inspect).join(', ')}, a number of bars, or a note length)") unless ALIGNMENTS.include?(on)
        elsif !(on.nil? || (length_like?(on) && !Length.negative?(on)) || (on.is_a?(Numeric) && on > 0))
          return error("on: must be #{ALIGNMENTS.map(&:inspect).join(', ')}, a number of bars, or a Duration or Length (got #{on.inspect})")
        end

        new(at: at, on: on, offset: offset)
      end

      # True for Durations and Lengths.
      def self.length_like?(value)
        value.is_a?(Length)
      end

      # Sends an ArgumentError through MB::Sound.live_error (returns nil in
      # live mode).
      def self.error(message)
        MB::Sound.live_error(ArgumentError.new(message))
      end
      private_class_method :error, :length_like?

      # The absolute position (a Bar from bar(n)), or nil.
      attr_reader :at

      # The alignment (a Symbol, a number of bars, or a Duration or
      # Length), or nil.
      attr_reader :on

      # The +in:+ offset from now (a number of bars, or a Duration or
      # Length), or nil.
      attr_reader :offset

      def initialize(at: nil, on: nil, offset: nil)
        @at = at
        @on = on
        @offset = offset
        freeze
      end

      # True if any of +at:+, +on:+, +in:+ was given.
      def given?
        !(@at.nil? && @on.nil? && @offset.nil?)
      end

      # Resolves to an exact timeline position in whole notes, counting
      # from +now+ with +transport+'s bar length and tempo.  Without +on:+,
      # aligns to +default+ (an +on:+ value: the command's own alignment),
      # or not at all if +default+ is nil; with nothing given and no
      # +default+, returns nil (the caller's "right away").  +clip_grid+ is
      # called for :clip (it returns the grid in whole notes).
      #
      # An absolute +at:+ that has already passed goes through
      # MB::Sound.live_error (landing now in live mode), unless +replay+ is
      # true (a take replaying a line that landed late live: it lands now,
      # where the take forces it anyway).
      def resolve(now:, transport:, default: nil, clip_grid: nil, replay: false)
        return nil if !given? && default.nil?
        on = @on.nil? ? default : @on
        on = :now if on.is_a?(Numeric) && on == 0

        time = now.to_r

        if @at
          time = @at.whole_notes(transport)
          if time < now
            MB::Sound.live_error(ArgumentError.new("at: #{@at.inspect} has already passed (the timeline is at #{Session::Stamp.at(now.to_r, transport)}); landing now in live mode")) unless replay
            time = now.to_r
          end
        elsif @offset
          time += @offset.is_a?(Numeric) ? transport.bars_length(time, Sequence::Duration.rational(@offset)) : whole_notes(@offset, transport)
        end

        grid = case on
               when nil, :now then return time
               when :beat then 1/4r
               when :bar then return transport.next_bar_line(time)
               when :clip then clip_grid ? clip_grid.call.to_r : (return transport.next_bar_line(time))
               when Numeric then return transport.next_bar_line(time, Sequence::Duration.rational(on))
               else whole_notes(on, transport)
               end

        (time / grid).ceil * grid
      end

      def to_s
        parts = []
        parts << "at: #{@at.inspect}" if @at
        parts << "in: #{@offset.inspect}" if @offset
        parts << "on: #{@on.inspect}" if @on
        parts.empty? ? 'default' : parts.join(', ')
      end

      def inspect
        "#<#{self.class.name} #{self}>"
      end

      private

      # Whole notes in a Duration, or a Length at +transport+'s tempo.
      def whole_notes(value, transport)
        return value.whole_notes if value.is_a?(Sequence::Duration)
        value.to_whole_notes(transport: transport)
      end

      public

      # No launch point: each command's default.
      NONE = new
    end
  end
end
