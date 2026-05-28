module MB
  module Sound
    module GraphNode
      class MidiDsl
        # Checks for whether the MIDI file has ended and invalidates DSL caches
        # at the start of the #sample method.
        #
        # Prepend this in MIDI DSL nodes' base classes.
        module MidiEof
          # Intercepts audio generation to trigger reading MIDI input and
          # invalidate the DSL cache.  Returns nil to stop the node graph if
          # reading from a MIDI file and the file has ended (see
          # MB::Sound::MIDI::MIDIFile#done?).
          def sample(count)
            # TODO: Allow for ringdown time of filters/envelopes/etc.
            # TODO: support looping MIDI files
            return nil if @dsl.nil? || @dsl.done?

            @dsl.invalidate_cache(self) unless @cache_invalidated
            @cache_invalidated = true

            # FIXME: this will totally screw up parameter smoothing because it gets called N times per frame for N MIDI nodes
            @dsl.manager.update

            super
          end
        end
      end
    end
  end
end
