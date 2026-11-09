module MB
  module Sound
    module GraphNode
      # The LFO of the modulation effects (GraphNode#phaser,
      # GraphNode#flanger, GraphNode#tremolo, the rotary speaker's rotors;
      # effects-2, which moved phaser-1's Phaser.lfo and tremolo-1's rate
      # reading here): one place that turns a +rate:+
      # setting into a Tone LFO, so every modulation effect reads rates the
      # same way.
      module ModulationLfo
        # LFO shapes.
        SHAPES = %i[sine triangle].freeze

        # A Tone LFO of +shape+ (:sine or :triangle) starting at +phase+
        # cycles, -1..1, at +rate+ (see .rate_tone).  +what+ names the
        # effect in errors.
        def self.tone(rate, shape: :sine, phase: 0, sample_rate:, what: 'lfo')
          unless SHAPES.include?(shape)
            raise ArgumentError, "#{what} shape: is #{SHAPES.map(&:inspect).join(' or ')} (got #{shape.inspect})"
          end

          tone = rate_tone(rate, sample_rate: sample_rate, what: what)
          tone = shape == :triangle ? tone.triangle : tone.sine
          tone = tone.with_phase(phase) unless phase == 0
          tone
        end

        # The Tone LFO (its waveform and phase left to the caller; tremolo
        # draws its own shapes on it) at +rate+: Hz (a number, a Pitch, or
        # a node of Hz), a musical length per cycle (`1.bar`, `knob.bars`;
        # follows the tempo and the timeline), or a Length per cycle
        # (`2.seconds`), at +sample_rate+.
        def self.rate_tone(rate, sample_rate:, what: 'lfo')
          rate = GraphNode.build_setting(rate) unless rate.respond_to?(:sample)
          tone = case rate
                 # (first: a Duration is a Length, and a NodeDuration may be a
                 # node; both follow the tempo through their own #lfo)
                 when Sequence::Duration, Sequence::NodeDuration, Pitch then rate.lfo
                 when Numeric
                   raise ArgumentError, "#{what} rate: must not be negative (got #{rate})" unless rate.real? && rate >= 0
                   rate.to_f.hz.lfo
                 when Length then (1.0 / rate.to_seconds(sample_rate: sample_rate)).hz.lfo
                 when GraphNode then rate.tone.lfo
                 else
                   unless rate.respond_to?(:lfo)
                     raise ArgumentError, "#{what} rate: is Hz, a Pitch, a musical length (1.bar), a Length, or a node of Hz (got #{rate.inspect})"
                   end
                   rate.lfo
                 end
          # (only when it differs: a rate node's Tone has its rate already,
          # and at_rate would reach upstream into the rate node's own graph)
          tone.at_rate(sample_rate) unless tone.sample_rate == sample_rate
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
