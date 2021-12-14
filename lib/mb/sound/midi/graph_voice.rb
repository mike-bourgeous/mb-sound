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

        # Raised when something is wrong with the modulation constants
        # parameter to the constructor.
        class ModConstantError < ArgumentError
          def initialize(msg = nil)
            msg ||= 'Modulation constants should be a Hash from CC number to a constant ' +
              'or Array of constants (MB::Sound::Constant, MB::Sound::Mixer, or ' +
              'MB::Sound::Multiplier)'

            super(msg)
          end
        end

        # Initializes a voice based on the given signal graph.  If the
        # automatic detection of envelopes and oscillators doesn't work, then
        # the +:amp_envelopes+, +:envelopes+, and +:freq_constants+ parameters
        # may be used to override detection.
        def initialize(graph, amp_envelopes: nil, envelopes: nil, freq_constants: nil, mod_constants: nil)
          @graph = graph

          sources = graph.graph
          puts "Found #{sources.length} total graph nodes" # XXX
          puts MB::U.highlight(sources.map(&:class))

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
          puts "Found #{@freq_constants.length} frequency constants: #{@freq_constants.map(&:__id__)}" # XXX

          @mod_constants = mod_constants
          if @mod_constants
            raise ModConstantError unless @mod_constants.is_a?(Hash)
            raise ModConstantError unless @mod_constants.keys.all?(Integer)

            @mod_constants.each do |cc, constants|
              raise ModConstantError, "Control Change index #{cc} is out of range" if cc < 1 || cc > 127

              if constants.is_a?(Array)
                raise ModConstantError unless constants.all? { |v| v.respond_to?(:constant=) }
              else
                raise ModConstantError unless constants.respond_to?(:constant=)
              end
            end
          end
        end

        def trigger(note, velocity)
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

        # Called by VoicePool when a MIDI CC is received.
        def midi_cc(cc, value)
          @mod_constants[cc]
        end
      end
    end
  end
end
