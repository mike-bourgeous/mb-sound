module MB
  module Sound
    module GraphNode
      module Recipe
        # The recorded DSL surface: which methods of which classes get
        # recorders (see Recipe.install!), and the public methods that are
        # deliberately left out (with reasons; the guard spec in
        # spec/lib/mb/sound/graph_node/recipe_spec.rb checks that every
        # public method is one or the other).
        module Surface
          # Names never recorded anywhere: Ruby plumbing and hot paths.
          NEVER = [
            :sample, :sample_rate, :sample_rate=, :sources, :to_s, :inspect, :to_s_graphviz, :graph_node_name,
            :hash, :==, :eql?, :<=>, :dup, :clone,
          ].freeze

          # Public methods of the recorded classes that aren't DSL builders
          # (value readers, plumbing, things the library calls while
          # sampling), by class name.  Predicates (?), setters (=), and
          # plan_* methods are always left out.
          EXEMPT = {
            'MB::Sound::Tone' => {
              reason: 'readers and sampling internals (the library reads them while sampling)',
              names: %i[
                advance compute_ruby fm_feedback_amount fm_feedback_gain frequency last_freq noise_seed output_gain
                phase phi period period_samples random_advance reset_input reset_to sample_c sample_ruby state
                sync_source table timeline to_midi to_note wave_type wavelength amplitude amplitude_set range seed
                phase_mod scan pivot warp_pivot
              ],
            },
            'MB::Sound::Pitch' => {
              reason: 'value readers (a Pitch prints as a value)',
              names: %i[frequency period period_samples wavelength oscillator_frequency to_midi to_note signal hz unison_copy unison_phase],
            },
            'MB::Sound::Notes::NotePitch' => {
              reason: 'readers of the pitch settings',
              names: %i[frequency oscillator_frequency notes settings],
            },
            'MB::Sound::Notes' => {
              reason: 'readers, stream plumbing, and checks the Synth calls while sampling',
              names: %i[
                control_specs control_stream controls envelopes level level_check quiet_check note_stream stream
                frequency_for to_midi_stream register keys
              ],
            },
            'MB::Sound::GraphNode::Channels' => {
              reason: 'readers (channel access is recorded as element access, see ELEMENT_ACCESS)',
              names: %i[channel_index length size names to_h],
            },
            'MB::Sound::Sequence::Clip' => {
              reason: 'event readers and lineage (clips print through their recipes)',
              names: %i[each edges event_at events events_for length lineage rederive source stream value variations seed],
            },
            'MB::Sound::Sequence::Seq' => {
              reason: 'readers',
              names: %i[steps beats],
            },
          }.freeze

          # Top-level MB::Sound modules whose methods build graphs, with the
          # methods left out.
          TOP = {
            'EnvelopeMethods' => {},
            'ModMethods' => {},
            'MultichannelMethods' => {},
            'GenerationMethods' => {},
            'DrumMethods' => {},
            'MidiMethods' => {
              midi: 'live MIDI input (printed as an input)',
              midi_stream: 'a MIDI::Stream for live input', close_midi: 'closes live input',
              per_voice: 'returns a plain value for the current lane (lanes that differ print with per_voice)',
            },
            'SequenceMethods' => {
              bpm: 'transport tempo (session state)', transport: 'the session transport',
              rewind: 'transport control', seek: 'transport control', scale: 'a Scale value',
            },
          }.freeze

          # Other top-level methods that build graph sources.
          TOP_EXTRA = [:file_input].freeze

          # Methods of the GraphNode *Methods modules (the per-channel DSL).
          def self.graph_node_dsl
            GraphNode.included_modules
              .select { |m| m.name&.end_with?('Methods') && m.name.start_with?('MB::Sound::GraphNode::') }
              .flat_map { |m| m.public_instance_methods(false) }
              .uniq - EXEMPT_GRAPH_NODE - NEVER
          end

          EXEMPT_GRAPH_NODE = Recipe::EXEMPT['MB::Sound::GraphNode'].keys.freeze

          # The own public methods of +klass+ that are recorded (see EXEMPT).
          def self.own_surface(klass)
            exempt = EXEMPT[klass.name]&.fetch(:names) || []
            klass.public_instance_methods(false).reject { |m|
              m.end_with?('?', '=') || m.start_with?('plan_') || NEVER.include?(m) || exempt.include?(m)
            }
          end

          # The top-level methods recorded on MB::Sound.
          def self.top_level
            TOP.flat_map { |mod, exempt|
              MB::Sound.const_get(mod).public_instance_methods(false) - exempt.keys
            } + TOP_EXTRA
          end

          # Classes with their own recorded surfaces.
          def self.classes
            [
              MB::Sound::Tone, MB::Sound::Pitch, MB::Sound::Notes::NotePitch, MB::Sound::Notes,
              MB::Sound::GraphNode::Channels, MB::Sound::Sequence::Clip, MB::Sound::Sequence::Seq,
            ]
          end
        end

        # Records new delay insert pipeline builders (d.fb { }, d.wet { }) as
        # statements of the delay's block.
        module PipelineRecording
          private

          def set_fb(b)
            super(Recipe.statement(@delayed, :fb, b))
          end

          def set_wet(b)
            super(Recipe.statement(@delayed, :wet, b))
          end
        end

        # Records +.new+ of node classes when called from user code (outside
        # lib/mb/sound), e.g. GraphNode::Mixer.new(taps) in a script.
        module NewRecording
          def new(*args, **kwargs, &block)
            if Recipe.enabled && Recipe.state.depth == 0 && !Recipe.library_caller?(caller_locations(1, 1)[0])
              Recipe.call(self, :new, args, kwargs, block) { |b| super(*args, **kwargs, &b) }
            else
              super
            end
          end
        end

        # MB::Sound.next_seed reports seeds drawn while a call is recorded.
        module SeedRecording
          def next_seed
            super.tap { |s| Recipe.drew_seed(s) }
          end

          # Calls inside derive their seeds from the given one (see
          # Recipe.lane), so they don't print seeds of their own.
          def with_seed(seed, &block)
            st = Recipe.state
            st.seeded += 1
            begin
              super
            ensure
              st.seeded -= 1
            end
          end
        end

        LIB_DIR = File.expand_path('../../..', __dir__).freeze
        GRAPH_IO_DIR = File.join(LIB_DIR, 'sound', 'graph_io').freeze

        class << self
          # True if +location+ is library code (lib/mb/sound).
          def library_caller?(location)
            path = location&.path
            return false unless path
            # The graph document loader makes user calls for the document
            path.start_with?(LIB_DIR) && !path.start_with?(GRAPH_IO_DIR)
          end

          # Prepends the recorders (idempotent; .refresh! adds recorders for
          # methods added since).
          def install!
            refresh!
            return if @installed
            @installed = true

            Numeric.prepend(Module.new.tap { |m|
              m.define_method(:constant) do |*args, **kwargs, &block|
                Recipe.call(self, :constant, args, kwargs, block) { |b| super(*args, **kwargs, &b) }
              end
            })
            @wrapped[:numeric] << :constant

            record(Array, [:channels, :reverb], key: :array)
            DelayMethods::InsertPipeline.prepend(PipelineRecording)
            MB::Sound.singleton_class.prepend(SeedRecording)

            [MB::Sound::Filter, MB::Sound::Notes, MB::Sound::Wavetable::KeyMap, MB::Sound::Sequence::Kit].each { |c| c.singleton_class.prepend(NewRecording) }
            new_roots.each { |c| c.singleton_class.prepend(NewRecording) }

            class << GraphNode
              prepend(Module.new {
                def include(*modules)
                  super.tap { Recipe.refresh! if Recipe.instance_variable_get(:@installed) }
                end
              })
            end
          end

          # Adds recorders for DSL methods without one (e.g. after a *Methods
          # module gained methods).
          def refresh!
            dsl = Surface.graph_node_dsl + [:named]
            record(GraphNode, dsl - @wrapped[GraphNode].to_a, key: GraphNode)

            # Classes that define DSL methods themselves (Pitch#tone,
            # FourPole#filter, ...) need their own recorders
            ObjectSpace.each_object(Class) do |c|
              next unless c.name&.start_with?('MB::Sound') && c.include?(GraphNode)
              own = c.public_instance_methods(false) & dsl
              record(c, own) unless own.empty?
            end

            Surface.classes.each do |c|
              names = Surface.own_surface(c)
              names |= dsl + ELEMENT_ACCESS + [:coerce] if c == Channels
              names |= MB::Sound::Sequence::NoteMethods.public_instance_methods(false) if c == MB::Sound::Sequence::Seq
              names |= [:named] if c == MB::Sound::Sequence::Clip # Sequence::Named, shared with Kit
              names |= MB::Sound::ModMethods.public_instance_methods(false) if c == MB::Sound::Notes
              record(c, names)
            end
            record(MB::Sound::Note, MB::Sound::Sequence::NoteMethods.public_instance_methods(false), key: MB::Sound::Note)

            record(MB::Sound.singleton_class, Surface.top_level, key: :sound)
            record(MB::Sound::Wavetable::KeyMap.singleton_class, [:zones], key: MB::Sound::Wavetable::KeyMap.singleton_class)
          end

          # Classes that include GraphNode or MultiOutput directly (their
          # subclasses inherit the +.new+ recorder).
          def new_roots
            ObjectSpace.each_object(Class).select { |c|
              next false unless c.name&.start_with?('MB::Sound') && !c.singleton_class.include?(NewRecording)
              (c.include?(GraphNode) || c.include?(MultiOutput)) &&
                !(c.superclass.include?(GraphNode) || c.superclass.include?(MultiOutput))
            }
          end
        end
      end
    end
  end
end
