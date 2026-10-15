module MB
  module Sound
    module Generative
      # Something that makes a clip's events per cycle (a Generator, or a
      # Mapped generator): the +block+ of a Sequence::Clip::Variation that
      # replaces the clip's events instead of changing them.  Clip#map_clip
      # (transpose, legato, reverse, ...) wraps producers with its event map
      # (#mapped), so a transposed generator clip plays transposed notes.
      module Producer
        # The Clip::Variation protocol: the events of +cycle+.
        def call(_events, cycle, _clip)
          events(cycle)
        end

        # This producer with +map+ (an Event => Event Proc) applied to every
        # event.
        def mapped(map)
          Mapped.new(self, map)
        end
      end

      # A producer's events through an event map (see Producer#mapped).
      class Mapped
        include Producer

        # The producer this one maps.
        attr_reader :inner

        def initialize(inner, map)
          @inner = inner
          @map = map
        end

        def events(cycle)
          @inner.events(cycle).map(&@map).sort_by(&:start).freeze
        end

        # The Generator at the bottom of the chain.
        def generator
          @inner.is_a?(Mapped) ? @inner.generator : @inner
        end

        def name
          @inner.name
        end

        def reach_cycles
          @inner.reach_cycles
        end

        def to_s
          name
        end
      end
    end
  end
end
