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
        mgr = MB::Sound::MIDI::Manager.new(input: mfile)
        dsl = MB::Sound::GraphNode::MidiDsl.new(manager: mgr)

        clock.dsl = dsl if clock.is_a?(MB::Sound::GraphNode::MidiDsl::DslClock)

        if block_given?
          yield dsl
        else
          dsl
        end
      end

      # Returns live MIDI input as a MB::Sound::Notes (notes and controllers
      # as signal nodes; a mono DSL that is also a MIDI source for synths),
      # reading a MIDI::LiveSource that follows the background session's
      # output clock (see MIDI::LiveSource for MIDI_TIMING).  +connect+ is
      # part of a MIDI source's name to connect to, or nil for a port named
      # after the script that other software connects to (see MIDI::Input).
      # Each +connect+ opens one input, cached until #close_midi.  +:quiet+
      # skips the note about the latency profile.
      #
      # Opening live MIDI switches the background session to the :low
      # latency profile unless a profile was chosen (see
      # PlaybackMethods#live_midi_latency).
      #
      # Example (bin/sound.rb):
      #     play midi.hz.saw * midi.amp_env                       # mono
      #     play midi.synth(voices: 6) { |v| v.hz.saw.filter(:lowpass, cutoff: v.cutoff(800)) * v.amp_env }
      #     play Synth.new(midi_stream.transpose(-12)) { |v| v.hz.square * v.amp_env }
      #     midi.mod                                              # the mod wheel, 0..1
      #     midi('Launchkey')                                     # a keyboard by name
      def midi(connect = nil, quiet: false)
        @live_midi ||= {}
        notes = @live_midi[connect]
        return notes if notes && !notes.stream.source.closed?

        # Switches the output only once the input has opened
        source = MB::Sound::MIDI::LiveSource.new(connect: connect)
        live_midi_latency(quiet: quiet)
        source.output = Session.default.output
        @live_midi[connect] = MB::Sound::Notes.new(MB::Sound::MIDI::Stream.new(source))
      end

      # The MIDI::Stream of live MIDI input from #midi (for transforms and
      # Synth.new; `Synth.new(midi)` works too).
      def midi_stream(connect = nil)
        midi(connect).stream
      end

      # Closes the live MIDI inputs opened by #midi (later calls open new
      # ones).  Returns nil.
      def close_midi
        (@live_midi || {}).each_value { |notes| notes.stream.source.close }
        @live_midi = {}
        nil
      end

      # The old MIDI DSL (GraphNode::MidiDsl) on live MIDI, which #midi
      # returned before the Notes rework; kept for old scripts until they
      # move to Notes (see #midi_manager).
      def midi_dsl
        @midi_dsl ||= MB::Sound::GraphNode::MidiDsl.new(manager: midi_manager)
      end

      # Creates and caches a MIDI manager for the given +input_name+, which may
      # be a MIDI filename (any existing file must be .mid or .midi), part of
      # a live MIDI source's name to connect to (an unconnected port with a
      # warning if none matches), or nil for a virtual MIDI port named after
      # the script (see MB::Sound::MIDI::Input; live MIDI goes through RtMidi
      # and never starts a JACK server).
      def midi_manager(input_name = nil)
        @midi_managers ||= {}
        return @midi_managers[input_name] if @midi_managers.include?(input_name)

        if input_name && File.file?(input_name)
          unless input_name.downcase.end_with?('.mid', '.midi')
            raise ArgumentError, "#{input_name} is not a MIDI file (expected .mid or .midi)"
          end

          # FIXME: really need a better way of connecting the clock to the graph
          clock = MB::Sound::GraphNode::GraphClock.new
          midi_in = MB::Sound::MIDI::MIDIFile.new(input_name, clock: clock)
        end

        unless midi_in
          midi_in = MB::Sound::MIDI::Input.new(connect: input_name)

          # Manager#update runs once per audio buffer
          profile = MB::Sound::DeviceOutput::PROFILES[(ENV['AUDIO_PROFILE'] || :default).to_s.delete_prefix(':').to_sym]
          buffer = Integer(ENV['AUDIO_BUFFER'] || profile&.[](:buffer_size) || 512)
          update_rate = 48000.0 / buffer
        end

        manager = MB::Sound::MIDI::Manager.new(input: midi_in, update_rate: update_rate)

        @midi_managers[input_name] = manager
      end

      # A polyphonic MB::Sound::Synth: +source+ is a MIDI source (a Notes
      # such as a synth script's `midi`, a MIDI::Stream or Source, a
      # Sequence::Clip, or a MIDI filename), or nil for live MIDI (#midi).
      # The block builds the graph of one voice from a Notes on the voice's
      # lane (+v+) and the lane index; see Synth.new for the options
      # (+:voices+, +:spares+, +:mono+, +:glide_mode+, +:controls+,
      # +:bend_range+, +:seed+, ...).
      #
      # Examples (bin/sound.rb):
      #     play synth { |v| v.hz.saw.filter(:lowpass, cutoff: v.cutoff(800)) * v.amp_env }
      #     play synth('spec/test_data/c_major.mid', voices: 4) { |v| v.hz.square * v.amp_env(0.01, 0.3, 0.5, 0.4) }
      #     play synth(midi, voices: 1) { |v| v.hz.glide(60.ms).saw * v.amp_env.legato }   # mono
      def synth(source = nil, voices: 8, **options, &block)
        raise ArgumentError, 'Pass a block that builds one voice from |v, index|' unless block

        MB::Sound::Synth.new(source.nil? ? midi : source, voices: voices, **options, &block)
      end

      private

      # Points the live MIDI sources of #midi at the background session's
      # current output (see PlaybackMethods#use_output).
      def retarget_live_midi
        return if @live_midi.nil? || @live_midi.empty?

        output = Session.default.output
        @live_midi.each_value { |notes| notes.stream.source.output = output }
      end
    end
  end
end
