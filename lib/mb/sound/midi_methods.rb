module MB
  module Sound
    # Methods included in MB::Sound for working with MIDI files, MIDI-driven
    # synthesizers, etc.
    module MidiMethods
      # Calls a block with a MIDI file to build a node graph, or returns a MIDI
      # DSL based on a MIDI file.
      #
      # Example (bin/sound.rb):
      #     graph = midi_file('spec/test_data/all_notes.mid') { |midi|
      #       midi.tone.ramp.filter(:lowpass, cutoff: midi.frequency + 100) * midi.gate
      #     }
      #     play graph
      def midi_file(filename, speed: 1.0, clock: nil)
        # TODO: end graph execution when the MIDI file has completely finished
        clock ||= MB::Sound::GraphNode::MidiDsl::DslClock.new
        mfile = MB::Sound::MIDI::MIDIFile.new(filename, speed: speed, clock: clock)
        mgr = MB::Sound::MIDI::Manager.new(input: mfile, jack: nil)
        dsl = MB::Sound::GraphNode::MidiDsl.new(manager: mgr)

        clock.dsl = dsl if clock.is_a?(MB::Sound::GraphNode::MidiDsl::DslClock)

        if block_given?
          yield dsl
        else
          dsl
        end
      end

      # Returns a handle for connecting MIDI events to GraphNode networks.  See
      # MidiDsl for details.
      def midi
        # TODO: allow specifying an input/connection by name and then caching the DSL for that input?

        @midi_manager ||= MB::Sound::MIDI::Manager.new
        @midi_dsl ||= MB::Sound::GraphNode::MidiDsl.new(manager: @midi_manager)
      end
    end
  end
end
