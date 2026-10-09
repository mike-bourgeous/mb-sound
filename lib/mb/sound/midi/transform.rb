module MB
  module Sound
    module MIDI
      # Base class for stream transforms: the Source of a Stream returned by
      # Stream#channel, #transpose, #sustain, #velocity_curve, or
      # #bend_range.  A transform reads its parent stream through its own
      # Reader and processes each event once, in order, for every reader of
      # the stream it feeds, so transforms may keep state (like held
      # sustain notes) without being run twice.
      #
      # Seeking or restarting a transformed stream seeks or restarts the
      # root source.  When the parent's content jumps (its #generation
      # changes), #jump is called so stateful transforms can let go of
      # notes.
      #
      # Subclasses implement #process(events, from, to), returning the
      # output events for one read.
      class Transform
        include Source

        # The Stream this transform reads.
        attr_reader :parent

        def initialize(parent)
          @parent = parent
          @input = parent.reader
          @position = @input.cursor
          @seen_generation = parent.generation
        end

        # The parent's generation (content jumps happen at the root source).
        def generation
          @parent.generation
        end

        def seek(time)
          @parent.seek(time)
          self
        end

        def restart
          @parent.restart
          self
        end

        # True once the parent has ended and this transform has nothing
        # left to send.
        def ended?
          @input.ended?
        end

        def music_end
          @parent.music_end
        end

        # The parent's Source#chase, with its note passed through this
        # transform (nil if the transform drops it).
        def chase
          c = @parent.chase
          note = c && map_note(c.event)
          note && c.with(event: note)
        end

        # The parent's Source#first_note, passed through this transform.
        def first_note
          note = @parent.first_note
          note && map_note(note)
        end

        def sources
          { input: @parent }
        end

        def to_s
          node_type_name
        end

        private

        def balance_notes?
          false
        end

        def read_events(from, to)
          events = @input.events(from, to)

          # Nothing to transform (every #process is a function of its
          # events): a shared frozen empty Array instead of new ones
          return Stream::NO_EVENTS if events.empty? && @parent.generation == @seen_generation

          out = []

          if @parent.generation != @seen_generation
            @seen_generation = @parent.generation
            out.concat(jump(from))
          end

          out.concat(process(events, from, to))
        end

        # Called when the parent's content jumped, before the events of the
        # read at +from+ seconds; returns events to send at +from+ (e.g.
        # note-offs for held notes).
        def jump(from)
          []
        end

        # Returns the transformed events for a read of [from, to).
        def process(events, from, to)
          raise NotImplementedError, "#{self.class} must implement #process"
        end

        # Returns a chased or first note (see #chase and #first_note) as this
        # transform would send it, or nil to drop it.  Unchanged by default
        # (e.g. for stateful transforms like Sustain); stateless transforms
        # run it through #process.
        def map_note(event)
          event
        end

        # A #map_note for stateless transforms.
        def process_note(event)
          process([event], event.time, event.time).first
        end

        # Keeps events on some channels (see Stream#channel).
        class Channel < Transform
          def initialize(parent, channels)
            super(parent)
            list = channels.is_a?(Integer) ? [channels] : channels.to_a
            unless !list.empty? && list.all? { |c| c.is_a?(Integer) && c.between?(0, 15) }
              raise ArgumentError, "MIDI channels are Integers from 0 to 15 (got #{channels.inspect})"
            end

            @channels = list.uniq.sort.freeze
            @node_type_name = "channel(#{channels.inspect})"
          end

          private

          def process(events, _from, _to)
            events.select { |e| e.channel.nil? || @channels.include?(e.channel) }
          end

          alias map_note process_note
        end

        # Shifts note numbers (see Stream#transpose).
        class Transpose < Transform
          def initialize(parent, step, scale: nil, root: nil)
            super(parent)
            @steps = Steps.new(step, scale: scale, root: root)
            @semitones = @steps.scale.chromatic? ? @steps.degrees + @steps.semitones : nil
            @node_type_name = @steps.scale.chromatic? ? "transpose(#{step})" : "transpose(#{step}, scale: #{@steps.scale})"
          end

          private

          # Glide events name a note too (see Event.glide).
          def process(events, _from, _to)
            events.map { |e|
              next e unless e.note? || e.type == :poly_pressure || (e.type == :glide && e.note)
              note = @semitones ? Sequence.transpose_value(e.note, @semitones) : @steps.apply(e.note)
              e.with_note(Transpose.whole(note))
            }
          end

          alias map_note process_note

          # Returns +value+ as an Integer if it's a whole Rational or Float,
          # so transposed notes keep their MIDI bytes.
          def self.whole(value)
            (value.is_a?(Rational) || value.is_a?(Float)) && value.finite? && value == value.round ? value.round : value
          end
        end

        # Applies sustain, sostenuto, and soft pedals (see Stream#sustain).
        class Sustain < Transform
          # The note-on velocity multiplier while the soft pedal is down.
          SOFT_VELOCITY = 0.7

          # The pedals this transform responds to (switches at 64 and up),
          # for MIDI::ControlMap (see Synth#control_specs).
          CONTROL_SPECS = [
            ControlSpec.new(number: 64, name: 'Sustain', curve: :switch, description: 'Sustain pedal'),
            ControlSpec.new(number: 66, name: 'Sostenuto', curve: :switch, description: 'Holds the notes down when pressed'),
            ControlSpec.new(number: 67, name: 'Soft Pedal', curve: :switch, description: 'Softer note-on velocities'),
          ].each(&:freeze).freeze

          def initialize(parent, soft: SOFT_VELOCITY)
            super(parent)
            @soft = soft.to_f
            @channels = Array.new(16) { new_channel }
            @node_type_name = 'sustain'
          end

          # True if any note-offs are held by a pedal.
          def holding?
            @channels.any? { |c| !c[:held].empty? }
          end

          # Once the input has ended, held notes are let go (see #process),
          # so this ends with it.
          def ended?
            super && !holding?
          end

          private

          def new_channel
            {
              sustain: false,
              sostenuto: false,
              soft: false,
              keys: {},        # note => true for keys that are down
              held: {},        # note => held note-off Event
              sostenuto_notes: {}, # note => true for notes caught by sostenuto
            }
          end

          def process(events, from, to)
            out = []

            events.each do |e|
              ch = e.channel
              state = ch && ch < 16 ? @channels[ch] : nil

              unless state
                out << e
                next
              end

              case e.type
              when :note_on
                if (held = state[:held].delete(e.note))
                  out << held.at(e.time)
                end
                state[:keys][e.note] = true
                e = e.with_velocity(e.velocity * @soft) if state[:soft]
                out << e

              when :note_off
                state[:keys].delete(e.note)
                if state[:sustain] || (state[:sostenuto] && state[:sostenuto_notes][e.note])
                  state[:held][e.note] = e
                else
                  out << e
                end

              when :cc
                out << e
                case e.note
                when 64
                  down = e.raw >= 64
                  if state[:sustain] && !down
                    state[:sustain] = false
                    release(state, e.time, out) { |note| !state[:sostenuto_notes][note] }
                  end
                  state[:sustain] = down

                when 66
                  down = e.raw >= 64
                  if down && !state[:sostenuto]
                    state[:sostenuto_notes] = (state[:keys].keys | state[:held].keys).to_h { |n| [n, true] }
                  elsif !down && state[:sostenuto]
                    state[:sostenuto] = false
                    notes = state[:sostenuto_notes]
                    state[:sostenuto_notes] = {}
                    release(state, e.time, out) { |note| notes[note] } unless state[:sustain]
                  end
                  state[:sostenuto] = down

                when 67
                  state[:soft] = e.raw >= 64

                when 120
                  release(state, e.time, out)

                when 121
                  state[:sustain] = state[:sostenuto] = state[:soft] = false
                  state[:sostenuto_notes] = {}
                  release(state, e.time, out)
                end

              else
                out << e
              end
            end

            # Let go of held notes when the music is over, so they don't hang
            release_all(MB::M.max(from, events.last&.time || from), out) if @input.ended?

            out
          end

          # Lets go of held notes at a jump (seek, restart, or clip swap).
          def jump(from)
            out = []
            release_all(from, out)
            @channels.each do |c|
              c[:keys].clear
              c[:sostenuto_notes] = {}
              c[:sustain] = c[:sostenuto] = c[:soft] = false
            end
            out
          end

          def release_all(time, out)
            @channels.each do |c| release(c, time, out) end
          end

          # Sends the held note-offs (those for which the block returns true,
          # or all of them) at +time+.
          def release(state, time, out)
            state[:held].delete_if do |note, off|
              next false if block_given? && !yield(note)
              out << off.at(time)
              true
            end
          end
        end

        # Keeps the note events of some note numbers (see Stream#keys).
        class Keys < Transform
          def initialize(parent, notes)
            super(parent)
            number = ->(n) {
              n = n.number if n.respond_to?(:number) && !n.is_a?(Numeric)
              raise ArgumentError, "Keys are note numbers, Ranges, or Notes (got #{n.inspect})" unless n.is_a?(Numeric)
              n
            }
            list = Array(notes).flatten.flat_map { |n|
              n.is_a?(Range) ? (number.(n.begin).to_i..number.(n.end).to_i).to_a : [number.(n)]
            }
            raise ArgumentError, 'Give at least one key' if list.empty?

            @keys = list.uniq.sort.freeze
            @key_set = @keys.to_h { |k| [k, true] }.freeze
            @node_type_name = "keys(#{@keys.join(', ')})"
          end

          # The note numbers kept.
          attr_reader :keys

          private

          # Note-ons, note-offs, poly pressure, and glides naming a note keep
          # only the listed notes; channel-wide events pass through.
          def process(events, _from, _to)
            events.select { |e|
              note_specific = e.note? || e.type == :poly_pressure || (e.type == :glide && e.note)
              !note_specific || @key_set.key?(e.note)
            }
          end

          alias map_note process_note
        end

        # Shapes note-on velocities (see Stream#velocity_curve).
        class VelocityCurve < Transform
          def initialize(parent, curve)
            super(parent)
            if curve.is_a?(Numeric)
              raise ArgumentError, "A velocity curve exponent must be positive (got #{curve})" unless curve > 0
              exponent = curve
              @curve = ->(v) { v ** exponent }
              @node_type_name = "velocity_curve(#{curve})"
            elsif curve.respond_to?(:call)
              @curve = curve
              @node_type_name = 'velocity_curve(proc)'
            else
              raise ArgumentError, "Expected an exponent or a block for the velocity curve (got #{curve.inspect})"
            end
          end

          private

          def process(events, _from, _to)
            events.map { |e|
              next e unless e.note_on?
              e.with_velocity(MB::M.clamp(@curve.call(e.velocity).to_f, 0.0, 1.0))
            }
          end

          alias map_note process_note
        end

        # Sets the default bend range (see Stream#bend_range).
        class BendRange < Transform
          def initialize(parent, interval)
            super(parent)
            @tracker = Stream::BendTracker.new(Interval.semitones(interval))
            @node_type_name = "bend_range(#{interval})"
          end

          private

          def process(events, _from, _to)
            events.map { |e| @tracker.process(e) }
          end
        end
      end
    end
  end
end
