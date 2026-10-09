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
            @chains = {} # [channel, played note] => Array of chains, each an Array of [note, channel, id, delay]
          end

          private

          def input_event(e)
            case e.type
            when :note_on then note_on(e)
            when :note_off then note_off(e)
            when :poly_pressure then poly_pressure(e)
            else
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
              id = schedule_on(out)
              if @length
                schedule_off(Event.note_off(out.note, channel: out.channel, time: out.time + length_seconds), id)
              end
              [out.note, out.channel, id, delay]
            }
            (@chains[[e.channel, e.note]] ||= []) << chain
          end

          def note_off(e)
            key = [e.channel, e.note]
            list = @chains[key]
            chain = list&.shift
            @chains.delete(key) if list && list.empty?
            return unless chain && !@length

            chain.each do |note, channel, id, delay|
              schedule_off(Event.note_off(note, e.velocity, channel: channel, time: e.time + delay), id)
            end
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
            first = map_on(event).first
            first && first[0]
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
          ALIASES = { major: :maj, minor: :min, m: :min, m7: :min7, '7': :dom7, '9': :dom9, half_dim: :min7b5, m9: :min9, m11: :min11 }.freeze

          def initialize(parent, steps, scale: nil, root: nil, velocity: 1, **options)
            super(parent, **options)
            if steps.length == 1 && (steps[0].is_a?(Symbol) || steps[0].is_a?(String))
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
            raise ArgumentError, "Delay must not be negative (got #{delay})" if seconds_of(delay) < 0
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
