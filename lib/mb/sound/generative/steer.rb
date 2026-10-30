module MB
  module Sound
    module Generative
      # Knob steering for generators (G3, design/notes/generative.md,
      # "Steering"): a generator's options that move (knobs, `cc`, tempo
      # LFOs, `knob(:x).choose(...)`, param arithmetic; MIDI::Param) are
      # read once per cycle at its **decision point**, +lead+ (one beat by
      # default) before the cycle starts, and the cycle's events are a pure
      # function of (seed, cycle, the values decided).
      #
      # Where the decision is read: a steered clip (Sequence::Clip#steered?)
      # doesn't read a cycle until playback reaches its decision point, so
      # the read happens in the span that holds the decision point and a
      # knob answers exactly the value it had on that frame
      # (GraphNode::Knob#value_at); a turn issued before the decision point
      # steers the cycle, a later one the cycle after.  Renders are
      # deterministic, takes replay the same decisions (knob turns replay on
      # the same frames; decisions made for future positions are logged,
      # Session::Decisions), and a cycle read after its decision point (a
      # launch, a seek) reads the values as they are then.  Decisions are
      # remembered per Session epoch (seeks start a new one) and cycle, so
      # a seek back decides again.
      #
      # Steered events may start at most +lead+ before their cycle (at the
      # decision point, not a whole cycle early like other generators'
      # events).
      #
      # Ahead of time: when a cycle is decided, the next cycle is computed
      # on the realtime Session's scheduler thread with the values the
      # params have then (Param.peek: nothing decided or logged); if the
      # decision point brings the same values, playback uses that cycle,
      # else it computes the cycle where it's read.
      class Steer
        # The default decision lead in whole notes (one beat in 4/4).
        DEFAULT_LEAD = 1r / 4

        # Decisions remembered per generator (oldest dropped first).
        DECISIONS = 256

        # The options (name => param, or a plain value).
        attr_reader :params

        # The decision lead in whole notes.
        attr_reader :lead

        # A Steer for +params+ (a Hash of option name => value; +what+
        # names the generator in errors), or nil when nothing in it moves
        # (plain values keep the generator's unsteered code path).  +lead+
        # is a length (1.beat, 1.n8; at most one cycle of +length+ whole
        # notes) or nil for one beat (or the cycle, if shorter).
        def self.build(params, length:, what:, lead: nil)
          moving = params.any? { |_, v| MIDI::Param.param?(v) }
          return nil unless moving
          new(params, length: length, what: what, lead: lead)
        end

        def initialize(params, length:, what:, lead: nil)
          @params = params.to_h { |k, v|
            [k.to_sym, MIDI::Param.param?(v) ? MIDI::Param.wrap(v, "#{what}'s #{k}:") : v]
          }.freeze
          @lead = if lead.nil?
                    MB::M.min(DEFAULT_LEAD, length)
                  else
                    Generative.length_of(lead, :lead, divisions: false).tap { |l|
                      raise ArgumentError, "#{what}'s lead: is at most one cycle (#{Sequence::Duration.format(length)}; got #{Sequence::Duration.format(l)})" if l > length
                    }
                  end
          @decided = {}
          @mutex = Mutex.new
        end

        # The clip position of +cycle+'s decision point (cycles +length+
        # whole notes long).
        def decision(cycle, length)
          cycle * length - @lead
        end

        # The values decided for +cycle+ (a frozen Hash of option name =>
        # value), read at the decision point the first time they are asked
        # for in the current Session epoch (see the class comment).
        def decide(cycle, length)
          key = Steer.key(cycle)
          hit = @mutex.synchronize { @decided[key] }
          return hit if hit

          values = read(cycle, length, Steer.origin)
          @mutex.synchronize {
            @decided.shift while @decided.length >= DECISIONS
            @decided[key] ||= values
          }
        end

        # The values +cycle+ would get if decided now (Param.peek: nothing
        # is decided or logged), for computing it ahead of time; +origin+ as
        # Steer.origin was when the cycle before was read.
        def peek(cycle, length, origin)
          MIDI::Param.peek { read(cycle, length, origin) }
        end

        # The graph nodes the params read (knobs, LFOs), for documents and
        # Sessions adopting knobs.
        def nodes
          @params.values.flat_map { |v| v.is_a?(MIDI::Param::Base) ? v.nodes : [] }
        end

        def inspect
          "#<#{self.class.name} #{@params.keys.join(', ')} lead #{Sequence::Duration.format(@lead)}>"
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

        # The epoch of the Session rendering on this thread (0 outside one).
        def self.epoch
          Session.span&.session&.epoch || 0
        end

        # A cache key for +cycle+ in the current epoch (an Integer, so
        # lookups allocate nothing).
        def self.key(cycle)
          cycle + (epoch << 48)
        end

        private

        def read(cycle, length, origin)
          pos = decision(cycle, length)
          tl = if origin == :clocked
                 # A clip on its own clock: read at the timeline's position now
                 (Session.span&.session || Session.existing)&.transport&.position || pos
               else
                 pos + origin
               end
          @params.transform_values { |v| ValueSource.value_at(v, tl) }.freeze
        end
      end
    end
  end
end
