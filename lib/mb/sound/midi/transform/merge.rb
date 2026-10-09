module MB
  module Sound
    module MIDI
      class Transform
        # Interleaves the events of several streams in time order (see
        # Stream#merge).  Each input stays balanced on its own; notes on the
        # same key from different inputs overlap (an Allocator gives each
        # its own voice).
        class Merge < Transform

          # The Streams merged.
          attr_reader :inputs

          def initialize(streams)
            raise ArgumentError, 'Merge at least two streams' if streams.length < 2
            @inputs = streams.map { |s| Stream.for(s) }.freeze
            @readers = @inputs.map(&:reader)
            @position = @readers.map(&:cursor).max
            @node_type_name = "merge(#{@inputs.length})"
          end

          # The sum of the inputs' generations, so a jump in any input is a
          # jump of the merged stream.
          def generation
            @inputs.sum(&:generation)
          end

          def seek(time)
            @inputs.each { |s| s.seek(time) }
            self
          end

          def restart
            @inputs.each(&:restart)
            self
          end

          def ended?
            @readers.all?(&:ended?)
          end

          # Merged streams don't chase notes (see Source#chase).
          def chase
            nil
          end

          def first_note
            @inputs.map(&:first_note).compact.min_by(&:time)
          end

          def music_end
            ends = @inputs.map(&:music_end)
            ends.include?(nil) ? nil : ends.max
          end

          def sources
            @inputs.each_with_index.to_h { |s, i| [:"input_#{i + 1}", s] }
          end

          private

          def balance_notes?
            false
          end

          def read_events(from, to)
            lists = @readers.map { |r| r.events(from, to) }
            return Stream::NO_EVENTS if lists.all?(&:empty?)

            lists.each_with_index.flat_map { |list, i| list.each_with_index.map { |e, j| [e.time, i, j, e] } }.sort.map(&:last)
          end
        end
      end
    end
  end
end
