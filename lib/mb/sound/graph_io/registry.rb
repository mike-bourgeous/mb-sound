require 'set'

module MB
  module Sound
    module GraphIO
      # What a graph document may call: the DSL surface the recorder wraps
      # (GraphNode::Recipe.wrapped, so a method that records is a method a
      # document can call back), plus explicit opt-ins for values (unit
      # methods, Pitch periods, Duration modifiers) and a closed table of
      # constants.  Everything else is a LoadError.
      #
      # The loader calls methods only with public_send, after checking the
      # name here; constants come from CONSTANTS (built from the loaded
      # classes, never const_get with document text).
      module Registry
        # Names no document may call, whatever the receiver (a clearer error
        # than "not a graph method", and a second fence behind the
        # allowlist).
        FORBIDDEN = Set[
          :eval, :instance_eval, :instance_exec, :class_eval, :class_exec, :module_eval, :module_exec,
          :send, :__send__, :public_send, :method, :public_method, :instance_method, :define_method,
          :define_singleton_method, :const_get, :const_set, :const_missing, :instance_variable_get,
          :instance_variable_set, :class_variable_get, :class_variable_set, :binding, :system, :exec, :spawn,
          :fork, :`, :popen, :require, :require_relative, :load, :exit, :exit!, :abort, :at_exit, :trap,
          :set_trace_func, :trace_var, :autoload, :callcc, :instance_variables, :extend, :include, :prepend,
        ].freeze

        # Kernel methods no document may call without a receiver
        # (GraphNode#proc and Clip#loop with a receiver are DSL methods).
        KERNEL = Set[
          :proc, :lambda, :loop, :sleep, :catch, :throw, :raise, :fail, :open, :gets, :puts, :print, :p, :pp,
          :warn, :srand, :rand, :format, :sprintf, :printf, :putc, :readline, :readlines, :select, :caller,
          :exit, :binding, :block_given?, :iterator?, :local_variables, :global_variables,
        ].freeze

        # Unit and value methods on numbers (mb-sound's Numeric mixins; not
        # mb-math's, which include factorial and choose).
        def self.numeric_modules
          [MB::Sound::NumericSoundMixins, MB::Sound::Sequence::NumericDurations, MB::Sound::GraphNode::Constant::NumericConstantMethods]
        end

        # Arithmetic on numbers and values.
        ARITHMETIC = Set[:+, :-, :*, :/, :**, :-@, :+@, :%].freeze

        # Value readers and modifiers a document may call, by class name
        # (and its subclasses), beyond the recorded surface.
        VALUES = {
          'MB::Sound::Pitch' => %i[period period_samples],
          'MB::Sound::Tone' => %i[period period_samples],
          # (hz, lfo: tempo-synced pitches and LFOs, `1.bar.hz`)
          'MB::Sound::Sequence::Duration' => %i[dotted dd double_dotted triplet d t hz lfo] + ARITHMETIC.to_a,
          'MB::Sound::Length::Quantity' => ARITHMETIC.to_a,
          'MB::Sound::Interval' => ARITHMETIC.to_a,
          'MB::Sound::Phase' => ARITHMETIC.to_a,
          # lfo.samples, 0.25.cycles of a node, input.outputs[i] (and
          # then: see the racks below)
          'MB::Sound::GraphNode::MultiOutput' => %i[outputs [] left right],
          # Unattached MIDI transform chains: echo(...).strum(...)
          'MB::Sound::MIDI::Transform::Spec' => MB::Sound::MIDI::Stream::TRANSFORMS.to_a,
          # Note marks (`!A1`, `~C2`, `G2.chance(0.5)`), on Notes and steps
          'MB::Sound::Sequence::NoteMarks' => %i[! ~ accent acc a! slide s! chance maybe every fill nofill pitch flam],
          'MB::Sound::Sequence::Seq::Step' => %i[! ~ accent acc a! slide s! chance maybe every fill nofill up dn down oct pitch flam],
          # Sample views and edits (how Samples print: Sample#lineage)
          'MB::Sound::Sample' => %i[slices slice chops at reverse rev trim [] looped one_shot fade gain normalize transpose bits lofi stretch mono with read_as],
          'MB::Sound::Sample::Slices' => %i[[] name keymap],
          # Instruments built region by region (in Instrument.new's block)
          'MB::Sound::Sampler::Instrument' => %i[region],
          'MB::Sound::Drums::Builder' => %i[voice choke tr808 tr909],
          'MB::Sound::Drums::Hit' => MB::Sound::Drums::Hit::METHODS - %i[knobs name machine],
          # Curve variants (Curve#to_ruby)
          'MB::Sound::Curve' => %i[reverse in out in_out out_in],
          # Probability scales (Generative::Value#to_ruby)
          'MB::Sound::Scale' => %i[weights],
          'MB::Sound::Generative::Chord' => %i[weights],
          'MB::Sound::Generative::Weights' => %i[+ - * / ** blur floor normalize blend over],
          'MB::Sound::Generative::Harmony' => %i[+ - * ** blur over],
          'MB::Sound::Generative::Field' => %i[**],
          # Racks applied to sources (`sig.then(&arack { |s| ... })`;
          # Loader#call_block takes a Rack as the block argument), bound,
          # and composed
          'MB::Sound::GraphNode' => %i[samples seconds cycles cyc radians rad outputs then],
          'MB::Sound::GraphNode::Channels' => %i[then],
          'MB::Sound::Notes' => %i[then],
          'MB::Sound::Sequence::Clip' => %i[then],
          'MB::Sound::MIDI::Stream' => %i[then],
          'MB::Sound::Rack' => %i[with >> << using],
          # A rack's macros with modulation around them (racks R2)
          'MB::Sound::GraphNode::Knob' => %i[mod],
        }.freeze

        # Methods of bundles that hand out channels; the iterating ones
        # (each, map, zip) take blocks and stay out of documents.
        ELEMENTS = Set[:[], :left, :right, :first, :last, :to_a, :outputs].freeze

        # Recorded names left out of documents: iteration with blocks.
        ITERATION = Set[:each, :each_with_index, :map, :each_slice, :zip, :to_ary].freeze

        # Class methods a document may call, by class name (plus .new of
        # every class the recorder records .new for).
        CLASS_METHODS = {
          'MB::Sound::Wavetable' => %i[[]],
          'MB::Sound::Sample' => %i[[]],
          'MB::Sound::Sampler::Instrument' => %i[new layered],
          'MB::Sound::Sampler::ZoneMap' => %i[new],
          'MB::Sound::Wavetable::KeyMap' => %i[zones new],
          'MB::Sound::Sequence::Duration' => %i[new],
          # Tweening curves (Curve#to_ruby: `Curve[:back, overshoot: 0.3]`)
          'MB::Sound::Curve' => %i[[]],
        }.freeze

        # Methods that read files (allowed only with a path relative to the
        # document's directory; see Loader#check_file).
        FILE_METHODS = Set[:file_input, :midi_file, :sfz, :sf2].freeze

        # FILE_METHODS that get the document's file name rather than its
        # resolved path, after the check, so the files they name in turn
        # follow the same rules (an SFZ's samples) and print as written (a
        # SoundFont's name in a bundle).
        KEEP_NAME = Set[:sfz, :sf2].freeze

        # Top-level names besides the recorded MB::Sound methods (scale:
        # Scale values for transforms such as Clip#ghost_chords).
        TOP_EXTRA = (Set[:per_voice, :per_channel, :scale, :tones, :weights, :harmony, :macro] | MB::Sound::Rack::CONSTRUCTORS).freeze

        # Methods whose blocks build graphs (run once per call as document
        # code) rather than run while sampling.
        # Drum kit blocks (DrumMethods#kit, Drums::Builder#voice) print as
        # their source (runtime blocks to the recorder) and load as build
        # blocks, whose parameterless forms run on the builder or hit.
        BUILD_BLOCKS = (MB::Sound::GraphNode::Recipe::BUILD_BLOCKS | Set[:wet, :kit, :drum_kit, :voice]).freeze

        # Methods allowed in the safe subset of runtime blocks (proc bodies
        # and lambda values, run while sampling): arithmetic and math on
        # numbers and NArrays, no graph building.
        RUNTIME = Set[
          :+, :-, :*, :/, :**, :%, :-@, :+@, :abs, :abs2, :clip, :floor, :ceil, :round, :real, :imag, :conj,
          :arg, :angle, :min, :max, :sum, :mean, :[], :<, :>, :<=, :>=, :==, :to_f, :to_i, :length, :size,
          :sin, :cos, :tan, :sinh, :cosh, :tanh, :asin, :acos, :atan, :atan2, :exp, :log, :log2, :log10, :sqrt,
          :cbrt, :hypot,
        ].freeze

        # Math modules runtime blocks may call (Math.sin(x), Numo::NMath.exp(buf)).
        RUNTIME_CONSTANTS = { 'Math' => Math, 'Numo::NMath' => Numo::NMath, 'Math::PI' => Math::PI, 'Math::E' => Math::E }.freeze

        # Constants that are plain values.
        VALUE_CONSTANTS = {
          'Float::INFINITY' => Float::INFINITY, 'Float::NAN' => Float::NAN,
          'Math::PI' => Math::PI, 'Math::E' => Math::E,
        }.freeze

        NOTE_NAME = /\A[A-G][sb]?\d+\z/

        class << self
          # Recorded names by target (GraphNode::Recipe.wrapped).
          def wrapped
            GraphNode::Recipe.wrapped
          end

          # The numeric unit methods.
          def numeric
            @numeric ||= numeric_modules.flat_map { |m| m.public_instance_methods(false) }.to_set | ARITHMETIC
          end

          # Top-level methods (receiver nil, i.e. MB::Sound).
          def top_level
            @top_level ||= (wrapped.fetch(:sound, Set.new).to_set | TOP_EXTRA).freeze
          end

          # True if +name+ is a method a document may call on +obj+.
          def allowed?(obj, name)
            return false if FORBIDDEN.include?(name)
            names_for(obj).include?(name) && obj.respond_to?(name)
          end

          # The callable names for +obj+ (for errors and did_you_mean).
          def names_for(obj)
            case obj
            when Numeric then numeric
            when Array then wrapped.fetch(:array, Set.new).to_set
            when Module then class_methods(obj)
            else instance_names(obj)
            end
          end

          # Class methods allowed on +klass+.
          def class_methods(klass)
            names = Set.new
            names << :new if klass.singleton_class.include?(GraphNode::Recipe::NewRecording) || data_class?(klass)
            klass.ancestors.each { |a| names.merge(CLASS_METHODS[a.name] || []) if a.name }
            names.merge(wrapped[klass.singleton_class]) if wrapped.key?(klass.singleton_class)
            names
          end

          # Instance methods allowed on +obj+: the recorded names of its
          # class's ancestors plus VALUES, without the iterating bundle
          # methods; delay insert pipelines add d.wet (d.fb is recorded).
          def instance_names(obj)
            klass = obj.class
            @instance_names ||= {}
            names = (@instance_names[klass] ||= begin
              n = Set.new
              klass.ancestors.each do |a|
                n.merge(wrapped[a]) if wrapped.key?(a)
                n.merge(VALUES[a.name]) if a.name && VALUES.key?(a.name)
              end
              n - ITERATION
            end)
            if obj.singleton_methods.include?(:wet)
              names = names | Set[:wet, :fb]
            end
            # A drum hit's knob readers (see Drums::Hit)
            names = names | obj.knobs.keys.to_set if obj.is_a?(MB::Sound::Drums::Hit)
            names
          end

          # True for Data value classes of the library (MIDI::ControlSpec).
          def data_class?(klass)
            klass.is_a?(Class) && klass < Data && klass.name&.start_with?('MB::Sound::')
          end

          # The constant a document names with +text+ (`GraphNode::Mixer`,
          # `MIDI::ControlSpec`, `A3`, `Float::INFINITY`), or nil.
          def constant(text)
            text = text.delete_prefix('::').delete_prefix('MB::Sound::')
            return VALUE_CONSTANTS[text] if VALUE_CONSTANTS.key?(text)
            return unrecorded { MB::Sound::Note.new(text) } if text.match?(NOTE_NAME)

            constants[text]
          end

          # Classes and markers a document may name, by their name relative
          # to MB::Sound: classes whose .new is recorded, Data values, the
          # CLASS_METHODS classes, and seq markers.
          def constants
            @constants ||= begin
              table = {}
              ObjectSpace.each_object(Module) do |m|
                name = m.name
                next unless name&.start_with?('MB::Sound::')
                next unless m.is_a?(Class)
                next unless m.singleton_class.include?(GraphNode::Recipe::NewRecording) || data_class?(m) || CLASS_METHODS.key?(name)
                table[name.delete_prefix('MB::Sound::')] = m
              end
              { 'Rest' => MB::Sound::Rest, 'R' => MB::Sound::R, 'Tie' => MB::Sound::Tie, 'T' => MB::Sound::T }.each { |k, v| table[k] = v }
              table.freeze
            end
          end

          # Runs the block without recording its calls (a value the
          # document names, like A3, isn't a DSL call).
          def unrecorded
            st = GraphNode::Recipe.state
            st.depth += 1
            begin
              yield
            ensure
              st.depth -= 1
            end
          end

          # Forgets cached tables (after new classes or recorders load).
          def refresh!
            @numeric = @top_level = @instance_names = @constants = nil
          end
        end
      end
    end
  end
end
