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
      #
      # +function: :resonance_quality+ is the other way (reese-slope-1,
      # 2026-11-07): the 2-pole quality whose gain at the cutoff is lp4's (or
      # the diode ladder's) at the input's resonance on the :db curve
      # (Filter::FourPole.resonance_to_quality; made by
      # FourPole.resonance_quality for `filter(:lowpass, resonance:)`).
      class QualityResonance < UnaryFunction
        include SampleRateHelper

        # Display names of the functions.
        FUNCTIONS = { quality_resonance: 'resonance of Q', resonance_quality: 'Q of resonance' }.freeze

        # The resonance curve and tuning (see FourPole).
        attr_reader :curve, :tuning

        # True for the diode ladder's resonance scale.
        def diode_ladder? = @diode

        def initialize(input, curve: :db, diode: false, tuning: :musical, sample_rate: nil, function: :quality_resonance)
          raise ArgumentError, 'Q of resonance reads the :db resonance curve' if function == :resonance_quality && curve != :db

          super(input, function: function)
          @curve = curve
          @diode = diode
          @tuning = tuning
          @sample_rate = (sample_rate || @input.sample_rate).to_f
          @node_type_name = 'QualityResonance'
        end

        # The resonances for the qualities in +data+, or the qualities for
        # the resonances with +function: :resonance_quality+ (a new buffer).
        def apply(data)
          if @function == :resonance_quality
            MB::Sound::Filter::FourPole.resonance_to_quality(data, diode: @diode, tuning: @tuning)
          else
            MB::Sound::Filter::FourPole.quality_to_resonance(data, curve: @curve, diode: @diode, tuning: @tuning)
          end
        end

        def plan_unsupported_reason
          if @function == :resonance_quality
            'resonance to Q runs in Ruby (Filter::FourPole.resonance_to_quality)'
          else
            'Q to resonance runs in Ruby (Filter::FourPole.quality_to_resonance)'
          end
        end
      end
    end
  end
end
