module MB
  module Sound
    module Generative
      # Knob steering for generators (G3, design/notes/generative.md,
      # "Steering"): a generator's options that move (knobs, `cc`, tempo
      # LFOs, `knob(:x).choose(...)`, param arithmetic; MIDI::Param) are
      # read once per **unit**: the whole cycle by default, or a piece of
      # it (+decide+: beats reads per beat, beats-timing-1).  A unit's
      # values are the params' values *at the unit's start* (an LFO's value
      # there, a ramp's value there), and its events are the events of the
      # cycle computed with those values that start inside the unit, so a
      # value steers the notes that sound in its unit.  The events of a
      # cycle are a pure function of (seed, cycle, the values decided).
      #
      # When the decision is read: at the unit's **decision point**, +lead+
      # before the unit starts (0 for beats, one beat for the others, whose
      # notes may start early).  A steered clip (Sequence::Clip#steered?)
      # doesn't read a unit until playback reaches its decision point, so
      # the read happens in the span that holds it: with no lead, a knob
      # answers exactly the value it has on the unit's first frame
      # (GraphNode::Knob#value_at), so a turn issued before the unit starts
      # steers it; with a lead, values known ahead (tempo LFOs, knobs
      # following one, ramps and turns already queued) are still read for
      # the unit's start, and a hand turn must come before the decision
      # point.  Renders are deterministic, takes replay the same decisions
      # (knob turns replay on the same frames; decisions made for future
      # positions are logged, Session::Decisions), and a unit read after
      # its decision point (a launch, a seek) reads the values as they are
      # then.  Decisions are remembered per Session epoch (seeks start a new
      # one) and unit, so a seek back decides again.
      #
      # Steered events may start at most +lead+ before their cycle (at the
      # decision point, not a whole cycle early like other generators'
      # events).
      #
      # Ahead of time: when a unit is decided, the next one is computed on
      # the realtime Session's scheduler thread with the values the params
      # have then for its start (Param.peek: nothing decided or logged); if
      # the decision brings the same values, playback uses that cycle, else
      # it computes the cycle where it's read.
      class Steer
        # The default decision lead in whole notes (one beat in 4/4).
        DEFAULT_LEAD = 1r / 4

        # Names for +decide:+ (besides lengths): the whole cycle, a bar of
        # the current meter, a beat (a quarter note).  Beats also takes
        # :step (its step length; MB::Sound#beats).
        DECIDE_NAMES = %i[cycle bar beat].freeze

        # Decisions remembered per generator (oldest dropped first).
        DECISIONS = 256

        # The options (name => param, or a plain value).
        attr_reader :params

        # The decision lead in whole notes.
        attr_reader :lead

        # The unit length in whole notes (the cycle's, unless +decide:+
        # made it shorter).
        attr_reader :unit

        # The +decide:+ setting as given (a Symbol or a length).
        attr_reader :decide_setting

        # A Steer for +params+ (a Hash of option name => value; +what+
        # names the generator in errors), or nil when nothing in it moves
        # (plain values keep the generator's unsteered code path).  +lead+
        # is a length (1.beat, 1.n8; 0 for none; at most one cycle of
        # +length+ whole notes) or nil for one beat (or the cycle, if
        # shorter).  +decide+ is how often values are read: :cycle, :bar,
        # :beat, or a length (at most one cycle).
        def self.build(params, length:, what:, lead: nil, decide: :cycle)
          moving = params.any? { |_, v| MIDI::Param.param?(v) }
          return nil unless moving
          new(params, length: length, what: what, lead: lead, decide: decide)
        end

        # The unit length in whole notes for +decide+ (see .build) in cycles
        # of +length+ whole notes; +what+ names the generator in errors.
        def self.unit_of(decide, length, what)
          unit = case decide
                 when :cycle, nil then length
                 when :bar then Sequence.current_transport.bar_length.to_r
                 when :beat then 1r / 4
                 when Symbol
                   hint = DidYouMean::SpellChecker.new(dictionary: DECIDE_NAMES).correct(decide).first
                   raise ArgumentError, "#{what}'s decide: is :cycle, :bar, :beat, or a length like 1.n8#{hint ? " (did you mean #{hint.inspect}?)" : ''} (got #{decide.inspect})"
                 else Generative.length_of(decide, :decide, divisions: false)
                 end
          if unit > length
            raise ArgumentError, "#{what}'s decide: is at most one cycle (#{Sequence::Duration.format(length)}; got #{Sequence::Duration.format(unit)}): use decide: :cycle"
          end
          unit
        end

        def initialize(params, length:, what:, lead: nil, decide: :cycle)
          @params = params.to_h { |k, v|
            [k.to_sym, MIDI::Param.param?(v) ? MIDI::Param.wrap(v, "#{what}'s #{k}:") : v]
          }.freeze
          @lead = if lead.nil?
                    MB::M.min(DEFAULT_LEAD, length)
                  elsif lead == 0
                    0r
                  else
                    Generative.length_of(lead, :lead, divisions: false).tap { |l|
                      raise ArgumentError, "#{what}'s lead: is at most one cycle (#{Sequence::Duration.format(length)}; got #{Sequence::Duration.format(l)})" if l > length
                    }
                  end
          @decide_setting = decide
          @length = length
          @unit = Steer.unit_of(decide, length, what)
          @units = (length / @unit).ceil
          @decided = {}
          @mutex = Mutex.new
        end

        # Units per cycle of +length+ whole notes (1 unless +decide:+ is
        # shorter than the cycle; the last unit may be shorter).
        def units(length = @length)
          length == @length ? @units : (length / @unit).ceil
        end

        # The unit of a clip position +offset+ whole notes into a cycle of
        # +length+ (early offsets in the first unit, late ones in the last).
        def unit_index(offset, length = @length)
          n = units(length)
          return 0 if n == 1 || offset <= 0
          MB::M.min((offset / @unit).floor, n - 1)
        end

        # The clip position of +cycle+'s decision point (cycles +length+
        # whole notes long): its first unit's.
        def decision(cycle, length, unit = 0)
          cycle * length + unit * @unit - @lead
        end

        # The values decided for the unit of +cycle+ holding +offset+ (whole
        # notes into the cycle; a frozen Hash of option name => value), read
        # for the unit's start the first time they are asked for in the
        # current Session epoch (see the class comment).
        def decide(cycle, length, offset = 0)
          u = unit_index(offset, length)
          key = Steer.key(cycle * units(length) + u)
          # (pregenerating: what the unit would get if decided now, the
          # same values for every ask in the pass; nothing decided)
          if (pre = Thread.current[:mb_steer_pregen])
            return pre.values(self, key) { read(cycle, length, Steer.origin, u) }
          end
          hit = @mutex.synchronize { @decided[key] }
          return hit if hit

          values = read(cycle, length, Steer.origin, u)
          @mutex.synchronize {
            @decided.shift while @decided.length >= DECISIONS
            @decided[key] ||= values
          }
        end

        # The values the unit of +cycle+ holding +offset+ would get if
        # decided now (Param.peek: nothing is decided or logged), for
        # computing it ahead of time; +origin+ as Steer.origin was when the
        # unit before was read.
        def peek(cycle, length, origin, offset = 0)
          MIDI::Param.peek { read(cycle, length, origin, unit_index(offset, length)) }
        end

        # The graph nodes the params read (knobs, LFOs), for documents and
        # Sessions adopting knobs.
        def nodes
          @params.values.flat_map { |v| v.is_a?(MIDI::Param::Base) ? v.nodes : [] }
        end

        def inspect
          per = @units == 1 ? '' : " per #{Sequence::Duration.format(@unit)}"
          "#<#{self.class.name} #{@params.keys.join(', ')}#{per} lead #{Sequence::Duration.format(@lead)}>"
        end

        # The timeline position of clip position 0 for the clip being read
        # on this thread (set by MIDI::ClipSource around its reads; 0
        # outside them, :clocked for clips on their own clock).
        def self.origin
          Thread.current[:mb_steer_origin] || 0r
        end

        # Sets Steer.origin for this thread (MIDI::ClipSource), returning
        # the previous one.
        def self.origin=(origin)
          Thread.current[:mb_steer_origin] = origin
        end

        # The epoch of the Session rendering on this thread (0 outside one;
        # while pregenerating, the epoch of the Session the clip will play
        # in: .pregenerating).
        def self.epoch
          (pre = Thread.current[:mb_steer_pregen]) ? pre.epoch : (Session.span&.session&.epoch || 0)
        end

        # What a pass of .pregenerating holds: the +epoch+ the clip will
        # play in, and the values each Steer's units got in the pass
        # (#values), so every ask for a unit sees the same values.
        class Pregen
          attr_reader :epoch

          def initialize(epoch)
            @epoch = epoch
            @memo = {}.compare_by_identity
          end

          # The values +steer+'s unit +key+ got in this pass, read with the
          # block (under Param.peek: nothing decided or logged) the first
          # time.
          def values(steer, key)
            per = (@memo[steer] ||= {})
            per.fetch(key) { per[key] = MIDI::Param.peek { yield } }
          end
        end

        # Runs the block computing what a clip's first reads will need
        # before it plays (Sequence::Clip#pregenerate, on the thread that
        # queues the change: the console, not the render thread), with
        # Steer.origin +origin+ (where the clip's position 0 will be on the
        # timeline) and cache keys of +epoch+ (the playing Session's).
        # Steered units get the values their params have now for them
        # (#peek), the same for every ask in the pass; nothing is decided
        # or logged, so the playing clip decides as it always does, and a
        # result made here is used only when the decision brings the same
        # values (Sequence::Clip, "Pregenerated").
        def self.pregenerating(origin, epoch)
          prev_origin = Thread.current[:mb_steer_origin]
          prev = Thread.current[:mb_steer_pregen]
          Thread.current[:mb_steer_origin] = origin
          Thread.current[:mb_steer_pregen] = Pregen.new(epoch)
          yield
        ensure
          Thread.current[:mb_steer_pregen] = prev
          Thread.current[:mb_steer_origin] = prev_origin
        end

        # True inside .pregenerating on this thread.
        def self.pregenerating?
          !Thread.current[:mb_steer_pregen].nil?
        end

        # A cache key for +cycle+ in the current epoch (an Integer, so
        # lookups allocate nothing).
        def self.key(cycle)
          cycle + (epoch << 48)
        end

        private

        # Reads the params for unit +u+ of +cycle+: their values at the
        # unit's start (beats-timing-1: before, at the decision point, so a
        # bar read the value of the beat before it, and a 2-bar square LFO
        # played a bar late; the session key was already read for the
        # cycle's start, gen-ux-1).
        def read(cycle, length, origin, u = 0)
          pos = cycle * length + u * @unit
          if origin == :clocked
            # A clip on its own clock: read at the timeline's position now
            # (the session key at now + lead, where the unit starts)
            tl = (Session.span&.session || Session.existing)&.transport&.position || pos
            return @params.transform_values { |v| ValueSource.value_at(v, v.is_a?(KeyFollow::Param) ? tl + @lead : tl) }.freeze
          end
          tl = pos + origin
          @params.transform_values { |v| ValueSource.value_at(v, tl) }.freeze
        end
      end
    end
  end
end
