module MB
  module Sound
    module MIDI
      # A single MIDI synthesizer voice based on an arbitrary signal graph.
      # Every envelope and ArrayInput is restarted when the voice is triggered,
      # and every oscillator with a constant frequency, or a constant value
      # added somewhere in its frequency input, has that constant set to the
      # triggering note frequency.
      class GraphVoice
        # Initializes a voice based on the given signal graph.
        def initialize(graph)
          @graph = graph

          sources = graph.graph
          puts "Found #{sources.length} total graph nodes" # XXX

          @oscillators = sources.select { |s|
            s.is_a?(MB::Sound::Tone) || s.is_a?(MB::Sound::Oscillator)
          }
          puts "Found #{@oscillators.length} oscillators" # XXX

          @envelopes = sources.select { |s|
            s.is_a?(MB::Sound::ADSREnvelope)
          }
          @envelopes.each(&:trigger)
          @envelopes.each(&:release)
          @envelopes.each(&:reset) # disable auto-release on envelopes
          puts "Found #{@envelopes.length} envelopes" # XXX

          @array_inputs = sources.select { |s|
            s.is_a?(ArrayInput)
          }
          puts "Found #{@array_inputs.length} array inputs" # XXX

          @freq_constants = {}
          @oscillators.each do |o|
            # Look for the top-most mixer or constant value in the frequency input graph for the oscillator
            # FIXME: this won't handle chained multi-op FM correctly
            g = o.respond_to?(:graph) ? o.graph : [o.frequency]
            mixer = o.graph.select { |s| s.is_a?(MB::Sound::Mixer) || s.is_a?(MB::Sound::Constant) }.last
            @freq_constants[o] = mixer if mixer

            o.forever if o.respond_to?(:forever)
          end

          puts "Found #{@freq_constants.length} frequency constants" # XXX
        end

        def trigger(note, velocity)
          @oscillators.each do |o|
            if o.frequency.is_a?(Numeric)
              o.frequency = MB::Sound::Oscillator.calc_freq(note)
            elsif @freq_constants.include?(o)
              # TODO: Have a way of setting the note number instead, to allow
              # for logarithmic portamento by filtering through a follower
              @freq_constants[o].constant = MB::Sound::Oscillator.calc_freq(note)
            end
          end

          @envelopes.each do |env|
            env.trigger(MB::M.scale(velocity, 0..127, -24..-6).db)
          end

          @array_inputs.each do |ai|
            ai.offset = 0
          end
        end

        # Generates the next +count+ samples for the voice/graph.
        def sample(count)
          @graph.sample(count)
        end
      end
    end
  end
end
