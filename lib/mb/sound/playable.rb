module MB
  module Sound
    # How things play: the one conversion from anything #play, #bg, #render,
    # and #write accept to the graph that plays it (an Array of GraphNodes,
    # one per channel), with a description, whether it ends by itself, and
    # a note on how it was turned into sound.
    #
    # Accepted (see Playable.graph):
    # - GraphNodes, channel bundles, and inputs (their channels; a Pitch
    #   plays as a sine, an Envelope on its own as the level of a soft
    #   triangle)
    # - Arrays: one channel or sound per element (numbers make one channel)
    # - Numo::NArray audio (48 kHz; one channel, or an Array of channels)
    # - Strings: sound files, MIDI files (the default patch), .sfz and .sf2
    #   instruments (a demo phrase)
    # - Sample (once, stereo kept), Sample::Slices (the slices in order,
    #   with gaps), Sampler::Instrument and SF2 fonts (a demo phrase)
    # - Clips and grids (the default patch, or a TR-808 for a grid), Notes,
    #   MIDI Streams (the default patch), Drums::Machine designs (each
    #   voice once), Wavetables (one note)
    # - Symbols naming a saved preset (a synth preset plays a demo phrase)
    #   or a genre template (see PlaybackMethods#play)
    # - anything with #to_playable returning one of these (the protocol
    #   for new types)
    #
    # Anything else raises Unplayable (an ArgumentError) naming the type
    # and the ways to play it that it offers.
    module Playable
      # Raised for things that can't be played, with a message saying what
      # to do instead (an ArgumentError, as Session#add raised before).
      class Unplayable < ArgumentError; end

      # What Playable.graph returns: +nodes+ (one GraphNode per channel),
      # a +description+ for #players and play's header, +ends+ (true if it
      # ends by itself, false if it plays until stopped, nil if unknown:
      # graphs with oscillators play forever), and a +note+ on how it was
      # turned into sound (nil for things that are already graphs).
      Graph = Data.define(:nodes, :description, :ends, :note)

      # The default patch for notes without one (Clips, Notes, MIDI files
      # and Streams) and the keyboard pane's (UI::Keyboard::Link::PATCH is this
      # one): a soft filtered saw.
      PATCH = proc { |v| v.hz.ramp.filter(:lowpass, cutoff: v.cutoff(1800), quality: 0.9) * v.amp_env(0.004, 0.4, 0.6, 0.3) * 0.5 }

      # Voices of the default patch and demo phrases.
      VOICES = 8

      # Silence between slices when Slices play (seconds).
      SLICE_GAP = 0.15

      # At most this many slices of a Slices play.
      MAX_SLICES = 64

      module_function

      # Converts +sound+ to a Graph (see the module description).  Raises
      # Unplayable for things that can't be played.  Sound files are read
      # at +sample_rate+ (ffmpeg resamples them).
      def graph(sound, sample_rate: 48000)
        case sound
        when Graph
          sound

        when Envelope
          wrap(220.hz.triangle.at(0.5) * sound, "#{sound} on a 220 Hz triangle", nil,
            'an envelope plays as the level of a triangle; multiply it into your own sound: `220.hz.saw * env`')

        when GraphNode, GraphNode::MultiOutput
          Graph.new(nodes: sound.outputs, description: describe(sound), ends: nil, note: nil)

        when Numo::NArray
          raise Unplayable, 'Cannot play an empty array' if sound.empty?
          data = sound.ndim == 2 ? sound.to_a.map { |c| Numo::SFloat.cast(c) } : [sound]
          audio(data)

        when Array
          array(sound, sample_rate: sample_rate)

        when String
          string(sound, sample_rate: sample_rate)

        when Symbol
          symbol(sound)

        when Sample
          wrap(sound.node, sound.to_s, !looping_sample?(sound), nil)

        when Sample::Slices
          slices(sound)

        when Sampler::SF2::Font
          instrument(sound.instrument, "#{sound.instrument} (the first preset of #{File.basename(sound.path.to_s)})")

        when Sampler::Instrument
          instrument(sound, sound.to_s)

        when Sequence::Kit
          ends = !sound.rows.values.any?(&:looping?)
          if (m = sound.instrument)
            wrap(m.kit(sound), "#{label(m)}: #{sound}", ends, nil)
          else
            wrap(MB::Sound.tr808(sound), "tr808: #{sound}", ends,
              'a grid plays on a TR-808; choose a kit with `tr909(beat)`, or `beat.played_by(Drums::TR909)`')
          end

        when Sequence::Clip
          if (inst = sound.instrument)
            node = inst.respond_to?(:sampler) ? sound.sampler(inst) : inst.kit(sound)
            wrap(node, "#{label(inst)}: #{sound}", !sound.looping?, nil)
          else
            wrap(sound.synth(voices: VOICES, &PATCH), sound.to_s, !sound.looping?,
              'notes play on a soft saw; choose a sound with `clip.synth { |v| v.hz.square * v.amp_env }` or `clip.played_by(instrument)`')
          end

        when Notes
          wrap(sound.synth(voices: VOICES, &PATCH), sound.to_s, nil,
            'notes play on a soft saw; choose a sound with `notes.synth { |v| v.hz.square * v.amp_env }`')

        when MIDI::Stream
          wrap(MB::Sound.synth(sound, voices: VOICES, &PATCH), sound.to_s, nil,
            'notes play on a soft saw; choose a sound with `synth(stream) { |v| v.hz.square * v.amp_env }`')

        when Drums::Machine
          machine(sound)

        when Wavetable
          wrap(MB::Sound::C4.wavetable(sound).at(0.5) * MB::Sound.env([[1, 0.005], [0, 1.5, 40]]), "#{sound} at C4", true,
            'a wavetable plays one note; play it yourself with `C4.wavetable(table) * env(...)`')

        when Genre::Template
          raise Unplayable, "A genre template sets up tracks, scenes, and a form: `play genre(:#{sound.name})` " \
            "(foreground), `genre(:#{sound.name}).play` (background), or `.setup` to play it by hand"

        when Form
          raise Unplayable, 'A form plays the scenes and tracks of the Session: `play_form form` (or `flow do ... end`)'

        when nil
          raise Unplayable, 'Nothing to play (got nil)'

        else
          if sound.respond_to?(:to_playable)
            graph(sound.to_playable, sample_rate: sample_rate)
          else
            raise Unplayable, unplayable_message(sound)
          end
        end
      end

      # True if +data+ is plain audio for IOMethods#write: an NArray, an
      # Array of numbers, or an Array of NArrays or number Arrays (one per
      # channel).
      def audio_data?(data)
        data.is_a?(Numo::NArray) || Internal.is_numeric_array?(data) ||
          (data.is_a?(Array) && !data.empty? && data.all? { |c| c.is_a?(Numo::NArray) || Internal.is_numeric_array?(c) })
      end

      # The channels of +sound+'s graph (see .graph), as Session#add plays
      # them.
      def nodes(sound, sample_rate: 48000)
        graph(sound, sample_rate: sample_rate).nodes
      end

      # A one-line message for something that can't be played: its type and
      # the ways to play it that it has.
      def unplayable_message(sound)
        ways = []
        ways << '`play x.node`' if sound.respond_to?(:node) || sound.respond_to?(:to_node)
        ways << '`play x.synth { |v| v.hz.saw * v.amp_env }`' if sound.respond_to?(:synth)
        ways << '`play clip.sampler(x)`' if sound.respond_to?(:sampler)
        ways << '`synth(midi) { |v| x.play(v) }` (it plays as a synth voice)' if sound.respond_to?(:play) && !ways.any? { |w| w.include?('sampler') }
        ways << '`play x.form` (or `play_form`)' if sound.respond_to?(:form) && sound.form
        hint = ways.empty? ? 'play takes graphs, samples, clips, instruments, files, and audio arrays (see `help :play`)' : "try #{ways.first(3).join(', or ')}"
        text = sound.inspect.to_s.lines.first.to_s.strip
        text = "#{text[0, 57]}..." if text.length > 60
        "Can't play #{sound.class.name || sound.class} #{text}: #{hint}"
      end

      # The Graph of an Array: numbers make one channel; an Array of
      # NArrays or number Arrays makes one channel each; anything else
      # plays one sound per element (each with its own channels).
      def array(list, sample_rate: 48000)
        raise Unplayable, 'Cannot play an empty Array' if list.empty?

        if Internal.is_numeric_array?(list)
          data = list[0].is_a?(Array) ? list.map { |c| Numo::SFloat.cast(c) } : [Numo::SFloat.cast(list)]
          return audio(data)
        end

        return audio(list) if list.all? { |c| c.is_a?(Numo::NArray) && c.ndim == 1 }

        parts = list.map { |s| graph(s, sample_rate: sample_rate) }
        ends = parts.map(&:ends)
        Graph.new(
          nodes: parts.flat_map(&:nodes),
          description: parts.map(&:description).join(', '),
          ends: ends.all?(true) ? true : (ends.any?(false) ? false : nil),
          note: parts.map(&:note).compact.uniq.join('; ').then { |n| n.empty? ? nil : n }
        )
      end

      # Audio data (an Array of NArrays, one per channel) played once.
      def audio(data)
        input = ArrayInput.new(data: data)
        frames = data.map(&:length).max
        Graph.new(nodes: input.outputs, description: "#{data.length} channel#{'s' unless data.length == 1} of #{frames} samples", ends: true, note: nil)
      end

      # A sound file, MIDI file, or SFZ/SF2 instrument.
      def string(path, sample_rate: 48000)
        unless File.exist?(path)
          found = Dir[File.join(File.dirname(path), '*')].map { |f| File.join(File.dirname(path), File.basename(f)) }
          raise Unplayable, "No file #{path.inspect} to play#{GraphIO.suggest(path, found)}"
        end

        case File.extname(path).downcase
        when '.mid', '.midi'
          wrap(MB::Sound.synth(MB::Sound.midi_file(path), voices: VOICES, &PATCH), "#{File.basename(path)} on the default patch", true,
            'MIDI plays on a soft saw; choose a sound with `synth(midi_file(path)) { |v| v.hz.square * v.amp_env }`')
        when '.sfz'
          instrument(MB::Sound.sfz(path), File.basename(path))
        when '.sf2'
          graph(MB::Sound.sf2(path))
        else
          node = MB::Sound.file_input(path, resample: sample_rate.round)
          Graph.new(nodes: node.outputs, description: file_description(path), ends: true, note: nil)
        end
      end

      # A preset (see GraphIO.find_preset) or genre template named +name+.
      def symbol(name)
        preset = GraphIO.find_preset(name)
        genre = Genre.names.include?(name)
        if preset && genre
          raise Unplayable, "#{name.inspect} is both a preset and a genre: `play preset(#{name.inspect})` or `play genre(#{name.inspect})`"
        elsif genre
          raise Unplayable, "Play a genre with `play genre(#{name.inspect})`" # (handled by #play before it gets here)
        elsif preset.nil?
          names = GraphIO.presets.values.flatten + Genre.names
          raise Unplayable, "No preset or genre #{name.inspect} to play#{GraphIO.suggest(name, names)} (`presets` and `genres` list them)"
        end

        doc = GraphIO.parse(preset)
        if doc.kind == :set
          raise Unplayable, "#{name.inspect} is a set: `doc = preset #{name.inspect}`, then `play_form doc.form` or `go :scene`"
        end

        inputs = doc.inputs
        if inputs.empty?
          wrap(MB::Sound.preset(name), "preset #{name.inspect}", nil, nil)
        elsif inputs == [:midi]
          wrap(MB::Sound.preset(name, midi: demo_phrase), "preset #{name.inspect} playing a demo phrase", true,
            "a synth preset plays a demo phrase; give it notes with `preset #{name.inspect}, midi: clip`")
        else
          raise Unplayable, "Preset #{name.inspect} needs #{inputs.map(&:inspect).join(', ')}: `play preset(#{name.inspect}, #{inputs.map { |i| "#{i}: ..." }.join(', ')})`"
        end
      end

      # The slices of +slices+ in order, each followed by SLICE_GAP seconds
      # of silence, so the cuts are easy to hear.
      def slices(slices)
        count = MB::M.min(slices.length, MAX_SLICES)
        parts = Array.new(count) { |i| slices[i].node }
        channels = parts.map { |p| p.outputs.length }.max
        nodes = Array.new(channels) { |c|
          GraphNode::NodeSequence.new(parts.flat_map { |p| [p.outputs[c % p.outputs.length], MB::Sound.silence(SLICE_GAP)] })
        }
        more = slices.length > count ? " (the first #{count})" : ''
        Graph.new(nodes: nodes, description: "#{slices}, one by one#{more}", ends: true,
          note: 'slices play in order with gaps; `play brk.sample` for the whole, `bg brk.chop(0, 1, ...).sampler(brk)` for a pattern')
      end

      # An instrument playing a demo phrase (see .demo_phrase).
      def instrument(inst, description)
        clip = demo_phrase(inst)
        voices = inst.split ? 1 : VOICES
        wrap(inst.sampler(clip, voices: voices), "#{description} playing a demo phrase", true,
          'an instrument plays a demo phrase; play it with `inst.sampler(clip)` or `synth(midi) { |v| inst.play(v) }`')
      end

      # A short phrase of Notes for +inst+ (an Instrument, or nil for any
      # synth): a C major arpeggio and chord when the instrument plays
      # every key from C3 to C5 at pitch, else each region's first key in
      # turn (drum kits, slice keymaps).
      def demo_phrase(inst = nil)
        if inst.nil? || melodic?(inst)
          MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4, MB::Sound::C5).n8 |
            MB::Sound.seq(MB::Sound::C4.n2 & MB::Sound::E4.n2 & MB::Sound::G4.n2)
        else
          keys = regions_of(inst).map { |r| r.keys[0] }.uniq.sort.first(16)
          MB::Sound.seq(*keys.map { |k| Note.new(k) }).n8
        end
      end

      # True if +inst+ plays every key from C3 to C5 with keytracking (a
      # melodic instrument rather than a drum kit or slices).
      def melodic?(inst)
        keys = Array.new(128, false)
        regions_of(inst).each do |r|
          next if r.keytrack.to_f == 0
          (r.keys[0]..r.keys[1]).each { |k| keys[k] = true }
        end
        (48..72).all? { |k| keys[k] }
      end

      # The regions of +inst+ and its layers.
      def regions_of(inst)
        inst.layers ? inst.layers.flat_map { |l| regions_of(l) } : inst.regions
      end

      # A drum machine design: each voice once, an eighth note apart.
      def machine(m)
        names = m.names.first(16)
        rows = names.each_with_index.to_h { |n, i| [n, "#{'.' * i}x#{'.' * (names.length - 1 - i)}"] }
        wrap(m.kit(m.grid(8, **rows)), "#{m} (each voice once)", true,
          'a kit design plays each voice once; play it with `m.kit(m.grid(16, kick: "x...", ...))` or `m.kit(midi)`')
      end

      # True if +sample+ loops (forever, once started).
      def looping_sample?(sample)
        [:forward, :ping_pong].include?(sample.loop_mode)
      end

      # A short name for an instrument: a drum machine module's last name
      # part (tr909), else its #to_s.
      def label(inst)
        inst.is_a?(Module) ? inst.name.split('::').last.downcase : inst.to_s
      end

      # A Graph of +node+ (a node or bundle).
      def wrap(node, description, ends, note)
        Graph.new(nodes: node.outputs, description: description, ends: ends, note: note)
      end

      # The description of a graph: its last node's #to_s, looking through
      # wrapper nodes (TimeLimit, Ringdown; anything with
      # #wrapped_description) and Tee branches to the node they wrap, with
      # the wrapper's label after its name (e.g. "lp4/id=12 until 2 bars --
      # lp4(800.0 Hz, r=0.0)"), or a file input's filename.
      def describe(sound)
        case sound
        when GraphNode
          sound.graph.detect { |n| n.respond_to?(:filename) }&.filename || node_description(sound)
        when GraphNode::MultiOutput
          sound.outputs.map { |o| describe(o) }.uniq.join(', ')
        when Array
          sound.map { |s| describe(s) }.join(', ')
        else
          MB::U.highlight(sound).to_s
        end
      end

      # See .describe.
      def node_description(node)
        node = node.owner_tee.original_source while node.is_a?(GraphNode::Tee::Branch) && node.owner_tee.original_source
        return node.to_s unless node.respond_to?(:wrapped_description)

        inner, label = node.wrapped_description
        head, sep, rest = node_description(inner).partition(' -- ')
        "#{head} #{label}#{sep}#{rest}"
      end

      # A sound file's name and tags.
      def file_description(path)
        tags = FFMPEGInput.parse_info(path).dig(:format, :tags)
        tags && !tags.empty? ? "#{path}: #{MB::U.highlight(tags)}" : path
      rescue StandardError
        path
      end
    end
  end
end
