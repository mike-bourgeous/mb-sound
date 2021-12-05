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
          sources = graph.graph

          @oscillators = sources.select { |s|
            s.is_a?(Tone) || s.is_a?(Oscillator)
          }

          @envelopes = sources.select { |s|
            s.is_a?(ADSREnvelope)
          }

          @array_inputs = sources.select { |s|
            s.is_a?(ArrayInput)
          }

          @freq_constants = {}
          @oscillators.each do |o|
            # Look for the top-most mixer or constant value in the frequency input graph for the oscillator
            g = o.respond_to?(:graph) ? o.graph : [o.frequency]
            mixer = o.graph.select { |s| s.is_a?(MB::Sound::Mixer) || s.is_a?(MB::Sound::Constant) }.last
            @freq_constants[o] = mixer if mixer

            o.forever
          end
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
      end
    end
  end
end
