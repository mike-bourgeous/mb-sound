module MB
  module Sound
    module GraphNode
      # The sweep LFO of the modulation effects (GraphNode#flanger, the
      # rotary speaker's motor; effects-2): one place that turns a +rate:+
      # setting into a Tone LFO, so every modulation effect reads rates the
      # same way (phaser-1's Phaser.lfo takes the same values).
      module ModulationLfo
        # LFO shapes.
        SHAPES = %i[sine triangle].freeze

        # A Tone LFO of +shape+ (:sine or :triangle) starting at +phase+
        # cycles, -1..1, at +rate+: Hz (a number, a Pitch, or a node of
        # Hz), a musical length per cycle (`1.bar`, `knob.bars`; follows
        # the tempo and the timeline), or a Length per cycle (`2.seconds`).
        # +what+ names the effect in errors.
        def self.tone(rate, shape: :sine, phase: 0, sample_rate:, what: 'lfo')
          unless SHAPES.include?(shape)
            raise ArgumentError, "#{what} shape: is #{SHAPES.map(&:inspect).join(' or ')} (got #{shape.inspect})"
          end

          rate = GraphNode.build_setting(rate) unless rate.respond_to?(:sample)
          tone = case rate
                 when Numeric
                   raise ArgumentError, "#{what} rate: must not be negative (got #{rate})" unless rate.real? && rate >= 0
                   rate.to_f.hz.lfo
                 when GraphNode then rate.tone.lfo
                 when Sequence::Duration, Pitch then rate.lfo # (a Duration is a Length: first, so it follows the tempo)
                 when Length then (1.0 / rate.to_seconds(sample_rate: sample_rate)).hz.lfo
                 else
                   unless rate.respond_to?(:lfo)
                     raise ArgumentError, "#{what} rate: is Hz, a Pitch, a musical length (1.bar), a Length, or a node of Hz (got #{rate.inspect})"
                   end
                   rate.lfo
                 end
          tone = shape == :triangle ? tone.triangle : tone.sine
          tone = tone.with_phase(phase) unless phase == 0
          tone.at_rate(sample_rate)
          tone
        end

        # A phase setting in cycles (a number or a Phase); +what+ and
        # +name+ for errors.
        def self.cycles(value, what, name)
          value = GraphNode.build_setting(value)
          value = Phase.cycles(value) if value.is_a?(Phase)
          raise ArgumentError, "#{what} #{name}: is a number of cycles (got #{value.inspect})" unless value.is_a?(Numeric) && value.real?
          value.to_f
        end
      end
    end
  end
end
