module MB
  module Sound
    module MIDI
      # A single MIDI synthesizer voice based on an arbitrary signal graph.
      # Every envelope and ArrayInput is restarted when the voice is triggered,
      # and every oscillator with a constant frequency, or a constant value
      # added somewhere in its frequency input, has that constant set to the
      # triggering note frequency.
      class GraphVoice
        include ArithmeticMixin

        attr_reader :number

        # A Hash from CC index to an Array of Hashes describing a controllable
        # parameter.  Used by VoicePool.  See #on_cc.
        attr_reader :cc_map

        # Initializes a voice based on the given signal graph.  If the
        # automatic detection of envelopes and oscillators doesn't work, then
        # the +:amp_envelopes+, +:envelopes+, and +:freq_constants+ parameters
        # may be used to override detection.
        def initialize(graph, amp_envelopes: nil, envelopes: nil, freq_constants: nil)
          @graph = graph

          @number = nil

          sources = graph.graph
          puts "Found #{sources.length} total graph nodes" # XXX

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
          puts "Found #{@oscillators.length} oscillators" # XXX

          @amp_envelopes = amp_envelopes || []
          @envelopes = envelopes || sources.select { |s|
            s.is_a?(MB::Sound::ADSREnvelope)
          }
          @envelopes.each(&:reset) # disable auto-release on envelopes
          puts "Found #{@envelopes.length} envelopes" # XXX

          @array_inputs = sources.select { |s|
            s.is_a?(ArrayInput)
          }
          puts "Found #{@array_inputs.length} array inputs" # XXX

          if freq_constants
            @freq_constants = freq_constants
          else
            @freq_constants = []
            @oscillators.each do |o|
              # Look for the top-most mixer or constant value in the frequency input graph for the oscillator
              # FIXME: this won't handle chained multi-op FM correctly
              g = o.respond_to?(:graph) ? o.graph : [o.frequency]
              mixer = g.select { |s|
                (s.is_a?(MB::Sound::Mixer) || s.is_a?(MB::Sound::Constant)) &&
                  s.constant >= 20 # Haxx to try to separate frequency values from other values; might help to have some kind of units or roles for detecting these things
              }.first
              @freq_constants << mixer if mixer
            end
          end

          @cc_map = {}

          puts "Found #{@freq_constants.length} frequency constants: #{@freq_constants.map(&:__id__)}" # XXX
        end

        # Tells all envelopes to start their attack phase based on the given
        # velocity, and sets all frequency constants based on the given note.
        def trigger(note, velocity)
          @number = note

          puts "Trigger #{note}@#{velocity} (#{MB::Sound::Note.new(note).name})" # XXX
          @oscillators.each do |o|
            o.reset # TODO: make keysync optional
            if o.frequency.is_a?(Numeric)
              o.frequency = MB::Sound::Oscillator.calc_freq(note)
            end
          end

          @freq_constants.each do |fc|
            # TODO: Have a way of setting the note number instead, to allow
            # for logarithmic portamento by filtering through a follower
            fc.constant = MB::Sound::Oscillator.calc_freq(note)
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
        end

        # Assigns one or more nodes within the graph to the given CC index.
        # The VoicePool and Manager will then set those nodes' values based on
        # MIDI control change events.
        #
        # The +node+ may be the name of a node or a direct reference to a node.
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
              cc(index, n, range: range, relative: relative, description: description, **options)
            end

            return
          end

          node = @graph.find_by_name(node) if node.is_a?(String)

          @cc_map[index] ||= []

          case
          when node.respond_to?(:constant=)
            getter = node.method(:constant)
            setter = node.method(:constant=)

          else
            raise 'Only nodes that have a #constant= method are supported at this time'
          end

          base = getter.call

          if relative
            a = base * range.begin
            b = base * range.end
            range = a..b
          end

          description ||= "#{node.graph_node_name} (#{range})"

          @cc_map[index] << options.merge(
            index: index,
            range: range,
            node: node,
            default: base,
            get: getter,
            set: setter,
            description: description
          )

          nil
        end

        # Tells all envelopes to start their release phase.
        def release(note, velocity)
          @envelopes.each(&:release)
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
          [@graph]
        end
      end
    end
  end
end
