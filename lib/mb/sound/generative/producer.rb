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

        # This producer with +fn+ (called with a cycle's Events and the
        # cycle number, returning Events) applied to each cycle's events as
        # a whole (Clip#ratchet, #permute, #ghost_chords, ...).
        def cycle_mapped(fn)
          Mapped.new(self, cycle: fn)
        end
      end

      # A producer's events through an event map (see Producer#mapped) or
      # a per-cycle list map (Producer#cycle_mapped).
      class Mapped
        include Producer

        # The producer this one maps.
        attr_reader :inner

        def initialize(inner, map = nil, cycle: nil)
          raise ArgumentError, 'Give an event map or a cycle map' unless map.nil? != cycle.nil?
          @inner = inner
          @map = map
          @cycle = cycle
        end

        def events(cycle)
          list = @inner.events(cycle)
          list = @cycle ? @cycle.call(list, cycle) : list.map(&@map)
          list.sort_by(&:start).freeze
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
