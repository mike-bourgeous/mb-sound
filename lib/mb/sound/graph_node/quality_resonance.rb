module MB
  module Sound
    module GraphNode
      # The lp4 or diode ladder resonance (FourPole) giving the gain at the
      # cutoff of a 2-pole filter of the quality from its input (a node such
      # as Notes#quality; Filter::FourPole.quality_to_resonance with the
      # filter's resonance +curve+, +diode+, and +tuning+).  Made by
      # FourPole.quality_resonance for node qualities; a node type of its
      # own since omnibus18 (2026-10-30; a ProcNode block before).  Not a
      # plan op (it stays unfused, as the block did).
      class QualityResonance < UnaryFunction
        include SampleRateHelper

        # Display names of the functions (one).
        FUNCTIONS = { quality_resonance: 'resonance of Q' }.freeze

        # The resonance curve and tuning (see FourPole).
        attr_reader :curve, :tuning

        # True for the diode ladder's resonance scale.
        def diode_ladder? = @diode

        def initialize(input, curve: :db, diode: false, tuning: :musical, sample_rate: nil)
          super(input, function: :quality_resonance)
          @curve = curve
          @diode = diode
          @tuning = tuning
          @sample_rate = (sample_rate || @input.sample_rate).to_f
          @node_type_name = 'QualityResonance'
        end

        # The resonances for the qualities in +data+ (a new buffer).
        def apply(data)
          MB::Sound::Filter::FourPole.quality_to_resonance(data, curve: @curve, diode: @diode, tuning: @tuning)
        end

        def plan_unsupported_reason
          'Q to resonance runs in Ruby (Filter::FourPole.quality_to_resonance)'
        end
      end
    end
  end
end
