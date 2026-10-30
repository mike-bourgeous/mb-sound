module MB
  module Sound
    # A timebase for clips and audio loops other than the session's bars
    # (design/notes/arrangement.md, "Clocks"; time-automation, 2026-10-18):
    #
    # - a Tempo (`138.75.bpm`): the clip plays at its own tempo, whatever
    #   the session's (Nev's record pressed at 138.75 inside a 165 set);
    # - a Rational (`5/4r`): a ratio of the session tempo, following its
    #   tempo changes (5/4 plays five bars in the time of four);
    # - a length in seconds (`19.7.seconds`): a loop period, the clip's whole
    #   loop (or the audio loop) spanning exactly that long (Kaede's bowls).
    #
    # Named clocks (`clock :tide, 31.1.seconds`) live in the Session's
    # namespace and may take a +speed:+ (a number, a knob name, a Knob, or
    # a MIDI::Param such as `cc(1, 0.5..2)`), read once per CELL frames, so
    # positions are the same at any buffer size.  Anonymous clocks (made by
    # Clip#clocked from a value) run at speed 1.
    #
    # A clock's position counts from session time, not the bar grid: the
    # Session's run frames (frames rendered while its timeline moves; seeks
    # don't reset them, and they pause with the timeline), so a clip
    # dropped by a scene comes back where it would have been, a seek leaves
    # it alone, and a take replay computes the same positions.  Tempo and
    # ratio clocks count whole notes; period clocks count cycles (one
    # cycle is one period).  Positions are exact Rationals; within each
    # CELL the position is linear (CELL boundaries and tempo changes are
    # the only breakpoints), so per-sample positions counted from a cell
    # start are the same floats at any buffer size.
    class Clock
      # What clocks count in: :tempo and :ratio clocks whole notes,
      # :period clocks cycles.
      KINDS = [:tempo, :ratio, :period].freeze

      # Frames per cell: speed is read at each cell's first frame.
      CELL = 800

      # The clock's name (a Symbol) for Session clocks, else nil.
      attr_reader :name

      # :tempo, :ratio, or :period.
      attr_reader :kind

      # The Tempo, Rational, or Length::Seconds it was made from.
      attr_reader :base

      # The speed (1 by default): a number, a knob name, a Knob, or a
      # MIDI::Param.
      attr_reader :speed

      # The Session this clock belongs to (named clocks), else nil.
      attr_reader :session

      # Makes a clock from +base+ (a Tempo, a Rational ratio, or a length
      # in seconds; see ArgTypes).  +name+ and +session+ are for Session
      # clocks (Session::Clocks#define_clock).
      def initialize(base, name: nil, speed: 1, session: nil)
        @name = name
        @session = session
        set_base(base)
        @speed = Clock.check_speed(speed)
        @speed_r = @speed.is_a?(Numeric) ? MB::Sound::Tempo.exact(@speed) : nil
        @cells = []      # variable speed: [run frame, position, step] breakpoints
        @cell_lock = Mutex.new
      end

      # A Clock for +value+: a Clock is itself, a Symbol stays a Symbol
      # (a named clock, looked up where the clip plays), a Tempo, Rational,
      # or seconds Length makes an anonymous clock; anything else raises
      # with the kinds of clocks there are.
      def self.coerce(value)
        case value
        when Clock, Symbol then value
        when MB::Sound::Tempo, Rational then new(value)
        when MB::Sound::Length::Seconds
          raise ArgumentError, "A clock period is a number of seconds (got #{value})" unless value.fixed?
          new(value)
        else
          raise ArgumentError, "A clock is a tempo (138.75.bpm), a ratio of the session tempo (5/4r), a loop period (19.7.seconds), or a clock's name (:tide) (got #{ArgTypes.describe_value(value)})"
        end
      end

      # The Clock for +ref+ (a Clock, or a clock's name) where +ctx+ plays
      # it: a Session's clock of that name, else one the console's Session
      # (Session.existing) has, defined in +ctx+ with the same settings
      # (a render Session playing a clip on a clock defined at the prompt;
      # like knobs joining the Session that plays them).  Outside a
      # Session (+ctx+ a Clock::Free), the console Session's clock.
      def self.resolve(ref, ctx)
        return ref if ref.is_a?(Clock)
        own = ctx.is_a?(Session) ? ctx.clock_named(ref) : nil
        return own if own
        other = Session.existing
        other = nil if other.equal?(ctx)
        found = other&.clock_named(ref)
        unless found
          raise ArgumentError, "No clock #{ref.inspect} where this plays; define it with `clock #{ref.inspect}, 19.7.seconds` (or 138.75.bpm, or 5/4r)" unless ctx.is_a?(Session)
          return ctx.clock!(ref) # (raises with suggestions)
        end
        return found unless ctx.is_a?(Session)
        speed = found.speed
        speed = 1 if speed.is_a?(Symbol) && !ctx.knobs.key?(speed) && warn("clock #{ref.inspect} plays at speed 1 here (its speed knob #{speed.inspect} isn't in this Session)").nil?
        ctx.define_clock(ref, found.base, speed: speed)
      end

      # Checks a speed: a non-negative number, a knob name, a Knob or
      # reader, or a MIDI::Param.
      def self.check_speed(speed)
        case speed
        when Numeric
          raise ArgumentError, "A clock speed is a number from 0 up (got #{speed.inspect})" unless speed.real? && speed.finite? && speed >= 0
          speed
        when Symbol, GraphNode::Knob, GraphNode::Knob::Reader then speed
        when GraphNode
          # (a tempo LFO, `4.bars.lfo.at(0.5..2)`, read per 800-frame cell
          # like any param; Hz LFOs raise naming the tempo LFO; omnibus15)
          MIDI::Param.wrap(speed, 'A clock speed')
        else
          return speed if speed.respond_to?(:value_at)
          raise ArgumentError, "A clock speed is a number, a knob name, knob(:x), or a param like cc(1, 0.5..2) (got #{speed.inspect})"
        end
      end

      # True if the speed changes while playing (a knob or a param).
      def variable?
        !@speed.is_a?(Numeric)
      end

      # The unit of #position: :whole_notes or :cycles.
      def unit
        @kind == :period ? :cycles : :whole_notes
      end

      # The exact number the clock is made from (BPM, ratio, or seconds).
      def base_exact
        @exact
      end

      # The ratio for :ratio clocks.
      def ratio
        @kind == :ratio ? @exact : nil
      end

      # The tempo (exact BPM, a Rational) for :tempo clocks.
      def bpm
        @kind == :tempo ? @exact : nil
      end

      # The period in seconds (exact Rational) for :period clocks.
      def period
        @kind == :period ? @exact : nil
      end

      # Changes what the clock is made from and its speed (Session
      # clocks defined again; positions after it follow the new settings).
      def respec(base: nil, speed: nil)
        @cell_lock.synchronize {
          set_base(base) if base
          unless speed.nil?
            @speed = Clock.check_speed(speed)
            @speed_r = @speed.is_a?(Numeric) ? MB::Sound::Tempo.exact(@speed) : nil
          end
          @cells = [] # (re-integrated from the next span)
        }
        self
      end

      # The step per frame at speed 1, at run frame +rf+ (exact Rational):
      # whole notes per frame (tempo, ratio of the session's) or cycles per
      # frame (period).
      def base_step(rf, ctx)
        case @kind
        when :tempo then @exact / 240 / ctx.clock_rate
        when :period then 1 / (@exact * ctx.clock_rate)
        else @exact * ctx.per_sample_at(rf)
        end
      end

      # The position (exact Rational, see #unit) at run frame +rf+ of the
      # context +ctx+ (a Session, or Clock::Free outside one).
      def position(rf, ctx)
        rf = rf.to_r
        bp = breakpoint(rf, ctx)
        bp[1] + (rf - bp[0]) * bp[2]
      end

      # The step per frame (exact) at run frame +rf+.
      def step(rf, ctx)
        breakpoint(rf.to_r, ctx)[2]
      end

      # The linear pieces of [+rf_a+, +rf_b+): [[from, to, position at
      # from, step], ...] (run frames; positions exact), split at cells and
      # tempo changes.
      def pieces(rf_a, rf_b, ctx)
        rf_a = rf_a.to_r
        rf_b = rf_b.to_r
        out = []
        a = rf_a
        while a < rf_b
          bp = breakpoint(a, ctx)
          nxt = next_break(a, ctx)
          b = nxt < rf_b ? nxt : rf_b
          out << [a, b, bp[1] + (a - bp[0]) * bp[2], bp[2]]
          a = b
        end
        out
      end

      # The breakpoint [run frame, position, step] in effect at +rf+: the
      # start of its cell, or a later tempo change inside the cell.
      def breakpoint(rf, ctx)
        cell = (rf / CELL).floor * CELL
        if variable?
          integrated(rf, cell, ctx)
        elsif @kind == :ratio
          t = ctx.tempo_point(rf)
          start = t[0] > cell ? t[0] : cell
          [start, @exact * ctx.odometer_at(start) * @speed_r, @exact * t[2] * @speed_r]
        else
          s = base_step(rf, ctx) * @speed_r
          [cell, cell * s, s]
        end
      end

      # The next breakpoint after +rf+: the next cell, or a tempo change
      # before it (ratio clocks).
      def next_break(rf, ctx)
        nxt = ((rf / CELL).floor + 1) * CELL
        if @kind == :ratio
          t = ctx.next_tempo_point(rf)
          nxt = t if t && t < nxt
        end
        nxt
      end

      # The speed at run frame +rf+ (read at the cell's first frame), an
      # exact Rational (0 for negative or non-finite values).
      def speed_at(rf, ctx)
        return @speed_r if @speed_r
        s = ctx.clock_speed_value(@speed, rf).to_f
        s.finite? && s > 0 ? s.to_r : 0r
      end

      # The arguments of this clock's `clock` line (console and graph
      # documents): `:tide, 31.1.seconds` plus `speed:` when it isn't 1.
      # Raises ArgumentError for a speed that doesn't print as Ruby.
      def line_args
        parts = [Clock.base_ruby(@base)]
        case @speed
        when 1 then nil
        when Numeric, Symbol then parts << "speed: #{@speed.inspect}"
        when GraphNode::Knob then parts << "speed: #{@speed.name.inspect}"
        when GraphNode::Knob::Reader then parts << "speed: #{@speed.knob.name.inspect}"
        else
          raise ArgumentError, "clock #{@name.inspect}'s speed doesn't print as Ruby (#{@speed.class})" unless @speed.respond_to?(:to_ruby)
          parts << "speed: #{@speed.to_ruby}"
        end
        parts
      end

      # Ruby code for this clock: its name (Session clocks) or the value
      # it was made from.
      def to_ruby
        return @name.inspect if @name
        Clock.base_ruby(@base)
      end

      # Ruby text for a base value.
      def self.base_ruby(base)
        case base
        when MB::Sound::Length::Seconds
          v = base.value
          v = v.to_i if v.is_a?(Float) && v == v.round && v.abs < 1e12
          RubyValue.unit(v, 'seconds')
        else RubyValue.text(base) || (base.respond_to?(:to_ruby) ? base.to_ruby : base.inspect)
        end
      end

      # The clock in words: "138.75 BPM", "5/4 of the session tempo",
      # "19.7 s loop", with its speed.
      def describe
        text = case @kind
               when :tempo then "#{MB::M.sigfigs(@exact.to_f, 6)} BPM"
               when :ratio then "#{@exact.numerator}/#{@exact.denominator} of the session tempo"
               else "#{MB::M.sigfigs(@exact.to_f, 6)} s period"
               end
        sp = case @speed
             when 1 then nil
             when Numeric then "speed #{MB::M.sigfigs(@speed.to_f, 4)}"
             when Symbol then "speed knob(#{@speed.inspect})"
             else "speed #{@speed.respond_to?(:to_ruby) ? @speed.to_ruby : @speed}"
             end
        [text, sp].compact.join(', ')
      end

      def to_s
        @name ? "clock #{@name.inspect} (#{describe})" : "clock #{to_ruby}"
      end

      def inspect
        to_s
      end

      def ==(other)
        other.is_a?(Clock) && (@name ? @name == other.name && @session.equal?(other.session) : other.name.nil? && @kind == other.kind && @exact == other.instance_variable_get(:@exact) && @speed == other.speed)
      end
      alias eql? ==

      def hash
        @name ? [Clock, @name].hash : [Clock, @kind, @exact].hash
      end

      # Breakpoints of a variable-speed clock up to the run frames of the
      # span being rendered: called by the Session once per span (after
      # knobs move) for frames [+rf+, +rf+ + +count+).
      def advance(rf, count, ctx)
        return unless variable?
        @cell_lock.synchronize { extend_cells(rf + count, ctx) }
      end

      # Forgets breakpoints before run frame +rf+ (the Session keeps the
      # recent ones).
      def trim(rf)
        @cell_lock.synchronize {
          i = @cells.bsearch_index { |c| c[0] > rf }
          @cells = @cells.drop(i - 1) if i && i > 1
        }
      end

      # The cells kept (for specs): [[run frame, position, step], ...].
      def cells
        @cell_lock.synchronize { @cells.dup }
      end

      # The context clocks read outside a Session (a graph played on its
      # own): run frames count from the graph's start at +rate+, the
      # odometer at the transport's current tempo, speeds read now.
      class Free
        attr_reader :clock_rate

        def initialize(rate: 48000, transport: nil)
          @clock_rate = rate.to_r
          @transport = transport
        end

        def transport
          @transport || Sequence.transport
        end

        def per_sample_at(_rf)
          transport.whole_notes_per_second / @clock_rate.to_r
        end

        def odometer_at(rf)
          rf.to_r * per_sample_at(rf)
        end

        def tempo_point(rf)
          [0r, 0r, per_sample_at(rf)]
        end

        def next_tempo_point(_rf)
          nil
        end

        def clock_start_frame
          0
        end

        def clock_speed_value(speed, rf)
          pos = rf.to_r * per_sample_at(rf)
          case speed
          when Symbol
            s = Session.existing or raise ArgumentError, "The clock speed knob #{speed.inspect} needs a Session"
            s.knob!(speed).value
          when GraphNode::Knob then speed.value
          when GraphNode::Knob::Reader then speed.knob.value
          else speed.value_at(pos, transport: transport, stream: nil)
          end
        end
      end

      private

      def set_base(base)
        case base
        when MB::Sound::Tempo
          @kind = :tempo
          @exact = base.to_r
        when Rational
          raise ArgumentError, "A clock ratio is positive (got #{base})" unless base > 0
          @kind = :ratio
          @exact = base
        when MB::Sound::Length::Seconds
          raise ArgumentError, "A clock period is a positive number of seconds (got #{base})" unless base.fixed? && base.value > 0
          @kind = :period
          @exact = MB::Sound::Tempo.exact(base.value)
        else
          raise ArgumentError, "A clock is a tempo (138.75.bpm), a ratio of the session tempo (5/4r), or a loop period (19.7.seconds) (got #{ArgTypes.describe_value(base)})"
        end
        @base = base
      end

      # [rf, pos, step] at +rf+ for a variable-speed clock: from the cells
      # integrated so far (extending them to +rf+ if needed).
      def integrated(rf, _cell, ctx)
        @cell_lock.synchronize {
          stale = @cells.empty? || @cells.last[0] <= rf && next_cell_start(@cells.last[0], ctx) <= rf
          # Only renders (and graphs outside a Session) integrate: a poll
          # thread asking ahead (the UI) mustn't read speeds before the
          # frames they belong to are rendered
          extend_cells(rf + 1, ctx) if stale && (ctx.is_a?(Free) || Thread.current[:mb_sound_span] || @cells.empty?)
          i = @cells.bsearch_index { |c| c[0] > rf }
          i.nil? ? @cells.last : (i > 0 ? @cells[i - 1] : @cells.first)
        }
      end

      # The run frame of the breakpoint after +rf+.
      def next_cell_start(rf, ctx)
        next_break(rf, ctx)
      end

      # Integrates cells up to run frame +to+ (exclusive).
      def extend_cells(to, ctx)
        if @cells.empty?
          # A clock defined (or respecified) partway: it counts from where
          # speed 1 would have put it, at the cell holding the context's
          # first frame (so a new clock lines up with an anonymous one)
          start = ctx.clock_start_frame
          cell = (start.to_r / CELL).floor * CELL
          base_pos = @kind == :ratio ? @exact * ctx.odometer_at(cell) : cell * base_step(cell, ctx)
          @cells << [cell, base_pos, base_step(cell, ctx) * speed_at(cell, ctx)]
        end
        while (last = @cells.last) && (nxt = next_cell_start(last[0], ctx)) < to
          pos = last[1] + (nxt - last[0]) * last[2]
          cell_start = (nxt % CELL).zero?
          # Speed changes only at cell starts; tempo changes keep the speed
          sp = cell_start ? speed_at(nxt, ctx) : (last[2].zero? ? 0 : last[2] / base_step(last[0], ctx))
          @cells << [nxt, pos, base_step(nxt, ctx) * sp]
          @cells.shift while @cells.length > 4096
        end
      end
    end
  end
end
