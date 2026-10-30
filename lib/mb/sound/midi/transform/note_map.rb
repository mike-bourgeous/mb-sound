module MB
  module Sound
    module MIDI
      class Transform
        # Base class for transforms that turn each played note into zero or
        # more output notes, each at a fixed delay (0 or later) from the
        # played note: filters (#select, #reject), maps (#map_notes,
        # #snap, #rechannel), chords, humanize, input quantize, and fixed
        # note lengths.  The played note's note-off ends its outputs, each
        # after its own delay, so outputs keep the played length (or get
        # +length+), and the Scheduled ledger keeps everything balanced
        # (see Scheduled for +:overlap+ and +:jump+).
        #
        # Subclasses implement #map_on(event) returning an Array of
        # [event, delay] pairs (delay in Rational seconds >= 0; the event's
        # time is the played time), and may override #map_other for
        # non-note events (passed through at their time by default).  Poly
        # pressure follows the newest outputs of its key.
        class NoteMap < Scheduled
          def initialize(parent, length: nil, **options)
            super(parent, **options)
            @length = length
            @chains = {} # [channel, played note] => Array of chains, each an Array of [note, channel, id, delay, played time, planned]
            # Subclasses that move note-offs recompute length hints
            @moves_offs = method(:note_off_time).owner != NoteMap
          end

          private

          def input_event(e)
            case e.type
            when :note_on then note_on(e)
            when :note_off then note_off(e)
            when :poly_pressure then poly_pressure(e)
            else
              @reading.observe(e) if e.type == :cc
              other = map_other(e)
              schedule(other) if other
            end
          end

          # Returns a non-note event as it should go out (or nil to drop it).
          def map_other(event)
            event
          end

          # Returns [[event, delay], ...] for a played note-on (see the class
          # description).
          def map_on(event)
            [[event, 0r]]
          end

          def note_on(e)
            chain = map_on(e).map { |out, delay|
              out = out.at(e.time + delay)
              planned = !@length && planned_length(out)
              out = out.with_length_hint(output_hint(out, e, delay, planned))
              id = schedule_on(out)
              if @length
                schedule_off(Event.note_off(out.note, channel: out.channel, time: out.time + length_seconds), id)
              elsif planned
                schedule_off(Event.note_off(out.note, channel: out.channel, time: out.time + planned), id)
              end
              [out.note, out.channel, id, delay, e.time, planned]
            }
            (@chains[[e.channel, e.note]] ||= []) << chain
          end

          def note_off(e)
            key = [e.channel, e.note]
            list = @chains[key]
            chain = list&.shift
            @chains.delete(key) if list && list.empty?
            return unless chain && !@length

            chain.each do |note, channel, id, delay, on_time, planned|
              # A planned note-off went out at note-on; an earlier played
              # note-off still ends the note (the ledger drops it after)
              time = planned ? e.time + delay : note_off_time(e.time, delay, on_time)
              schedule_off(Event.note_off(note, e.velocity, channel: channel, time: time), id)
            end
          end

          # The length (Rational seconds) of an output note whose note-off
          # is scheduled at its note-on (from its length hint), or nil to end
          # it from the played note-off.  Override (Stream#legato below 1).
          def planned_length(_out)
            nil
          end

          # The Event#length_hint of an output note-on +out+ for played
          # note-on +e+ with +delay+: the fixed length, the +planned+ length,
          # the hint recomputed through #note_off_time for subclasses that
          # move note-offs, or the hint +out+ carries.
          def output_hint(out, e, delay, planned)
            return (@length.is_a?(Sequence::Duration) ? @length : length_seconds) if @length
            return planned if planned

            hint = out.length_hint
            return hint unless hint && @moves_offs

            off = e.time + seconds_of(hint)
            MB::M.max(note_off_time(off, delay, e.time) - out.time, 0r)
          end

          # The time (Rational seconds) of an output note-off for a played
          # note-off at +time+, given its output's +delay+ and the played
          # note-on's +on_time+: +time+ + +delay+ (the played length) by
          # default.  Never earlier than +time+ in subclasses (streams
          # can't look ahead).
          def note_off_time(time, delay, _on_time)
            time + delay
          end

          def poly_pressure(e)
            chain = @chains[[e.channel, e.note]]&.last
            return unless chain

            chain.each do |note, channel, _id, delay|
              out = e.with_channel(channel)
              out = out.with_note(note) unless note == e.note
              schedule(out.at(e.time + delay))
            end
          end

          def length_seconds
            seconds_of(@length)
          end

          def cut_state
            @chains.clear
          end

          # The note-on Event as #map_on would first send it, for Notes'
          # held values after jumps (see Transform#chase).
          def map_note(event)
            # Notes nodes ask for the chased note often after a jump; map
            # each one once (blocks may have side effects)
            return @chased[1] if @chased && @chased[0] == event

            first = map_on(event).first
            @chased = [event, first && first[0]]
            @chased[1]
          end
        end

        # Keeps (or with +reject: true+ drops) the notes for which the block
        # returns true; see Stream#select.
        class Select < NoteMap
          def initialize(parent, reject: false, name: nil, &block)
            raise ArgumentError, 'Pass a block that tests a note-on Event' unless block
            super(parent)
            @block = block
            @reject = reject
            @node_type_name = name || (reject ? 'reject' : 'select')
          end

          private

          def map_on(e)
            keep = !!@block.call(e)
            keep != @reject ? [[e, 0r]] : []
          end
        end

        # Changes each note-on with a block (see Stream#map_notes).
        class MapNotes < NoteMap
          def initialize(parent, name: 'map_notes', &block)
            raise ArgumentError, 'Pass a block that returns an Event, an Array of Events, or nil' unless block
            super(parent)
            @block = block
            @node_type_name = name
          end

          private

          def map_on(e)
            out = @block.call(e)
            Array(out).map { |o|
              raise ArgumentError, "map_notes blocks return note-on Events or nil (got #{o.inspect})" unless o.is_a?(Event) && o.note_on?
              [o, MB::M.max(o.time - e.time, 0r)]
            }
          end
        end

        # Moves every channel message to one channel (see Stream#rechannel).
        class Rechannel < NoteMap
          def initialize(parent, channel)
            super(parent)
            raise ArgumentError, "MIDI channels are Integers from 0 to 15 (got #{channel.inspect})" unless channel.is_a?(Integer) && channel.between?(0, 15)
            @channel = channel
            @node_type_name = "rechannel(#{channel})"
          end

          private

          def map_on(e)
            [[e.with_channel(@channel), 0r]]
          end

          def map_other(e)
            e.with_channel(@channel)
          end
        end

        # Snaps notes to a scale (see Stream#snap).
        class Snap < NoteMap
          def initialize(parent, scale, root: nil, direction: :nearest, **options)
            super(parent, **options)
            @scale = Scale[scale, root]
            @direction = direction
            @scale.snap(60, direction) # validates
            @node_type_name = "snap(#{@scale}#{", #{direction.inspect}" unless direction == :nearest})"
          end

          private

          def map_on(e)
            return [[e, 0r]] unless e.note.is_a?(Numeric)
            [[e.with_note(Transpose.whole(@scale.snap(e.note, @direction))), 0r]]
          end
        end

        # Transposes each note by a step read at its note-on from a param
        # (MIDI::Param: `midi.transpose(seq(0, -4, 3, -2).n1.loop)`,
        # `transpose(knob(:shift))`); its note-off and poly pressure follow
        # the note, so a step that changes while a key is held never leaves
        # a note hanging.  Steps are scale degrees of +:scale+ (semitones by
        # default; fractions are cents only in the chromatic scale), or
        # Intervals; nil (a clip before its first note) is 0.
        class MovingTranspose < NoteMap
          def initialize(parent, step, scale: nil, root: nil, **options)
            super(parent, **options)
            @step = Param.wrap(step, 'Transpose step')
            @scale = scale.is_a?(Scale) && root.nil? ? scale : Scale[scale, root]
            @node_type_name = @scale.chromatic? ? "transpose(#{Param.label(step)})" : "transpose(#{Param.label(step)}, scale: #{@scale})"
          end

          private

          def map_on(e)
            return [[e, 0r]] unless e.note.is_a?(Numeric)

            step = param_at(@step, e.time) || 0
            step = step.number if step.respond_to?(:number) && !step.is_a?(Numeric) # (a clip of notes: semitones from C-1)
            step = step.round if step.is_a?(Float) && !@scale.chromatic?
            [[e.with_note(Transpose.whole(Steps.new(step, scale: @scale).apply(e.note))), 0r]]
          end
        end

        # Maps each note through a MIDI::Lock map (Stream#degrees,
        # Stream#snap without a fixed scale or with :chord, Stream#lock)
        # read at the note's timeline position; note-offs and poly
        # pressure follow the note as it was mapped, so a held note keeps
        # its pitch when the key or chord changes.  Silent keys (nil) play
        # nothing.
        class Locked < NoteMap
          # Options that go to the transform, not the map (Stream#lock).
          OPTIONS = [:overlap, :jump, :transport, :length].freeze

          attr_reader :map

          def initialize(parent, map, **options)
            super(parent, **options)
            @map = map
            @node_type_name = map.to_s
          end

          private

          def map_on(e)
            out = @map.event(e, timeline_at(e.time), transport: transport, stream: @reading)
            out ? [[out, 0r]] : []
          end
        end

        # Adds notes above (or below) each played note (see Stream#chord).
        class Chord < NoteMap
          # Chord shapes in semitones above the root (root included).
          SHAPES = {
            maj: [0, 4, 7], min: [0, 3, 7], dim: [0, 3, 6], aug: [0, 4, 8],
            sus2: [0, 2, 7], sus4: [0, 5, 7], power: [0, 7], fifth: [0, 7, 12], octave: [0, 12],
            maj7: [0, 4, 7, 11], min7: [0, 3, 7, 10], dom7: [0, 4, 7, 10], min7b5: [0, 3, 6, 10], dim7: [0, 3, 6, 9],
            min_maj7: [0, 3, 7, 11], maj6: [0, 4, 7, 9], min6: [0, 3, 7, 9],
            add9: [0, 4, 7, 14], min_add9: [0, 3, 7, 14], maj9: [0, 4, 7, 11, 14], min9: [0, 3, 7, 10, 14], dom9: [0, 4, 7, 10, 14],
            min11: [0, 3, 7, 10, 14, 17], quartal: [0, 5, 10], quintal: [0, 7, 14],
          }.transform_values(&:freeze).freeze

          # Other names for SHAPES.
          ALIASES = {
            major: :maj, minor: :min, m: :min, m7: :min7, '7': :dom7, '9': :dom9, half_dim: :min7b5, m9: :min9, m11: :min11,
            m7b5: :min7b5, '6': :maj6, m6: :min6, M7: :maj7, dom: :dom7,
          }.freeze

          def initialize(parent, steps, scale: nil, root: nil, velocity: 1, **options)
            super(parent, **options)
            if steps.length == 1 && (steps[0].is_a?(Symbol) || steps[0].is_a?(String))
              if scale || root
                raise ArgumentError, "A chord name adds its shape above each played note, so it takes no scale: or root: (a chord on a root as a value: MB::Sound.chord(#{steps[0].inspect}, root: :d))"
              end
              name = steps[0].to_sym
              name = ALIASES.fetch(name, name)
              shape = SHAPES.fetch(name) { raise ArgumentError, "Unknown chord #{steps[0].inspect} (#{SHAPES.keys.join(', ')})" }
              @steps = shape.drop(1).map { |s| Steps.new(Interval.new(s)) }
              @label = steps[0].inspect
            else
              list = steps.flatten
              raise ArgumentError, 'Give a chord name or at least one pitch step' if list.empty?
              @steps = list.reject { |s| s == 0 }.map { |s| Steps.new(s, scale: scale, root: root) }
              @label = list.map(&:to_s).join(', ')
              @label += ", scale: #{Scale[scale, root]}" if scale
            end
            @velocity = velocity.to_f
            @node_type_name = "chord(#{@label})"
          end

          private

          def map_on(e)
            out = [[e, 0r]]
            @steps.each do |s|
              note = Transpose.whole(s.apply(e.note))
              next if note.is_a?(Numeric) && !note.between?(0, 127)
              added = e.with_note(note)
              added = added.with_velocity(MB::M.clamp(e.velocity * @velocity, 0.0, 1.0)) if @velocity != 1
              out << [added, 0r]
            end
            out
          end
        end

        # Fixed note lengths (see Stream#note_length).
        class NoteLength < NoteMap
          def initialize(parent, length, **options)
            seconds_check = Length.seconds(length) rescue nil
            raise ArgumentError, "Note length must be a positive length (got #{length.inspect})" unless length.is_a?(Sequence::Duration) || (seconds_check.is_a?(Numeric) && seconds_check > 0)
            super(parent, length: length, **options)
            @node_type_name = "note_length(#{length})"
          end
        end

        # Delays every event (see Stream#shift).
        class Shift < NoteMap
          def initialize(parent, delay, **options)
            super(parent, **options)
            @delay = delay
            if seconds_of(delay) < 0
              raise ArgumentError, "a live stream can only shift notes later (got #{delay}): it can't play them before they arrive; clips shift both ways (clip.shift(-1.n8))"
            end
            @node_type_name = "shift(#{delay})"
          end

          private

          def tail_seconds
            seconds_of(@delay)
          end

          def map_on(e)
            [[e, seconds_of(@delay)]]
          end

          def map_other(e)
            e.at(e.time + seconds_of(@delay))
          end
        end
      end
    end
  end
end
