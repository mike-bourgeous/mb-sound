module MB
  module Sound
    module MIDI
      class Transform
        # An arpeggiator: plays the held keys one at a time on a musical
        # grid (see Stream#arp).
        #
        # Clock (user decision 6, 2026-10-09): by default (+start: :grid+)
        # steps fall on the timeline grid (multiples of +rate+ from the
        # session timeline's start), so arpeggios stay in phase with clips
        # and bars and follow tempo changes and seeks; a key pressed between
        # steps waits for the next step (a quantized start, decision 7).
        # +start: :key+ starts the clock at the first key pressed while
        # nothing was held, Juno-style, then steps every +rate+ from there.
        #
        # Pattern: the held notes (sorted by pitch, or in the order played
        # for :played), copied +octaves+ times, each copy moved by +step+
        # (an octave by default; scale degrees or an Interval), read in the
        # order of +mode+.  The position in the pattern keeps counting as
        # keys are added or released, and starts over when a key is pressed
        # with nothing held.  +steps:+ adds a pitch offset per step (an
        # Array cycled, in degrees of +scale:+ or Intervals), e.g. [0, 0, 12, 7].
        #
        # Notes last +gate+ of a step (1 is legato, more overlaps).
        # Velocity is the key's (+velocity: nil+), a number, or an Array of
        # factors cycled per step (accents).  +swing:+ (0.5 straight, 0.66
        # triplet feel) delays every other step.  +latch: true+ keeps
        # playing the last keys after they are released, until a key is
        # pressed with nothing held.  When the input ends, the arp stops
        # (latched notes included), so renders end.
        #
        # Input notes are consumed (only arpeggiated notes go out); other
        # events pass through.  Output notes go through the Scheduled ledger
        # (+:overlap+, +:jump+).
        class Arp < Scheduled
          include Seeded

          # Arpeggio modes (see Stream#arp).
          MODES = [
            :up, :down, :updown, :downup, :up_down, :down_up, :played, :random,
            :converge, :diverge, :pinky, :thumb, :chord,
          ].freeze

          # Clock starts (see the class description).
          STARTS = [:grid, :key].freeze

          # The step length in whole notes.
          attr_reader :rate

          # The mode (see MODES).
          attr_reader :mode

          def initialize(parent, mode = :up, rate = 16, octaves: 1, step: 12, gate: 0.5, velocity: nil,
            swing: 0.5, latch: false, start: :grid, steps: nil, scale: nil, root: nil, seed: nil, **options)
            super(parent, **options)

            raise ArgumentError, "Arp mode must be one of #{MODES.map(&:inspect).join(', ')} (got #{mode.inspect})" unless MODES.include?(mode)
            raise ArgumentError, "Arp start must be one of #{STARTS.map(&:inspect).join(', ')} (got #{start.inspect})" unless STARTS.include?(start)
            raise ArgumentError, "Arp octaves must be a positive Integer (got #{octaves.inspect})" unless octaves.is_a?(Integer) && octaves > 0
            raise ArgumentError, "Arp gate must be positive (got #{gate.inspect})" unless gate.is_a?(Numeric) && gate > 0
            raise ArgumentError, "Arp swing must be from 0 to 1 (exclusive; got #{swing.inspect})" unless swing.is_a?(Numeric) && swing > 0 && swing < 1

            @mode = mode
            @rate = Sequence::Duration.whole_notes(rate)
            @rate_label = rate.is_a?(Integer) ? "n#{rate}" : rate.to_s
            @scale = Scale[scale, root]
            @octave_step = Steps.new(step, scale: @scale)
            @octaves = octaves
            @gate = Sequence::Duration.rational(gate)
            @velocity = velocity
            @swing = Sequence::Duration.rational(swing)
            @latch = latch
            @start = start
            @offsets = steps && Array(steps).map { |s| Steps.new(s, scale: @scale) }
            raise ArgumentError, 'Arp steps: needs at least one offset' if @offsets && @offsets.empty?
            setup_seed(seed)

            @held = []      # [event] for keys down, in the order pressed
            @latched = []   # [event] still playing after release (latch)
            @index = 0      # steps played since the pattern started
            @origin = nil   # timeline position of step 0 (start: :key)
            @next_step = nil # the next step's timeline position, or nil when idle

            parts = [mode.inspect, @rate_label]
            parts << "octaves: #{octaves}" if octaves != 1
            parts << "gate: #{gate}" if gate != 0.5
            parts << "swing: #{swing}" if swing != 0.5
            parts << 'latch: true' if latch
            parts << 'start: :key' if start == :key
            parts << "steps: #{Array(steps).map(&:to_s).join(', ')}" if steps
            parts << "scale: #{@scale}" unless @scale.chromatic?
            @node_type_name = "arp(#{parts.join(', ')})"
          end

          # The notes the arpeggiator is playing from (held or latched), in
          # pattern order before octaves (see the class description).
          def notes
            base_notes.map(&:note)
          end

          def ended?
            super && @held.empty?
          end

          private

          def tail_seconds
            @rate * (@gate + 1) / transport.whole_notes_per_second
          end

          def process(events, from, to)
            idx = 0
            loop do
              step = next_step(from)
              if step && step[1] < to
                # Input events up to (and at) the step come first
                while idx < events.length && events[idx].time <= step[1]
                  input(events[idx])
                  idx += 1
                end

                # They may have stopped or restarted the clock
                if next_step(from) == step
                  play_step(*step)
                  @next_step = step[0] + @rate
                end
              else
                break if idx >= events.length
                input(events[idx])
                idx += 1
              end
            end

            if @input.ended?
              @held.clear
              @latched.clear
              @next_step = nil
            end
          end

          # [timeline position, stream time] of the next step, or nil if
          # nothing is playing.
          def next_step(from)
            wn = next_step_at(from)
            wn && [wn, stream_time_at(swung(wn))]
          end

          # The timeline position of the next step at or after stream time
          # +from+, or nil if nothing is playing.
          def next_step_at(from)
            return nil if base_notes.empty?
            return @next_step if @next_step

            now = timeline_at(from)
            @next_step = if @start == :key && @origin
                           @origin + ((now - @origin) / @rate).ceil * @rate
                         else
                           (now / @rate).ceil * @rate
                         end
          end

          # Every other step is late by the swing (0.5 = straight).
          def swung(step_wn)
            return step_wn if @swing == 1/2r
            phase = @start == :key && @origin ? step_wn - @origin : step_wn
            ((phase / @rate).round.odd?) ? step_wn + (@swing - 1/2r) * 2 * @rate : step_wn
          end

          def input(e)
            case e.type
            when :note_on
              if @held.empty?
                # A new phrase: forget latched keys, start the pattern over
                @latched.clear
                @index = 0
                now = timeline_at(e.time)
                if @start == :key
                  @origin = now
                  @next_step = now
                else
                  @next_step = (now / @rate).ceil * @rate
                end
              end
              @held.reject! { |h| h.channel == e.channel && h.note == e.note }
              @held << e

            when :note_off
              idx = @held.index { |h| h.channel == e.channel && h.note == e.note }
              if idx
                released = @held.delete_at(idx)
                if @latch
                  @latched.reject! { |h| h.channel == released.channel && h.note == released.note }
                  @latched << released
                end
              end
              @latched = [] if !@latch
              @next_step = nil if base_notes.empty?

            when :poly_pressure
              # consumed with the notes

            else
              schedule(e)
            end
          end

          # Held keys, or latched keys once all are released.
          def base_notes
            return @held unless @held.empty?
            @latched
          end

          # The pattern for this step: an Array of [note, velocity, channel].
          def pattern
            keys = base_notes
            keys = keys.sort_by.with_index { |e, i| [e.note.to_f, i] } unless @mode == :played

            list = []
            @octaves.times do |o|
              shift = @octave_step * o
              keys.each do |k|
                n = Transpose.whole(shift.apply(k.note))
                list << [n, k.velocity, k.channel] unless n.is_a?(Numeric) && !n.between?(0, 127)
              end
            end
            list
          end

          def order(list)
            n = list.length
            case @mode
            when :up, :played, :random, :chord then list
            when :down then list.reverse
            when :updown then n > 2 ? list + list[1...-1].reverse : list
            when :downup then n > 2 ? list.reverse + list[1...-1] : list.reverse
            when :up_down then list + list.reverse
            when :down_up then list.reverse + list
            when :converge then Array.new(n) { |i| i.even? ? list[i / 2] : list[n - 1 - i / 2] }
            when :diverge then Array.new(n) { |i| i.even? ? list[i / 2] : list[n - 1 - i / 2] }.reverse
            when :pinky then n > 1 ? list[0...-1].flat_map { |x| [x, list[-1]] } : list
            when :thumb then n > 1 ? list[1..].flat_map { |x| [list[0], x] } : list
            end
          end

          def play_step(step_wn, step_time)
            list = order(pattern)
            return if list.empty?

            chosen = case @mode
                     when :chord then list
                     when :random then [list[next_random.rand(list.length)]]
                     else [list[@index % list.length]]
                     end

            offset = @offsets && @offsets[@index % @offsets.length]
            length = (stream_time_at(swung(step_wn + @rate)) - step_time)
            length = @rate / transport.whole_notes_per_second if length <= 0
            off_time = step_time + length * @gate

            chosen.each do |note, velocity, channel|
              note = Transpose.whole(offset.apply(note)) if offset
              next if note.is_a?(Numeric) && !note.between?(0, 127)

              v = step_velocity(velocity)
              id = schedule_on(Event.note_on(note, v, channel: channel, time: step_time))
              schedule_off(Event.note_off(note, channel: channel, time: off_time), id)
            end

            @index += 1
          end

          def step_velocity(played)
            v = case @velocity
                when nil then played
                when Array then played * @velocity[@index % @velocity.length]
                else @velocity
                end
            MB::M.clamp(v.to_f, 1 / 127.0, 1.0)
          end

          # A content jump: the source's note-offs release the keys (as
          # usual); a timeline jump re-phases the grid (computed from the
          # timeline at each step), and moves a key-started clock with the
          # jump.
          def timeline_jumped(time, old)
            @origin += time - old if @origin && old
            @next_step = nil
          end

          def cut_state
            @held.clear
            @latched.clear
            @next_step = nil
          end
        end
      end
    end
  end
end
