module MB
  module Sound
    class Notes
      # Polyphonic key pressure (poly aftertouch, MIDI 0xA0), 0..1, of the
      # newest held note (see Notes#poly_pressure).  Each key keeps its own
      # pressure; a note-on starts its key at 0, and the output follows the
      # key on top of the note stack (last-note priority, like
      # Notes#number), so in a Synth lane, which holds one note (the
      # Allocator routes each key's pressure to the lane playing it), it is
      # that note's pressure.  After the last key is released the value
      # holds (keyboards usually send 0 before the key-up), and a content
      # jump (seek, swap) chases to 0.
      class PolyPressure < NoteNode
        def initialize(stream, notes: nil, sample_rate: 48000)
          super
          @pressures = {}
          @value = 0.0
          @node_type_name = 'Notes Poly Pressure'
        end

        # The MIDI::ControlSpec of poly pressure (MIDI::ControlSpec.poly_pressure).
        def spec
          MIDI::ControlSpec.poly_pressure
        end

        # [#spec], for MIDI::ControlMap.
        def control_specs
          [spec]
        end

        # The current value.
        def value
          level
        end

        private

        def level
          top = @stack.top
          @value = @pressures.fetch(top.key, 0.0) if top
          @value
        end

        def note_on(event)
          @pressures[[event.channel, event.note]] = 0.0
        end

        def note_off(event)
          key = [event.channel, event.note]
          if @stack.held?
            @pressures.delete(key) unless @stack.held_key?(key)
          else
            level # remember the released note's pressure
            @pressures.clear
          end
        end

        def other(event)
          if event.type == :poly_pressure
            @pressures[[event.channel, event.note]] = event.value.to_f
          elsif event.type == :cc && (event.all_sound_off? || event.all_notes_off?)
            @pressures.clear
          end
        end

        def handle(event)
          super
          @pressures.clear if event.type == :choke
        end

        def chase(event)
          @pressures.clear
          @pressures[[event.channel, event.note]] = 0.0
          @value = 0.0
        end
      end

      # Aftertouch, 0..1: the larger of poly pressure (Notes#poly_pressure)
      # and channel pressure (Notes#pressure), so a patch responds to
      # either kind of keyboard, and to one that sends both without
      # doubling (see Notes#aftertouch).
      class Aftertouch
        include GraphNode
        include GraphNode::SampleRateHelper

        # The poly and channel pressure nodes (sampler branches).
        attr_reader :poly, :channel

        def initialize(poly, channel, sample_rate: 48000)
          @poly = poly.get_sampler
          @channel = channel.get_sampler
          @sample_rate = sample_rate.to_f
          @node_type_name = 'Notes Aftertouch'
        end

        def sample(count)
          p = @poly.sample(count)
          c = @channel.sample(count)
          return nil if p.nil? || c.nil?

          # Constant frozen buffers (Notes fast paths): one constant result
          if p.frozen? && c.frozen? && (pv = p[0]) == p.max && pv == p.min && (cv = c[0]) == c.max && cv == c.min
            v = pv > cv ? pv : cv
            return @steady if @steady && @steady.length == count && @steady_value == v
            @steady_value = v
            return @steady = Numo::SFloat.new(count).fill(v).freeze
          end

          Numo::SFloat.maximum(p, c)
        end

        def control_specs
          [MIDI::ControlSpec.pressure, MIDI::ControlSpec.poly_pressure]
        end

        def sources
          { poly: @poly, channel: @channel }
        end
      end
    end
  end
end
