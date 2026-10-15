module MB
  module Sound
    module Generative
      # The per-cycle events of a generator clip (Sequence::Clip.generate):
      # a block called with (cycle, dice) that returns the cycle's events,
      # repeatably.  It is the +block+ of the clip's Clip::Variation (it
      # answers #call(events, cycle, clip)), so generator clips play
      # wherever clips play (synths, kits, scenes, swap, rec, bake, MIDI
      # export, takes).
      #
      # The block must depend only on the cycle and the dice (and values
      # fixed when the generator was made), never on call order or a
      # stateful Random: cycles are computed cold on seeks and takes, ahead
      # of time on a background thread (see Ahead), and again after the
      # cache drops them, and must come out the same every time.
      #
      # The block returns Events or rows [start, length, value, velocity,
      # { marks }] (see MB::Sound#events), starts relative to the cycle in
      # whole notes (Rationals, Integers, or Durations; a start may be up
      # to one cycle early or late, see Clip::Variation).
      #
      # Cost: #stats counts cycles, notes, and the time spent (mean and
      # worst cycle), for checking that generation stays predictable.
      class Generator
        # Cycles kept per generator (a seek back to recent cycles is free).
        CACHE_CYCLES = 32

        include Producer

        # The clip length in whole notes (one cycle).
        attr_reader :length

        # The seed of the dice.
        attr_reader :seed

        # A name for listings (e.g. "strikes(seed: 3)").
        attr_reader :name

        # The latest end of any event, in whole notes from its cycle's
        # start (see .new).
        attr_reader :reach

        # +length+ is the cycle length in whole notes; +reach+ the latest
        # end of any event from its cycle's start (2 cycles by default:
        # notes up to a cycle long), which tells clips how far back to look
        # for note-offs.
        def initialize(length, seed:, name: nil, reach: nil, &block)
          raise ArgumentError, 'A generator needs a block: { |cycle, dice| events }' unless block
          @length = length
          @reach = reach ? reach.to_r : length * 2
          raise ArgumentError, "A generator's reach must be at least its length (got #{reach})" if @reach < length
          @seed = Integer(seed)
          @name = name || "generate(seed: #{@seed})"
          @block = block
          @cache = {}
          @mutex = Mutex.new
          @stats = { cycles: 0, notes: 0, seconds: 0.0, worst: 0.0, worst_cycle: nil }
        end

        # The Events of +cycle+ (frozen, sorted by start), computed once and
        # cached; asks Ahead to compute the next cycle in the background.
        def events(cycle)
          list = @mutex.synchronize { @cache[cycle] }
          Ahead.request(self, cycle + 1)
          list || compute(cycle)
        end

        # True if +cycle+ is cached.
        def cached?(cycle)
          @mutex.synchronize { @cache.key?(cycle) }
        end

        # Computes and caches +cycle+ (used by #events and Ahead).
        def compute(cycle)
          t0 = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
          raw = @block.call(cycle, Dice.new(@seed, cycle))
          list = Generator.normalize(raw, @name).sort_by(&:start).freeze
          list.each { |e| check_reach(e, cycle) }
          dt = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - t0
          @mutex.synchronize {
            @stats[:cycles] += 1
            @stats[:notes] += list.length
            @stats[:seconds] += dt
            if dt > @stats[:worst]
              @stats[:worst] = dt
              @stats[:worst_cycle] = cycle
            end
            @cache.shift while @cache.length >= CACHE_CYCLES
            @cache[cycle] ||= list
          }
        end

        # Cycles computed, notes made, seconds of CPU (thread time), and
        # the worst cycle's seconds and number.
        def stats
          @mutex.synchronize { @stats.dup }
        end

        # Events from a generator block's result (see the class comment).
        def self.normalize(raw, name)
          raise ArgumentError, "#{name}'s block must return an Array of events (got #{raw.class})" unless raw.is_a?(Array)
          raw.map { |e|
            case e
            when Sequence::Event then check_event(e, name)
            when Array then check_event(row_event(e, name), name)
            else raise ArgumentError, "#{name} made #{e.inspect}: events are Sequence::Events or [start, length, value, velocity] rows"
            end
          }
        end

        def self.row_event(row, name)
          raise ArgumentError, "#{name} made the row #{row.inspect}: rows are [start, length, value, velocity, { marks }]" unless row.length.between?(3, 5)
          start, len, value, velocity, marks = row
          marks ||= {}
          unknown = marks.keys - MB::Sound::SequenceMethods::EVENT_MARKS
          raise ArgumentError, "#{name} made unknown event marks #{unknown.inspect}" unless unknown.empty?
          Sequence::Event.new(
            start: time(start, name), length: time(len, name), value: value,
            velocity: velocity.nil? ? Sequence::Clip::DEFAULT_VELOCITY : velocity.to_f.clamp(0.0, 1.0), **marks
          )
        end

        def self.time(t, name)
          case t
          when Sequence::Duration then t.whole_notes
          when Integer, Rational then t.to_r
          else raise ArgumentError, "#{name} made a time of #{t.inspect}: event times are whole notes (Rationals, like 1r/8, or Durations, like 1.n8)"
          end
        end

        def self.check_event(e, name)
          raise ArgumentError, "#{name} made an event of negative length (#{e})" if e.length < 0
          e
        end

        # Cycles an event can reach past its own (for Clip's note-off lookback).
        def reach_cycles
          (@reach / @length).ceil
        end

        def to_s
          @name
        end

        private

        def check_reach(e, cycle)
          return if e.start >= -@length && e.start < @length * 2 && e.end_time <= @reach
          raise ArgumentError, "#{@name} made #{e} in cycle #{cycle}: events start from one cycle early to two cycles in and end by #{Sequence::Duration.format(@reach)} (pass reach: for longer notes)"
        end

        def inspect
          "#<#{self.class.name} #{@name}>"
        end
      end
    end
  end
end
