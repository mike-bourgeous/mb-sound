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
        # Stream#humanize).
        class Humanize < NoteMap
          include Seeded

          def initialize(parent, time = 0.01, velocity: 0, seed: nil, **options)
            super(parent, **options)
            raise ArgumentError, "Humanize time must not be negative (got #{time.inspect})" if seconds_of(time) < 0
            raise ArgumentError, "Humanize velocity must be from 0 to 1 (got #{velocity.inspect})" unless velocity.is_a?(Numeric) && velocity.between?(0, 1)
            @time = time
            @velocity = velocity.to_f
            setup_seed(seed)
            @node_type_name = "humanize(#{time}#{", velocity: #{velocity}" if @velocity > 0})"
          end

          private

          def tail_seconds
            seconds_of(@time)
          end

          def map_on(e)
            rng = next_random
            delay = Sequence::Duration.rational(rng.rand * seconds_of(@time))
            v = rng.rand * 2 - 1
            e = e.with_velocity(MB::M.clamp(e.velocity * (1 + v * @velocity), 1 / 127.0, 1.0)) if @velocity > 0
            [[e, delay]]
          end

          # Chased notes don't draw (so they can't change later decisions).
          def map_note(event)
            event
          end
        end

        # Delays notes to the next step of a timeline grid (see
        # Stream#quantize).
        class Quantize < NoteMap
          def initialize(parent, grid = 16, amount: 1, window: nil, **options)
            super(parent, **options)
            @grid = Sequence::Duration.whole_notes(grid)
            raise ArgumentError, "Quantize amount must be from 0 to 1 (got #{amount.inspect})" unless amount.is_a?(Numeric) && amount.between?(0, 1)
            @amount = Sequence::Duration.rational(amount)
            @window = window && Sequence::Duration.whole_notes(window)
            @grid_label = grid.is_a?(Integer) ? "n#{grid}" : grid.to_s
            @node_type_name = "quantize(#{@grid_label}#{", amount: #{amount}" if amount != 1})"
          end

          private

          def tail_seconds
            @grid / transport.whole_notes_per_second
          end

          def map_on(e)
            wn = timeline_at(e.time)
            target = (wn / @grid).ceil * @grid
            return [[e, 0r]] if @window && target - wn > @window

            delay = (stream_time_at(target) - e.time) * @amount
            [[e, MB::M.max(delay, 0r)]]
          end

          def map_note(event)
            event
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
