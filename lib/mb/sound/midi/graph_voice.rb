require 'forwardable'

module MB
  module Sound
    module MIDI
      # A single MIDI synthesizer voice based on an arbitrary signal graph.
      # Every envelope and ArrayInput is restarted when the voice is triggered,
      # and every oscillator with a constant frequency, or a constant value
      # added somewhere in its frequency input, has that constant set to the
      # triggering note frequency.
      #
      # TODO: It should be *way* easier to create a synthesizer.  Something
      # like this:
      #
      #     synth('midi filename or jack midi input', 8) { |midi|
      #       midi.hz.ramp.at(1) * midi.env
      #     }
      class GraphVoice
        extend Forwardable

        include GraphNode

        # Provides GraphVoice-specific behavior for MidiDsl nodes used within a
        # GraphVoice, such as per-voice note events (vs. all note events).
        class ManagerProxy
          extend Forwardable

          def_delegators :@manager, :on_cc, :on_bend, :channel, :update, :midi_in

          def initialize(voice:, manager:)
            @gv = voice
            @manager = manager
            @graph_voice_callbacks = []
            @gv_number_callbacks = []
          end

          # MIDI DSL nodes normally call the manager update function from their
          # sample method, which can result in multiple updates per sample
          # buffer.  To avoid this, we ignore update calls here and instead
          # call Manager#update in the VoicePool.
          def update
          end

          # Overrides the manager's default #on_note method to notify callbacks
          # only when this specific voice is triggered, rather than when any
          # note is received.
          def on_note(&callback)
            @graph_voice_callbacks << callback
          end

          # New method for use by DslProxy for managing polyphonic portamento
          # (see GraphVoice#set_note).
          def gv_on_number(&callback)
            @gv_number_callbacks << callback
          end

          # Called by GraphVoice to trigger note events on note-related nodes
          # like MidiTone, MidiNumber, etc.
          def graph_voice_trigger(number, velocity, timestamp)
            @graph_voice_callbacks.each do |cb|
              cb.call(number, velocity, true, timestamp)
            end
          end

          # Called by GraphVoice to trigger release events on note-related
          # nodes like MidiGate, MidiEnvelope, etc.
          def graph_voice_release(number, velocity, timestamp)
            @graph_voice_callbacks.each do |cb|
              cb.call(number, velocity, false, timestamp)
            end
          end

          def graph_voice_set_note(number, timestamp, reset_portamento: :todo)
            @gv_number_callbacks.each do |ncb|
              ncb.call(number, timestamp)
            end
          end
        end

        # TODO: maybe GraphVoice should be abandoned, and instead a new
        # mechanism for round-robining MIDI events?  nah probbalbybbyoi
        # notnoooot
        class DslProxy < MB::Sound::GraphNode::MidiDsl
          def initialize(voice:, manager:)
            super(manager: manager)
            @gv = voice
          end

          def channel(ch)
            raise 'MIDI manager handles channel filtering for GraphVoice'
          end

          def frequency(ratio = 1, offset = 0, bend_range: DEFAULT_BEND_RANGE, smoothing: false)
            # TODO: maybe there's a way to move this up to MidiDsl itself
            super.tap { |n| @manager.gv_on_number(&n.method(:set_note)) }
          end
          alias freq frequency

          def number(range: nil, bend_range: DEFAULT_BEND_RANGE, unit: nil, si: false, smoothing: false)
            super.tap { |n| @manager.gv_on_number(&n.method(:set_note)) }
          end
        end

        attr_reader :number, :dsl_proxy

        # A Hash from CC index to an Array of Hashes describing a controllable
        # parameter.  Used by VoicePool.  See #on_cc.
        attr_reader :cc_map

        def_delegators :@graph, :sample_rate, :sample_rate=

        # Initializes a voice based on the given signal graph.  The
        # +:update_rate+ is passed to internal Parameter objects for parameter
        # smoothing.  If the automatic detection of envelopes and oscillators
        # doesn't work, then the +:amp_envelopes+, +:envelopes+, and
        # +:freq_constants+ parameters may be used to override detection.
        #
        # The +:label+ option allows prefixing all named nodes in the node
        # graph with a given label, e.g. to show the voice index.
        #
        # TODO: can we calculate the update rate from graph sample rate and
        # buffer size, or on first call to sample?
        def initialize(graph = nil, update_rate: 60, amp_envelopes: nil, envelopes: nil, freq_constants: nil, label: nil, manager:)
          if block_given?
            raise 'Both block and graph parameter were given; only pass one or the other' if graph
            raise 'Do not supply a list of envelopes when giving a block' if amp_envelopes || envelopes
            raise 'Do not supply a list of frequency constants when giving a block' if freq_constants

            @manager_proxy = ManagerProxy.new(voice: self, manager: manager)
            @dsl_proxy = DslProxy.new(voice: self, manager: @manager_proxy)
            graph = yield @dsl_proxy

          else
            raise 'No graph was given' unless graph
          end

          if label
            graph.graph.each do |n|
              next unless n.respond_to?(:named)
              name = n.graph_node_name
              name ||= n.node_type_name if n.respond_to?(:node_type_name)
              n.named("#{label} #{name}".strip)
            end
          end

          @graph = graph
          @update_rate = update_rate

          @parameters = []

          @number = nil

          sources = graph.graph

          @oscillators = sources.select { |s|
            s.is_a?(MB::Sound::Tone) || s.is_a?(MB::Sound::Oscillator)
          }.map { |o|
            if o.is_a?(MB::Sound::Tone)
              o.forever
              o.oscillator
            else
              o
            end
          }

          @amp_envelopes = amp_envelopes || []
          @envelopes = envelopes || sources.select { |s|
            s.is_a?(MB::Sound::ADSREnvelope)
          }

          @amp_envelopes.map! { |env| find_node(env) }
          @envelopes.map! { |env| find_node(env) }

          @envelopes.each(&:reset) # disable auto-release on envelopes

          @array_inputs = sources.select { |s|
            s.is_a?(ArrayInput)
          }

          if freq_constants
            @freq_constants = freq_constants
          else
            @freq_constants = []
            @oscillators.each do |o|
              # Look for the top-most mixer or constant value in the frequency input graph for the oscillator
              # FIXME: this won't handle chained multi-op FM correctly
              g = o.respond_to?(:graph) ? o.graph : [o.frequency]
              mixer = g.select { |s|
                # TODO: use Constant#unit accessor
                (s.is_a?(MB::Sound::GraphNode::Mixer) || s.is_a?(MB::Sound::GraphNode::Constant)) &&
                  s.constant >= 20 # Haxx to try to separate frequency values from other values; might help to have some kind of units or roles for detecting these things
              }.first
              @freq_constants << mixer if mixer
            end
          end

          @portamento_filters = []
          @portamento_filters = graph.find_all_by_name('portamento')

          @cc_map = {}
          @velocity_listeners = []

          # Make sure frequency smoothing defaults to off so there is no
          # unintentional portamento effect.
          @freq_constants.each do |f|
            f.smoothing = false if f.respond_to?(:smoothing) && f.smoothing.nil?
          end
        end

        # Tells all envelopes to start their attack phase based on the given
        # velocity, and sets all frequency constants based on the given note.
        def trigger(note, velocity, timestamp)
          set_note(note, timestamp, reset_portamento: false)

          @oscillators.each do |o|
            o.reset unless o.no_trigger
          end

          # TODO: make envelope ranges controllable
          @envelopes.each do |env|
            env.trigger(MB::M.scale(velocity, 0..127, 0.9..1.05))
          end
          @amp_envelopes.each do |env|
            env.trigger(MB::M.scale(velocity, 0..127, -10..-6).db)
          end

          @array_inputs.each do |ai|
            ai.offset = 0
          end

          @velocity_listeners.each do |vl|
            vl[:parameter].raw_value = velocity
          end

          @manager_proxy&.graph_voice_trigger(note, velocity, timestamp)
        end

        # Sets the note number without triggering the envelope generators (e.g.
        # for polyphonic portamento).
        def set_note(note, timestamp, reset_portamento: true)
          @number = note

          @oscillators.each do |o|
            if o.frequency.is_a?(Numeric) && @freq_constants.empty?
              o.frequency = MB::Sound::Oscillator.calc_freq(note)
            end
          end

          freq = MB::Sound::Oscillator.calc_freq(note)
          @freq_constants.each do |fc|
            # TODO: Have a way of setting the note number instead, to allow
            # for logarithmic portamento by filtering through a follower
            fc.constant = freq
          end

          # FIXME: the assumption that the portamento filter will be using the log2 of the frequency is not a safe assumption
          if reset_portamento
            @portamento_filters.each do |f|
              f.reset(Math.log2(freq))
            end
          end

          @manager_proxy&.graph_voice_set_note(note, timestamp)
        end

        # Sends values of internal parameters to graph nodes (e.g. those from
        # #on_velocity).  The VoicePool will have the Manager call this method
        # at the manager's update rate.
        #
        # TODO: it's weird to have the manager passed into the GraphVoice just
        # for the update_rate.  Either have GraphVoice be fully active in
        # connecting to Manager, or fully passive with VoicePool doing all the
        # work, but this is challenging when Parameters are constructed before
        # the voice is added to a pool.
        def update
          @parameters.each do |p|
            p[:set].call(p[:parameter].value)
          end
        end

        # Assigns values of one or more nodes within the graph to receive
        # values based on note attack velocity.  Unlike #on_cc, these values
        # have no filtering applied.  Additional +options+ will be passed to
        # MB::Sound::MIDI::Parameter#initialize.
        def on_velocity(node, range: 0.5..1.5, relative: true, description: nil, **options)
          # TODO: Figure out best way to do this for both attack and release
          # velocity.  Sometimes the same parameter should be controlled by
          # both attack and release velocity, so using two separate methods
          # wouldn't work.
          if node.is_a?(Array)
            node.each do |n|
              on_velocity(n, range: range, relative: relative, description: description)
            end

            return
          end

          node = find_node(node)

          info = build_node_info(
            node: node,
            range: range,
            relative: relative,
            description: description,
            options: options,
          )

          p = Parameter.new(
            # TODO: Allow a parameter to specify all-note velocity
            message: MIDIMessage::NoteOn.new(nil, 64, 64),
            update_rate: @update_rate,
            **info.slice(:range, :default, :max_rise, :max_fall, :filter_hz, :description)
          )

          info[:parameter] = p

          @parameters << info
          @velocity_listeners << info

          self
        end

        # Assigns one or more nodes within the graph to the given CC index.
        # The VoicePool and Manager will then set those nodes' values based on
        # MIDI control change events.
        #
        # The +node+ may be the name of a node or a direct reference to a node,
        # or an Array thereof.
        #
        # The +:range+ defaults to 0..1.  If +:relative+ is true (the default),
        # then the range will be multiplicative of the current value of the
        # node.  If +:relative+ is false, then the +:range+ is interpreted as
        # an absolute range.
        #
        # Additional +options+ may be given for the Manager#on_cc method.
        def on_cc(index, node, range: 0.0..1.0, relative: true, description: nil, **options)
          if node.is_a?(Array)
            node.each do |n|
              on_cc(index, n, range: range, relative: relative, description: description, **options)
            end

            return self
          end

          node = find_node(node)

          @cc_map[index] ||= []

          node_info = build_node_info(
            node: node,
            range: range,
            relative: relative,
            description: description,
            options: options.merge(index: index)
          )

          @cc_map[index] << node_info

          self
        end

        # Tells all envelopes to start their release phase.
        def release(note, velocity, timestamp)
          @envelopes.each(&:release)

          @manager_proxy&.graph_voice_release(note, velocity, timestamp)
        end

        # Returns true if any envelopes have not reached the end of their
        # release phase.
        def active?
          @envelopes.any?(&:active?)
        end

        # Generates the next +count+ samples for the voice/graph.
        def sample(count)
          @graph.sample(count)
        end

        # Returns the direct inputs that feed this graph voice (just the graph
        # given to the constructor).
        def sources
          { input: @graph }
        end

        private

        # If +node+ is a String, finds and returns a graph node of the given
        # name within the signal graph.  Otherwise, returns +node+ as is.
        def find_node(node)
          if node.is_a?(String)
            n = @graph.find_by_name(node)
            raise "Node #{node.inspect} not found" if n.nil?
            n
          elsif node.respond_to?(:sample)
            node
          else
            raise "Node #{node.inspect} does not appear to be a signal graph node"
          end
        end

        # Assembles a Hash with getter, setter, etc. about a node for control
        # by a Parameter.  Used in #on_cc and #on_velocity.
        def build_node_info(node:, range:, relative:, description:, options:)
          raise 'Graph nodes must respond to :graph_node_name' unless node.respond_to?(:graph_node_name)

          case
          when node.respond_to?(:constant=)
            getter = node.method(:constant)
            setter = node.method(:constant=)

          else
            raise "Only nodes that have a #constant= method are supported at this time (got #{node.class})"
          end

          base = getter.call

          if relative
            a = base * range.begin
            b = base * range.end
            range = a..b
          end

          description ||= "#{node.graph_node_name || node.class.name} (#{range})"

          options.merge(
            node: node,
            range: range,
            get: getter,
            set: setter,
            default: base,
            description: description
          )
        end
      end
    end
  end
end
