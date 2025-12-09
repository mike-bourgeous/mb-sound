module MB
  module Sound
    module GraphNode
      class MidiDsl
        # Included by MidiDsl in objects it creates to get notified when their
        # sample rate changes, so that MidiDsl can update its internal object
        # caches.
        module RateDecacher
          # Overrides #at_rate and #sample_rate= to notify MidiDsl when an
          # object's sample rate changes.
          def at_rate(sample_rate)
            @midi_dsl.rate_changed(self)
            super
          end
          alias sample_rate= at_rate
        end
      end
    end
  end
end
