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
        end

        # Shifts note numbers (see Stream#transpose).
        class Transpose < Transform
          def initialize(parent, interval)
            super(parent)
            @semitones = Interval.semitones(interval)
            @node_type_name = "transpose(#{interval})"
          end

          private

          def process(events, _from, _to)
            events.map { |e|
              next e unless e.note? || e.type == :poly_pressure
              e.with_note(Transpose.whole(Sequence.transpose_value(e.note, @semitones)))
            }
          end

          # Returns +value+ as an Integer if it's a whole Rational or Float,
          # so transposed notes keep their MIDI bytes.
          def self.whole(value)
            (value.is_a?(Rational) || value.is_a?(Float)) && value.finite? && value == value.round ? value.round : value
          end
        end
      end
    end
  end
end
