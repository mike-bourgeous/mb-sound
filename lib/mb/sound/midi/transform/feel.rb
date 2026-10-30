module MB
  module Sound
    module MIDI
      class Transform
        # Shared seeded randomness for transforms (user decision: everything
        # random repeats from MB::Sound's seeds).  Each decision draws from
        # a Random seeded by the transform's seed and a counter (the note
        # index), so results don't depend on read sizes.
        module Seeded
          # The seed (see MB::Sound#next_seed).
          attr_reader :seed

          private

          def setup_seed(seed)
            @seed = seed.nil? ? MB::Sound.next_seed : Integer(seed)
            @draws = 0
          end

          # A Random for the next decision.
          def next_random
            Random.new((@seed * 1_000_003 + (@draws += 1)) & ((1 << 62) - 1))
          end
        end

        # Random timing (later only) and velocity offsets per note (see
        # Stream#humanize; the draws are Sequence::Feel's, shared with
        # Clip#humanize).
        class Humanize < NoteMap
          include Seeded

          def initialize(parent, time = Sequence::Feel::HUMANIZE_TIME, velocity: 0, seed: nil, **options)
            super(parent, **options)
            @time = Param.wrap(time, 'Humanize time')
            @velocity = Param.wrap(velocity, 'Humanize velocity')
            unless Param.param?(@time)
              raise ArgumentError, "Humanize time must not be negative (got #{time.inspect})" if seconds_of(time) < 0
            end
            if Param.param?(@velocity)
              shown = true
            else
              Sequence::Feel.check_fraction('Humanize velocity', velocity)
              @velocity = velocity.to_f
              shown = @velocity > 0
            end
            setup_seed(seed)
            @node_type_name = "humanize(#{Param.label(time)}#{", velocity: #{Param.label(velocity)}" if shown})"
          end

          private

          def tail_seconds
            Param.param?(@time) ? seconds_of(Param.largest(@time, 0.05)) : seconds_of(@time)
          end

          def map_on(e)
            amount = @velocity.is_a?(Float) ? @velocity : MB::M.clamp(param_at(@velocity, e.time).to_f, 0.0, 1.0)
            time = Param.param?(@time) ? MB::M.max(seconds_of(param_at(@time, e.time)), 0r) : seconds_of(@time)
            offset, velocity = Sequence::Feel.humanize_draw(next_random, e.velocity, amount, both_ways: false)
            delay = Sequence::Duration.rational(offset * time)
            e = e.with_velocity(velocity) if amount > 0
            [[e, delay]]
          end

          # Chased notes don't draw (so they can't change later decisions).
          def map_note(event)
            event
          end
        end

        # Delays notes to the next step of a timeline grid (see
        # Stream#quantize; the steps are Sequence::Feel's, shared with
        # Clip#quantize).
        class Quantize < NoteMap
          def initialize(parent, grid = Sequence::Feel::GRID, amount: 1, window: nil, ends: false, **options)
            super(parent, **options)
            @grid = Sequence::Duration.whole_notes(grid)
            @amount = Param.wrap(amount, 'Quantize amount')
            unless Param.param?(@amount)
              Sequence::Feel.check_fraction('Quantize amount', amount)
              @amount = Sequence::Duration.rational(amount)
            end
            @window = window && Sequence::Duration.whole_notes(window)
            @ends = !!ends
            @grid_label = grid.is_a?(Integer) ? "n#{grid}" : grid.to_s
            @node_type_name = "quantize(#{@grid_label}#{", amount: #{Param.label(amount)}" if amount != 1}#{', ends: true' if @ends})"
          end

          private

          def tail_seconds
            transport.seconds_of(@grid)
          end

          def map_on(e)
            target = Sequence::Feel.quantize_step(timeline_at(e.time), @grid, direction: :next, window: @window)
            return [[e, 0r]] if target.nil?

            delay = (stream_time_at(target) - e.time) * amount_at(e.time)
            [[e, MB::M.max(delay, 0r)]]
          end

          # With +ends: true+, note-offs move to the next step too (+amount+
          # of the way), keeping a whole note at least one step long when
          # fully quantized (like Clip#quantize's ends).
          def note_off_time(time, delay, on_time)
            return super unless @ends

            amount = amount_at(on_time)
            target = Sequence::Feel.quantize_step(timeline_at(time), @grid, direction: :next)
            off = time + (stream_time_at(target) - time) * amount
            start = on_time + delay
            off = MB::M.max(off, start + transport.seconds_of(@grid)) if amount == 1
            MB::M.max(off, time)
          end

          def map_note(event)
            event
          end

          # The amount (0..1, a Rational) at stream time +time+ (a param's
          # value there, limited to 0..1).
          def amount_at(time)
            return @amount unless Param.param?(@amount)
            Sequence::Duration.rational(MB::M.clamp(param_at(@amount, time).to_f, 0.0, 1.0))
          end
        end

        # Delays notes onto a feel template's positions on the timeline
        # (see Stream#groove; the core is Sequence::Feel.groove_target,
        # shared with Clip#groove) and scales their velocities toward its
        # levels.
        class Groove < NoteMap
          def initialize(parent, template, amount: 1, velocity: nil, **options)
            super(parent, **options)
            raise ArgumentError, "groove takes a Groove or a Clip (got #{template.class})" unless template.is_a?(Sequence::Groove)
            Sequence::Feel.check_fraction('Groove amount', amount)
            velocity = amount if velocity.nil?
            Sequence::Feel.check_fraction('Groove velocity', velocity)
            @template = template
            @amount = Sequence::Duration.rational(amount)
            @velocity = velocity
            @node_type_name = "groove(#{template.steps} steps#{", amount: #{amount}" if amount != 1})"
          end

          private

          def tail_seconds
            transport.seconds_of(@template.grid * 2)
          end

          def map_on(e)
            target, i = @template.target(timeline_at(e.time), direction: :next)
            delay = (stream_time_at(target) - e.time) * @amount
            v = Sequence::Groove.level(e.velocity, @template.levels[i], @velocity)
            e = e.with_velocity(v) if v != e.velocity
            [[e, MB::M.max(delay, 0r)]]
          end

          def map_note(event)
            event
          end
        end

        # Delays offbeat notes by the timeline grid (see Stream#swing; the
        # time warp is Sequence::Feel's, shared with Clip#swing).  Note-offs
        # go through the same warp, so lengths follow as in clips.
        class Swing < NoteMap
          def initialize(parent, amount = Sequence::Feel::SWING, grid = Sequence::Feel::GRID, **options)
            super(parent, **options)
            @amount = Param.wrap(amount, 'Swing amount')
            @amount = Sequence::Feel.check_swing(amount, delay_only: true) unless Param.param?(@amount)
            @grid = Sequence::Duration.whole_notes(grid)
            @grid_label = grid.is_a?(Integer) ? "n#{grid}" : grid.to_s
            @node_type_name = "swing(#{Param.label(amount)}#{", #{@grid_label}" if @grid != 1/16r})"
          end

          private

          def tail_seconds
            transport.seconds_of(@grid * 2)
          end

          def map_on(e)
            [[e, MB::M.max(swung(e.time, swing_at(e.time)) - e.time, 0r)]]
          end

          def note_off_time(time, _delay, on_time)
            MB::M.max(swung(time, swing_at(on_time)), time)
          end

          # The stream time of stream time +time+ through the swing warp
          # (by +amount+) of its timeline position.
          def swung(time, amount = @amount)
            stream_time_at(Sequence::Feel.swing_warp(timeline_at(time), amount, @grid))
          end

          # The swing amount at stream time +time+: a param's value read
          # there (at the played note-on; its note-off warps by the same
          # amount), limited to 0.5 (straight) up to just under 1.
          def swing_at(time)
            return @amount unless Param.param?(@amount)
            Sequence::Duration.rational(MB::M.clamp(param_at(@amount, time).to_f, 0.5, 0.99))
          end

          def map_note(event)
            event
          end
        end

        # Plays each note with a probability (see Stream#chance), decided
        # per note from the seed and a counter, like Clip#chance decides
        # per cycle and note.
        class Chance < NoteMap
          include Seeded

          def initialize(parent, probability, seed: nil, **options)
            super(parent, **options)
            @probability = Param.wrap(probability, 'Chance')
            @probability = Sequence::Clip.check_probability(probability) unless Param.param?(@probability)
            setup_seed(seed)
            @node_type_name = "chance(#{Param.label(probability)})"
          end

          private

          def map_on(e)
            p = Param.param?(@probability) ? MB::M.clamp(param_at(@probability, e.time).to_f, 0.0, 1.0) : @probability
            next_random.rand < p ? [[e, 0r]] : []
          end

          # Chased notes don't draw (so they can't change later decisions).
          def map_note(event)
            event
          end
        end

        # Plays notes only in every +n+th bar of the timeline (see
        # Stream#every; the condition is Sequence::Feel's, shared with
        # Clip#every, which counts loop cycles).
        class Every < NoteMap
          def initialize(parent, n, from: 1, **options)
            super(parent, **options)
            @n = Param.wrap(n, 'every')
            @from = from
            @condition = Param.param?(@n) ? nil : Sequence::Clip.check_condition(n, from)
            @node_type_name = "every(#{Param.label(n)}#{", from: #{from}" if from != 1})"
          end

          private

          # The 0-based bar of the timeline at stream +time+ (bars follow
          # the transport's meter map).
          def bar_index(time)
            transport.bar_at(timeline_at(time)).floor - 1
          end

          def map_on(e)
            Sequence::Feel.condition_plays?(condition_at(e.time), bar_index(e.time)) ? [[e, 0r]] : []
          end

          # The condition for the bar holding stream time +time+: a param's
          # n is read at the bar's start (a whole number of at least 1).
          def condition_at(time)
            return @condition if @condition

            bar_start = transport.bar_position(transport.bar_at(timeline_at(time)).floor)
            n = Param.value_at(@n, bar_start, transport: transport, stream: @reading).to_f.round
            Sequence::Clip.check_condition(MB::M.max(n, 1), @from)
          end
        end

        # Spreads notes that start together over time, like strumming (see
        # Stream#strum).
        class Strum < Scheduled
          include Seeded

          # Strum directions (see Stream#strum).
          DIRECTIONS = [:down, :up, :alternate, :random, :played].freeze

          def initialize(parent, spread = 0.03, direction = :down, window: 0, velocity: 1, seed: nil, **options)
            super(parent, **options)
            raise ArgumentError, "Strum direction must be one of #{DIRECTIONS.map(&:inspect).join(', ')} (got #{direction.inspect})" unless DIRECTIONS.include?(direction)
            raise ArgumentError, "Strum spread must not be negative (got #{spread.inspect})" if seconds_of(spread) < 0
            raise ArgumentError, "Strum window must not be negative (got #{window.inspect})" if seconds_of(window) < 0

            @spread = spread
            @direction = direction
            @window = window
            @velocity = velocity.to_f
            setup_seed(seed)
            @group = nil # [start time, [[event, off time or nil], ...]]
            @strokes = 0
            @chains = {} # [channel, note] => Array of [note, channel, id, delay]
            @node_type_name = "strum(#{spread}, #{direction.inspect}#{", window: #{window}" if seconds_of(window) > 0})"
          end

          def ended?
            super && @group.nil?
          end

          private

          def tail_seconds
            seconds_of(@spread) + seconds_of(@window)
          end

          def process(events, _from, to)
            events.each do |e|
              close_group if @group && e.time > @group[0] + seconds_of(@window)

              case e.type
              when :note_on
                @group ||= [e.time, []]
                @group[1] << [e, nil]
              when :note_off
                entry = @group && @group[1].find { |n, off| off.nil? && n.note == e.note && n.channel == e.channel }
                if entry
                  entry[1] = e.time
                else
                  note_off(e)
                end
              else
                schedule(e)
              end
            end

            close_group if @group && (to > @group[0] + seconds_of(@window) || @input.ended?)
          end

          def close_group
            start, notes = @group
            @group = nil
            @strokes += 1

            ordered = case @direction
                      when :down then notes.sort_by.with_index { |(n, _), i| [n.note.to_f, i] }
                      when :up then notes.sort_by.with_index { |(n, _), i| [-n.note.to_f, i] }
                      when :alternate
                        down = notes.sort_by.with_index { |(n, _), i| [n.note.to_f, i] }
                        @strokes.odd? ? down : down.reverse
                      when :random then notes.shuffle(random: next_random)
                      else notes
                      end

            base = start + seconds_of(@window)
            step = ordered.length > 1 ? seconds_of(@spread) / (ordered.length - 1) : 0r
            ordered.each_with_index do |(e, off), i|
              on = base + step * i
              out = e.at(on)
              out = out.with_velocity(MB::M.clamp(e.velocity * @velocity ** i, 1 / 127.0, 1.0)) if @velocity != 1
              id = schedule_on(out)
              delay = on - e.time
              chain = [out.note, out.channel, id, delay]
              if off
                schedule_off(Event.note_off(out.note, channel: out.channel, time: off + delay), id)
              else
                (@chains[[e.channel, e.note]] ||= []) << chain
              end
            end
          end

          def note_off(e)
            key = [e.channel, e.note]
            list = @chains[key]
            note, channel, id, delay = list&.shift
            @chains.delete(key) if list && list.empty?
            return unless id

            schedule_off(Event.note_off(note, e.velocity, channel: channel, time: e.time + delay), id)
          end

          def cut_state
            @chains.clear
            @group = nil
          end
        end
      end
    end
  end
end
