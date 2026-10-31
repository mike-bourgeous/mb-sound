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
      #       midi.hz.saw.filter(:lowpass, cutoff: midi.freq + 100) * midi.gate
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

      # Returns one track of the MIDI file +filename+ as a Sequence::Clip
      # (MIDI::Import#clip; design/notes/midi.md, Clips from MIDI files):
      # notes at exact positions from the file's ticks (so files without
      # a tempo event are fine), looping by default over whole bars of the
      # file's meter, with velocities as played, legato overlaps of a
      # monophonic track marked as slides (`~`), chords kept, and the
      # track's controllers (CCs, pitch bend, pressure) as controller
      # lanes that voices read (`v.mod`, `v.cc(1)`, `v.bend`).
      #
      # +track:+ a name (or a unique part of one) or index, needed when
      # several tracks have notes (`midi_tracks(path)` lists them);
      # +channel:+ (0-based) keeps one channel; +from:+ skips that many
      # bars and +bars:+ sets the length (else up to the bar line after the
      # last note); +loop: false+ for a one-shot.
      #
      # +slides:+ :auto, true, false, or a share of the note for the :auto
      # rule's half (0.25 tighter, 1 looser); +cc:+ :steps (as recorded),
      # :fit (fitted curves: a few keys that play smoothly,
      # Clip#fit_controls), false, or an Array of CC numbers and
      # :bend/:pressure; +timing: :performed+ keeps the
      # file's tempo map (rubato) at the session tempo instead of the
      # score's bars; +sustain: false+ ignores the sustain pedal (keeping
      # it as a lane).
      #
      # Example (bin/sound.rb):
      #     midi_tracks 'one_eighty.mid'
      #     bass = midi_clip('one_eighty.mid', track: 'Bass', bars: 8, from: 16, cc: :fit)
      #     bg :bass, bass.synth(voices: 1) { |v| v.hz.saw.lp4(v.mod.at(200..4000)) * v.amp_env }
      def midi_clip(filename, track: nil, channel: nil, bars: nil, from: 0, loop: true, slides: :auto, cc: :steps, timing: :score, sustain: true)
        MB::Sound::MIDI::Import.new(midi_import_path(filename)).clip(
          track: track, channel: channel, bars: bars, from: from, loop: loop, slides: slides, cc: cc, timing: timing, sustain: sustain
        )
      end

      # Returns the drum tracks of the MIDI file +filename+ (channel 10, or
      # tracks named like kick, snare, hat; or +track:+ names or indexes)
      # as a Sequence::Kit with one row per drum, named like grid rows
      # (:kick, :snare, :closed_hat, ...), so drum machines play it like a
      # grid: `tr909(midi_kit('beat.mid'))`.  +bars:+, +from:+, +loop:+,
      # and +timing:+ as for #midi_clip.
      #
      #     beat = midi_kit('n2a.mid', bars: 2)
      #     bg :drums, tr808(beat)
      def midi_kit(filename, track: nil, bars: nil, from: 0, loop: true, timing: :score)
        MB::Sound::MIDI::Import.new(midi_import_path(filename)).kit(track: track, bars: bars, from: from, loop: loop, timing: timing)
      end

      # Lists the tracks of the MIDI file +filename+ (MIDI::Import::TrackList,
      # one line per track: index, name, channels, notes and range, mono
      # or the most notes at once, controller lanes), for picking
      # #midi_clip's +track:+.
      def midi_tracks(filename)
        MB::Sound::MIDI::Import.new(midi_import_path(filename)).tracks
      end

      private def midi_import_path(filename)
        unless filename.to_s.downcase.end_with?('.mid', '.midi')
          raise ArgumentError, "#{filename} is not a MIDI file (expected .mid or .midi)"
        end
        filename
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
      # The input is read through the session's MIDI input
      # (Session::MidiInput): the session reads it once per buffer and
      # every graph playing it gets the events on the same frames, which
      # recordings (`rec`, `capture`) and the take's MIDI log see too, so a
      # saved take replays what was played.
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
        input = attach_live_midi(Session.current, connect, quiet: quiet)
        key = [connect, !!sustain]
        notes = @live_midi[key]
        return notes if notes && notes.stream.source.respond_to?(:hub) && notes.stream.source.hub.equal?(input) && !input.closed?

        # One stream per input, shared by its Notes (with and without pedals)
        @live_midi_taps ||= {}.compare_by_identity
        stream = @live_midi_taps[input] ||= input.stream
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
        @live_midi_taps = {}.compare_by_identity
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

      # A value that differs per synth voice, for use inside a synth's voice
      # block: a list of values gives one value per lane (repeating from the
      # start when the list is shorter than the lanes), and a Range spreads
      # evenly across the lanes (voices plus spares; the first lane gets the
      # range's start and the last its end).  The voice-level sibling of
      # MultichannelMethods#per_channel (inside a voice block, #channels and
      # #per_channel keep their multichannel meaning).
      #
      # Examples (bin/sound.rb):
      #     # voices detuned from -10 to +10 cents, alternately panned left and right
      #     play synth(voices: 4) { |v| (v.hz.transpose(per_voice(-0.1..0.1)).saw * v.amp_env).pan(per_voice(-0.5, 0.5)) }
      def per_voice(*items)
        items = items[0] if items.length == 1 && items[0].is_a?(Array)
        raise ArgumentError, 'per_voice needs at least one value or a Range' if items.empty?

        lane = MB::Sound::Synth.current_lane
        raise ArgumentError, 'per_voice is for synth voice blocks (e.g. synth { |v| v.hz.saw.at(per_voice(0.5, 0.3)) })' unless lane

        index, count = lane
        if items.length == 1 && items[0].is_a?(Range)
          GraphNode::ChannelSpread.new(items[0]).value(index, count)
        else
          items[index % items.length]
        end
      end

      # A MIDI controller as a moving parameter for MIDI transforms
      # (MIDI::Param::CC): the last value of controller +number+ seen on the
      # transform's own input stream (a keyboard's knobs steer its own
      # notes), else on the Session's MIDI input (a clip's transforms
      # steered from a controller), else +default+ (a raw value 0..127),
      # mapped onto +range+ with +curve+ (:linear, :exp, :switch; MB::Sound::Param::CURVES has the aliases).
      # Read once per decision (each note-on, arp step, bar).  Combines with
      # numbers, knobs, and other params (`0.5 + cc(1) * 0.2`).
      #
      #     midi.swing(cc(1, 0.5..0.7))
      #     riff.loop.stream.chance(cc(2))
      #     midi.humanize(cc(3, 0..0.03), velocity: cc(4, 0..0.3))
      def cc(number, range = 0.0..1.0, curve: :linear, default: nil, channel: nil, name: nil)
        MIDI::Param::CC.new(number, range, curve: curve, default: default, channel: channel, name: name)
      end

      private

      # Returns +session+'s MIDI input named +connect+ (see
      # Session::MidiIn#midi_in), giving it live MIDI input (opened by name
      # with +connect+, once until #close_midi) unless it has an open input
      # or replays a take.
      def attach_live_midi(session, connect = nil, quiet: false)
        input = session.midi_in(connect)
        return input if input.replaying? || (input.input && !input.closed?)

        @live_midi_streams ||= {}
        stream = @live_midi_streams[connect]
        if stream.nil? || stream.source.closed?
          # Switches the output only once the input has opened
          source = MB::Sound::MIDI::LiveSource.new(connect: connect)
          live_midi_latency(quiet: quiet)
          source.output = Session.default.output
          stream = @live_midi_streams[connect] = MB::Sound::MIDI::Stream.new(source)
          # (the latency switch may have replaced the default session)
          session = Session.current
          input = session.midi_in(connect)
        end

        input.input = stream unless input.input.equal?(stream)
        input
      end

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
