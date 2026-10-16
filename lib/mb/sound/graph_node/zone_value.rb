module MB
  module Sound
    module GraphNode
      # The value of a Sampler::ZoneMap for the current note: each sample
      # reads the note +number+ and +velocity+ (0..1, as Notes#velocity)
      # inputs, rounds them to MIDI numbers like the sampler kernel's region
      # choice, and outputs the map's value for them.  Made by
      # Sampler::Instrument#play for SoundFont settings that change from zone
      # to zone (envelope times, sustain levels, filter cutoffs).
      #
      #     ZoneValue.new(map, number: v.number, velocity: v.velocity)
      class ZoneValue
        include GraphNode
        include SampleRateHelper

        # The Sampler::ZoneMap read.
        attr_reader :map

        def initialize(map, number:, velocity:, sample_rate: 48000)
          raise ArgumentError, "A ZoneValue reads a Sampler::ZoneMap (got #{map.inspect})" unless map.is_a?(Sampler::ZoneMap)
          @map = map
          @table = map.table.reshape(128 * 128)
          @number = number.get_sampler
          @velocity = velocity.get_sampler
          @sample_rate = sample_rate.to_f
          @buf = nil
          @node_type_name = 'Zone Value'
        end

        def sample(count)
          n = @number.sample(count)
          return nil if n.nil?
          count = n.length
          v = @velocity.sample(count)
          return nil if v.nil?
          v = v[0...count] if v.length > count

          keys = Numo::Int32.cast((Numo::DFloat.cast(n) + 0.5).floor.clip(0, 127))
          vels = Numo::Int32.cast((Numo::DFloat.cast(v) * 127.0 + 0.5).floor.clip(0, 127))
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          @buf[0..] = @table[keys * 128 + vels]
          @buf
        end

        def sources
          { number: @number, velocity: @velocity }
        end

        def plan_unsupported_reason
          'zone values are a plan boundary for now'
        end

        def to_s
          "ZoneValue #{@map}"
        end
      end
    end
  end
end
