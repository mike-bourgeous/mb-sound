module MB
  module Sound
    module Generative
      # Something that makes a clip's events per cycle (a Generator, or a
      # Mapped generator): the +block+ of a Sequence::Clip::Variation that
      # replaces the clip's events instead of changing them.  Clip#map_clip
      # (transpose, legato, reverse, ...) wraps producers with its event map
      # (#mapped), so a transposed generator clip plays transposed notes.
      module Producer
        # The Clip::Variation protocol: the events of +cycle+ (+offset+:
        # whole notes into the cycle, for the unit a steered generator
        # decides; see Generator#events).
        def call(_events, cycle, clip, offset = 0r)
          events(cycle, clip.length, offset)
        end

        # This producer with +map+ (an Event => Event Proc) applied to every
        # event.
        def mapped(map)
          Mapped.new(self, map)
        end

        # This producer with +fn+ (called with a cycle's Events and the
        # cycle number, returning Events) applied to each cycle's events as
        # a whole (Clip#ratchet, #permute, #ghost_chords, ...).
        # +extra_cycles+ is how many cycles past the producer's own reach
        # the map may move events (echo tails, Clip#bake_cycles), so the
        # clip looks back that much further for their notes.
        def cycle_mapped(fn, extra_cycles: 0)
          Mapped.new(self, cycle: fn, extra_cycles: extra_cycles)
        end
      end

      # A producer's events through an event map (see Producer#mapped) or
      # a per-cycle list map (Producer#cycle_mapped).
      class Mapped
        include Producer

        # The producer this one maps.
        attr_reader :inner

        def initialize(inner, map = nil, cycle: nil, extra_cycles: 0)
          raise ArgumentError, 'Give an event map or a cycle map' unless map.nil? != cycle.nil?
          raise ArgumentError, "extra_cycles is a non-negative Integer (got #{extra_cycles.inspect})" unless extra_cycles.is_a?(Integer) && extra_cycles >= 0
          @inner = inner
          @map = map
          @cycle = cycle
          @extra_cycles = extra_cycles
        end

        def events(cycle, clip_length = nil, offset = 0r)
          list = @inner.events(cycle, clip_length, offset)
          list = @cycle ? @cycle.call(list, cycle) : list.map(&@map)
          list.sort_by(&:start).freeze
        end

        # True if the generator reads moving options (see Steer).
        def steered?
          @inner.steered?
        end

        # The decision lead of a steered generator (see Steer), or nil.
        def lead
          @inner.lead
        end

        # The unit length of a steered generator (see Steer), or nil.
        def unit
          @inner.unit
        end

        # The events +cycle+ would have if decided now (Generator#preview).
        def preview(cycle)
          list = @inner.preview(cycle)
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
          @inner.reach_cycles + @extra_cycles
        end

        def to_s
          name
        end
      end
    end
  end
end
