module MB
  module Sound
    # Methods to help generating sounds, either as source GraphNodes or as an
    # Array of Numo::NArrays.
    #
    # Included in MB::Sound for the bin/sound.rb DSL.
    module GenerationMethods
      # Creates a uniformly distributed white noise generator that can be
      # combined with other tones, filters, etc.  See MB::Sound::GraphNode
      # and MB::Sound::Tone.
      def noise
        2000.hz.ramp.noise
      end

      # Shortcut/DSL method for creating a tone with a given dynamic frequency
      # source, for full control over the FM signal graph.
      def tone(frequency)
        MB::Sound::Tone[frequency]
      end

      # Returns a node sequence that will generate a single sample impulse
      # followed by silence.
      def impulse
        tapped = false
        0.constant.named('Single-sample impluse').or_for(5).spy { |d|
          unless tapped
            d[0] = 1
            tapped = true
          end
        }
      end
    end
  end
end
