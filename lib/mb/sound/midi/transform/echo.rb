module MB
  module Sound
    module MIDI
      class Transform
        # Repeats notes later in time, each repeat moved in pitch and
        # scaled in velocity, so a few notes can build an arpeggio (see
        # Stream#echo).  Graduated from the research prototype
        # (research-midi-transforms).
        #
        # Each played note-on schedules +count+ repeats, +delay+ apart
        # (seconds, a Length, or a Duration read at the tempo of the
        # played note-on, so a tempo change doesn't move echoes already
        # scheduled; an Array of them is cycled, each the gap before the
        # next repeat, so `[3.n32, 5.n32]` lands repeats 3, 8, 11, 16, ...
        # thirty-seconds after the note; gen-ux-1).  Repeat i is moved by the sum of the first i +pitch+
        # steps (scale degrees of +scale+, chromatic by default, or
        # Intervals; an Array is cycled: `[4, 3, 5]` climbs a major triad)
        # and has the played velocity times +velocity+ ** i.  Repeats under
        # +floor+ (1/127) or outside 0..127 end the chain.
        #
        # Note lengths (user decision 3): each repeat is as long as the
        # played note (its note-off is scheduled when the played note-off
        # arrives, with the delay of its note-on), unless +gate:+ is given
        # (a fraction of the delay, or a Length).  Same-key overlaps and
        # jumps follow +overlap:+ and +jump:+ (see Scheduled).
        class Echo < Scheduled
          # Echoes quieter than this (normalized velocity) are dropped.
          FLOOR = 1 / 127r

          # The delay between repeats (seconds, a Length, or a Duration), or
          # an Array of them (gaps, cycled).
          attr_reader :delay

          # The number of repeats after the played note.
          attr_reader :count

          # The Scale for pitch steps.
          attr_reader :scale

          def initialize(parent, delay, count = 3, pitch: 0, velocity: 1, gate: nil, dry: true,
            scale: nil, root: nil, floor: FLOOR, overlap: :retrigger, jump: :ring, transport: nil, &block)
            super(parent, overlap: overlap, jump: jump, transport: transport)

            raise ArgumentError, "Echo count must be a non-negative Integer (got #{count.inspect})" unless count.is_a?(Integer) && count >= 0
            gaps = delay.is_a?(Array) ? delay : [delay]
            raise ArgumentError, 'An echo delay Array needs at least one gap' if gaps.empty?
            gaps.each do |g|
              raise ArgumentError, "An echo delay can't be negative (got #{g.is_a?(Length) ? g : g.inspect})" if seconds_of(g) < 0
            end
            unless gate.nil? || (gate.is_a?(Numeric) && gate > 0) || gate.is_a?(Length)
              raise ArgumentError, "Echo gate must be nil, a positive fraction of the delay, or a Length (got #{gate.inspect})"
            end
            raise ArgumentError, "Echo velocity must be a non-negative number (got #{velocity.inspect})" unless velocity.is_a?(Numeric) && velocity >= 0

            @delay = delay
            @gaps = gaps.freeze
            @count = count
            @scale = Scale[scale, root]
            steps = pitch.is_a?(Array) ? pitch : [pitch]
            raise ArgumentError, 'Echo pitch needs at least one step' if steps.empty?
            @steps = steps.map { |p| Steps.new(p, scale: @scale) }.freeze
            @cycle = @steps.reduce(:+)
            @pitch = pitch
            @velocity = velocity.to_f
            @gate = gate
            @dry = dry
            @floor = floor
            @block = block

            @chains = {} # [channel, played note] => Array of [delay, chain] (oldest first)

            @node_type_name = describe
          end

          private

          def describe
            parts = [@delay.is_a?(Array) ? "[#{@delay.join(', ')}]" : @delay.to_s, @count.to_s]
            parts << "pitch: #{@pitch.is_a?(Array) ? "[#{@pitch.join(', ')}]" : @pitch}" unless @pitch == 0
            parts << "velocity: #{MB::M.sigfigs(@velocity, 3)}" unless @velocity == 1
            parts << "gate: #{@gate}" if @gate
            parts << "scale: #{@scale}" unless @scale.chromatic?
            parts << 'dry: false' unless @dry
            parts << "overlap: #{@overlap.inspect}" unless @overlap == :retrigger
            parts << 'jump: :cut' if @jump_mode == :cut
            "echo(#{parts.join(', ')})"
          end

          def tail_seconds
            offsets.last
          end

          # The time of each repeat after its note (seconds; index 0 is the
          # note itself), at the current tempo.
          def offsets
            t = 0r
            [0r] + Array.new(@count) { |i| t += seconds_of(@gaps[i % @gaps.length]) }
          end

          def input_event(e)
            case e.type
            when :note_on then note_on(e)
            when :note_off then note_off(e)
            else schedule(e)
            end
          end

          # Schedules the played note (if dry) and its echoes.
          def note_on(e)
            offs = offsets
            chain = []

            add_note(e, 0, offs, chain) if @dry
            (1..@count).each do |i|
              echo = echo_event(e, i)
              break unless echo # out of range or too quiet: the rest would be too
              echo = @block.call(echo, i) if @block
              next unless echo
              add_note(echo.at(e.time + offs[i]), i, offs, chain)
            end

            (@chains[[e.channel, e.note]] ||= []) << [offs, chain]
          end

          # Schedules the note-offs of the oldest chain started by this key.
          def note_off(e)
            key = [e.channel, e.note]
            list = @chains[key]
            offs, chain = list&.shift
            @chains.delete(key) if list && list.empty?
            return unless chain

            # The offsets of the note-on, so a tempo change can't move an
            # echo's note-off before its note-on
            chain.each do |note, channel, id, i, gated|
              next if gated
              schedule_off(Event.note_off(note, e.velocity, channel: channel, time: e.time + offs[i]), id)
            end
          end

          # (+offs+: the repeat offsets, see #offsets; a gate fraction is of
          # the gap before repeat +index+)
          def add_note(event, index, offs, chain)
            gated = @gate && index > 0
            d = gated ? offs[index] - offs[index - 1] : nil
            # Ungated echoes keep the played note's hint (with_note copies it)
            event = event.with_length_hint(gate_seconds(d)) if gated
            id = schedule_on(event)
            schedule_off(Event.note_off(event.note, channel: event.channel, time: event.time + gate_seconds(d)), id) if gated
            chain << [event.note, event.channel, id, index, gated]
          end

          def gate_seconds(d)
            @gate.is_a?(Length) ? seconds_of(@gate) : d * Sequence::Duration.rational(@gate)
          end

          # The +i+th echo of +e+, or nil if it falls outside 0..127 or under
          # the velocity floor.
          def echo_event(e, i)
            v = e.velocity * @velocity ** i
            return nil if v < @floor

            full, rest = i.divmod(@steps.length)
            step = @cycle * full
            @steps.first(rest).each { |s| step += s }

            note = Transpose.whole(step.apply(e.note))
            return nil if note.is_a?(Numeric) && !note.between?(0, 127)

            e.with_note(note).with_velocity(MB::M.clamp(v.to_f, 0.0, 1.0))
          end

          def cut_state
            @chains.clear
          end
        end
      end
    end
  end
end
