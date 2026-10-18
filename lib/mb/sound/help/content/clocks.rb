# Help topics for clocks (`help :clocks`) and the type-dispatched
# prepositions `help :at` and `help :over` (time-automation, 2026-10-18).
# The :at and :over pages print the declared tables (ArgTypes::REGISTRY)
# as they are in the code, so the help can't drift from what the methods
# do.  Same rules as topics.rb: the guard spec plays every example and
# checks its level.
module MB
  module Sound
    module Help
      # Rows for a page about method +name+'s type tables: one heading per
      # receiver, a row per type.
      def self.arg_type_section(name)
        lambda do |d|
          ArgTypes.tables_for(name).each_value do |table|
            next unless table.is_a?(ArgTypes::Dispatch)
            d.heading("#{table.receiver.capitalize}: #{name == :% ? "x % y" : ".#{name}(x)"} by the type of x")
            rows = table.rows.map { |type, (method, meaning)| [ArgTypes.describe(type), "#{meaning} (= .#{method}(x))"] }
            rows << ['anything else', table.fallback_meaning] if table.fallback_meaning
            d.rows(rows, max_label: 34, wrap: true)
            d.note(table.note) if table.note
          end
        end
      end
    end

    Help.topic :clocks, 'Clocks: loops in seconds, clips at their own tempo', group: :time do
      about <<~TEXT
        A clock is a timebase other than the session's bars: a loop period
        (`clock :tide, 31.1.seconds`), a tempo of its own (`clock :reese,
        138.75.bpm`), or a ratio of the session tempo (`clock :lag, 5/4r`,
        or `gear :reese, 165 => 138.75`).  Clips go on a clock with
        `clip.clocked(:tide)` (also `clip % 19.7.seconds`, `clip.at(138.75.bpm)`,
        `clip.over(19.7.seconds)`; graphs print `clocked`), or a whole track
        with `track :bowl, clock: :tide do |c| ... end`, or `bg ..., clock:`.
        Audio loops too: `pad.clocked(19.7.seconds)` stretches the loop to
        the period, keeping its pitch (`fit: :stretch`, the default), or
        `fit: :resample` plays it slower or faster like tape.

        Clocks count session time, not bars: a clip dropped by a scene comes
        back where it would have been, a seek leaves it alone, and a take
        replays it exactly at any buffer size.  They pause with the
        timeline.  Launches still land on the session's bars.  `speed:`
        takes a number, a knob's name, or a param (`cc(1, 0.5..2)`), read
        every 800 frames; turns of the knob are journaled like any turn.
      TEXT
      commands :clock, :clocks, :gear
      dsl :clocked, :follow
      note :arrangement, :sequences
      see :at, :over, :sets, :loops, :knobs
      example 'two strikes that never line up the same way twice', bars: 4 do
        clock :try_a, 1.3.seconds
        clock :try_b, 1.7.seconds
        ding = seq(E5.n16, Rest.n16).loop
        bg :try, ding.clocked(:try_a).trigger.resonate(:rin, decay: 1.5) * -21.db
        bg :try2, ding.clocked(:try_b).trigger.resonate(:bowl, decay: 2.5) * -10.db
      end
      example 'a riff at its own tempo' do
        riff = seq(A2, C3, E3, A3, G3, E3).n8.loop
        bg :try, riff.clocked(98.bpm).tone.triangle.at(-20.db) * riff.clocked(98.bpm).amp_env
      end
    end

    Help.topic :at, 'at: by the type of what you give it', group: :time do
      about <<~TEXT
        `at` reads its argument's type.  On a graph node it scales (`sig.at(-6.db)`,
        `lfo.at(200..800)`).  On a clip or a sample a tempo, a ratio, or a
        clock's name puts it on a clock, and on a clip a length in seconds is a
        loop period; a sample's lengths and numbers stay offsets (`brk.at(7.n16)`).
        Plain numbers on a clip raise, listing what would work.  The tables
        below are the code's own (ArgTypes).
      TEXT
      dsl :at
      section(&Help.arg_type_section(:at))
      see :over, :clocks
      example 'a clip at 5/4 of the session tempo' do
        riff = seq(A3, E4, C4, E4).n8.loop.at(5/4r)
        bg :try, riff.tone.triangle.at(-20.db) * riff.amp_env
      end
    end

    Help.topic :over, 'over: a span', group: :time do
      about <<~TEXT
        `over` means a span everywhere: a turn's ramp (`turn :cut, 3000,
        over: 2.bars`), a fade, and on clips and samples a loop period (the
        loop spans that long: `bowl.over(19.7.seconds)`, the same as
        `bowl.clocked(19.7.seconds)`).  Stretching a clip to fit bars is not a
        clock (scale its notes with `.stretch`).  `clip % x` is the clock by
        type too.  The tables below are the code's own (ArgTypes).
      TEXT
      section(&Help.arg_type_section(:over))
      section(&Help.arg_type_section(:%))
      see :at, :clocks, :knobs
      example 'a strike every 1.5 seconds' do
        bg :try, seq(G5.n16, Rest.n16).loop.over(1.5.seconds).trigger.resonate(:bowl, decay: 1.2) * -9.db
      end
    end
  end
end
