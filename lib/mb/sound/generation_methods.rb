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

      # Returns a source of zeros for +length+ (seconds or any length, e.g.
      # `480.samples` or `1.bar`), then the end of the stream (see
      # GraphNode::Silence), e.g. for appending a tail with
      # RoutingMethods#and_then.
      def silence(length, sample_rate: 48000)
        MB::Sound::GraphNode::Silence.new(length, sample_rate: sample_rate)
      end

      # Returns a node that generates a single sample impulse followed by
      # silence, for +length+ in all (5 seconds by default; any length).
      def impulse(length = 5)
        tapped = false
        silence(length).named('Single-sample impulse').spy { |d|
          unless tapped
            d[0] = 1
            tapped = true
          end
        }
      end
    end
  end
end
