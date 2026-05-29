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

      # Creates a voice pool with voices defined using the GraphNode::MidiDsl
      # API yielded to the block given.
      #
      # TODO: it could make sense to have a synth or pool method on the MIDI
      # DSL as well
      def synth(input_name = nil, osc_count: ENV['OSC_COUNT']&.to_i || 4, channel: ENV['CHANNEL']&.to_i&.-(1))
        raise 'Pass a block to define individual voices' unless block_given?

        # TODO: further automate connecting to an output, parsing command-line
        # options, repeating MIDI files, etc.

        if input_name && input_name.downcase.end_with?('.mid') && File.readable?(input_name)
          clock = MB::Sound::GraphNode::GraphClock.new
          midi_in = MB::Sound::MIDI::MIDIFile.new(input_name, clock: clock)
        end

        unless midi_in
          jack = MB::Sound::JackFFI[]
          midi_in = jack.input(port_type: :midi, port_names: ['synth_midi'], connect: input_name)
          update_rate = jack.buffer_size.to_f / jack.sample_rate
        end

        manager = MB::Sound::MIDI::Manager.new(jack: jack, input: midi_in, update_rate: update_rate)

        voices = Array.new(osc_count) { |idx|
          MB::Sound::MIDI::GraphVoice.new(manager: manager, label: idx) do |midi|
            yield midi, idx
          end
        }

        # TODO: Create a stereo pool or multi-channel pool or something?
        pool = MB::Sound::MIDI::VoicePool.new(manager, voices)
        clock&.node = pool

        # TODO: Write the parameter map to a file if requested.
        puts MB::U.syntax(manager.to_acid_xml, :xml)
        puts "\n" * MB::U.height

        pool
      end
    end
  end
end
