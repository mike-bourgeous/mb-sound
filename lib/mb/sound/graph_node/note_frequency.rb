module MB
  module Sound
    module GraphNode
      # Converts note numbers (C4 = 60, fractional for detuned notes) from
      # its input to frequencies in Hz with a Tuning, as the tuning is when
      # each buffer is computed (FastSound.number_to_freq: 2^x at
      # MB::Sound.precision :fast, libm at :exact).  Made by Tuning#freq (so
      # GraphNode#freq, Notes pitch nodes); a node type of its own since
      # omnibus18 (2026-10-30; a ProcNode block before), so it shows as
      # itself in graphviz and the inspector.  The plan layer fuses it
      # (Plan::Op::NoteFreq).
      class NoteFrequency < UnaryFunction
        include SampleRateHelper

        # Display names of the functions (one).
        FUNCTIONS = { note_freq: 'hz' }.freeze

        # The Tuning the notes are converted with.
        attr_reader :tuning

        # Creates a node converting the note numbers from +input+ with
        # +tuning+ (a MB::Sound::Tuning).
        def initialize(input, tuning:, sample_rate: nil)
          super(input, function: :note_freq)
          @tuning = tuning
          @sample_rate = (sample_rate || @input.sample_rate).to_f
          @copier = FrozenCopy.new
          @node_type_name = 'NoteFrequency'
        end

        # The frequencies of the note numbers in +data+.  An SFloat input
        # is converted in a reused copy (FastSound.number_to_freq converts
        # an inplace SFloat where it is, else copies it), so the input's
        # buffer is never modified and nothing is allocated per buffer.
        def apply(data)
          data = @copier.copy(data).inplace! if data.is_a?(Numo::SFloat)
          MB::FastSound.number_to_freq(data, @tuning.note, @tuning.frequency)
        end

        # What GraphNode#make_source_name shows for this node: the note for
        # a constant whole note number (C4), else hz(...) of the input.
        def display_label
          src = climb_tee_tree(@input)
          if src.is_a?(Constant) && src.constant.is_a?(Numeric) && src.constant.real? && src.constant == src.constant.round
            Note.new(src.constant.round).to_s
          else
            "hz(#{make_source_name(src)})"
          end
        end

        # (display_label, not "hz(...)" with parentheses; see
        # GraphNode#make_source_name)
        def arithmetic_string(_separator = ' ')
          display_label
        end

        def plan_describe(p)
          p.note_freq(p[@input], @tuning)
        end
      end
    end
  end
end
