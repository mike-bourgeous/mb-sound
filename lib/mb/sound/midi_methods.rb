module MB
  module Sound
    # Methods included in MB::Sound for working with MIDI files, MIDI-driven
    # synthesizers, etc.
    module MidiMethods
      # Returns a MB::Sound::Notes playing the MIDI file +filename+ (a
      # MIDI::FileSource, looping with +:loop+), or the block's result if a
      # block is given: a mono voice (`midi.hz.saw * midi.amp_env`) and a
      # source for synths (`midi.synth(voices: 4) { |v| ... }`), like #midi
      # for live input.  Note nodes apply the sustain pedals unless
      # +sustain: false+ (see Notes.new).
      #
      # Example (bin/sound.rb):
      #     graph = midi_file('spec/test_data/all_notes.mid') { |midi|
      #       midi.hz.ramp.filter(:lowpass, cutoff: midi.freq + 100) * midi.gate
      #     }
      #     play graph
      #     play midi_file('spec/test_data/c_major.mid').synth { |v| v.hz.square * v.amp_env }
      def midi_file(filename, loop: false, sustain: true)
        unless filename.to_s.downcase.end_with?('.mid', '.midi')
          raise ArgumentError, "#{filename} is not a MIDI file (expected .mid or .midi)"
        end

        notes = MB::Sound::Notes.new(MB::Sound::MIDI::FileSource.new(filename, loop: loop), sustain: sustain)
        block_given? ? yield(notes) : notes
      end

      # Returns live MIDI input as a MB::Sound::Notes (notes and controllers
      # as signal nodes; a mono DSL that is also a MIDI source for synths),
      # reading a MIDI::LiveSource that follows the background session's
      # output clock (see MIDI::LiveSource for MIDI_TIMING).  +connect+ is
      # part of a MIDI source's name to connect to, or nil for a port named
      # after the script that other software connects to (see MIDI::Input).
      # Each +connect+ opens one input, cached until #close_midi.  +:quiet+
      # skips the note about the latency profile.  Note nodes (gate,
      # trigger, envelopes, ...) apply the sustain, sostenuto, and soft
      # pedals like a Synth does, unless +sustain: false+ (a separate Notes
      # on the same input; see Notes.new).
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
      #     dry = midi(sustain: false); play dry.hz.saw * dry.gate   # ignore the pedals
      def midi(connect = nil, quiet: false, sustain: true)
        @live_midi ||= {}
        @live_midi_streams ||= {}
        key = [connect, !!sustain]
        notes = @live_midi[key]
        return notes if notes && !notes.stream.source.closed?

        stream = @live_midi_streams[connect]
        if stream.nil? || stream.source.closed?
          # Switches the output only once the input has opened
          source = MB::Sound::MIDI::LiveSource.new(connect: connect)
          live_midi_latency(quiet: quiet)
          source.output = Session.default.output
          stream = @live_midi_streams[connect] = MB::Sound::MIDI::Stream.new(source)
        end

        @live_midi[key] = MB::Sound::Notes.new(stream, sustain: sustain)
      end

      # The MIDI::Stream of live MIDI input from #midi, before the sustain
      # pedals (for transforms and Synth.new, which applies them itself;
      # `Synth.new(midi)` works too).
      def midi_stream(connect = nil)
        midi(connect).stream
      end

      # Closes the live MIDI inputs opened by #midi (later calls open new
      # ones).  Returns nil.
      def close_midi
        (@live_midi_streams || {}).each_value { |stream| stream.source.close }
        @live_midi = {}
        @live_midi_streams = {}
        nil
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
        return if @live_midi_streams.nil? || @live_midi_streams.empty?

        output = Session.default.output
        @live_midi_streams.each_value { |stream| stream.source.output = output }
      end
    end
  end
end
