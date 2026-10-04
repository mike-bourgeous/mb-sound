module MB
  module Sound
    module GraphNode
      # Shifts a frequency signal (Hz) by a number of semitones (a number
      # or a graph node, read every sample): hz × 2 ** (semitones / 12).
      # Used by Pitch#vibrato.
      #
      # Example:
      #     SemitoneShift.new(440.constant, 6.hz.lfo * 0.3)
      class SemitoneShift
        include GraphNode
        include SampleRateHelper

        def initialize(frequency, semitones, sample_rate: 48000)
          @sample_rate = sample_rate.to_f
          @frequency = frequency.get_sampler
          @semitones = semitones.respond_to?(:sample) ? semitones.get_sampler : semitones.to_f
          @buf = nil
          @node_type_name = 'Semitone Shift'
        end

        def sample(count)
          f = @frequency.sample(count)
          return nil if f.nil?

          count = f.length
          @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
          @buf[0..] = f

          if @semitones.is_a?(Numeric)
            @buf.inplace * 2 ** (@semitones / 12.0)
          else
            s = @semitones.sample(count)
            return nil if s.nil? || s.length < count
            @buf.inplace * Numo::NMath.exp(s * (Math.log(2) / 12.0))
          end

          @buf.not_inplace!
        end

        def sources
          { frequency: @frequency, semitones: @semitones }
        end
      end
    end
  end
end
