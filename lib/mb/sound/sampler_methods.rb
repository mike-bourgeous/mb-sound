module MB
  module Sound
    # Sampler commands (see design/notes/sampler.md and MB::Sound::Sample):
    # bouncing graphs into Samples, capturing live audio, SFZ instruments,
    # chop patterns, and sampler voices from MIDI.
    module SamplerMethods
      # Renders graphs offline into a Sample (resampling, pressing a break):
      # +graphs+ (or the graph the block returns; the block runs inside the
      # render's Session) for +length+ (a Duration like `2.bars`, a Length,
      # or a plain number of bars) at +bpm+ (by default the current tempo:
      # the rendering or scheduling session's, including a tempo a scheduled
      # block just queued; see Sequence.current_transport) on a private Transport, so the session's tempo never
      # changes.  The Sample is +channels+ wide (1, mono, by default), at
      # 0 dB master gain, exactly +length+ long, with +root+ (a Note; C4)
      # and the tempo kept for Durations (`rec.at(7.n16)`).  Also
      # GraphNode#bounce.
      #
      #     rec = bounce(2.bars, bpm: 138.75) { tr808(grid(16, kick: 'X.....x...X.....', snare: '....X.......X...')) }
      #     bass = reese.bounce(1.bar, root: F1)
      def bounce(*graphs, bpm: nil, channels: 1, root: 60, gain: 1.0, name: nil, &block)
        length = graphs.pop if graphs.last.is_a?(Numeric) || graphs.last.is_a?(Length)
        raise ArgumentError, 'Give bounce a length (bounce(graph, 2.bars) or bounce(2.bars) { graph })' if length.nil?
        raise ArgumentError, 'Give bounce graphs or a block, not both' if block && !graphs.empty?
        raise ArgumentError, 'Give bounce a graph or a block' if graphs.empty? && block.nil?

        current = Sequence.current_transport
        bpm = (bpm || current.bpm).to_f
        transport = Sequence::Transport.new(bpm: bpm, bar_length: current.bar_length)
        length = length.bars if length.is_a?(Numeric)
        frames = Length.samples(length, sample_rate: 48000, transport: transport).round
        raise ArgumentError, "A bounce needs a positive length (got #{length.inspect})" unless frames > 0

        out = Sampler::CaptureOutput.new(channels: channels)
        if block
          render(out, seconds: Rational(frames, 48000), bpm: bpm, channels: channels, gain: gain) {
            g = block.call
            Session.current.add(g, on: :now) if g.respond_to?(:sample) || g.is_a?(GraphNode::MultiOutput)
          }
        else
          render(out, *graphs, seconds: Rational(frames, 48000), bpm: bpm, channels: channels, gain: gain)
        end
        Sample.new(out.channels(frames), root: root, bpm: bpm, name: name || 'bounce')
      end
      alias resample_to_sample bounce

      # Lists the loop files in +dir+ (recursively) with their tempo,
      # beats, and key from ACID chunks, tags, and file and folder names,
      # without decoding any audio (Sample::LoopInfo); filters by +bpm+ (a
      # number within 1%, or a Range), +key+ (:Am, or an Array), and
      # +beats+.  Reads only: never writes to the files.  Returns a
      # Sample::LoopInfo::List: `list[3].sample` reads one as a Sample.
      #
      #     loops '~/Loops/Funk'
      #     l = loops('~/Loops', bpm: 90..100, key: [:Am, :C])
      #     bg :brk, l[0].sample.follow
      def loops(dir = '.', bpm: nil, key: nil, beats: nil, recursive: true)
        Sample::LoopInfo.list(dir, bpm: bpm, key: key, beats: beats, recursive: recursive)
      end

      # Records live audio into a Sample from a launch point (now by
      # default; `on: :bar`, `at: bar(9)`) for +length+ (a Duration, Length,
      # or bars): the master bus (+from+ :master), or any node (+from+ a
      # graph, e.g. `input` or a synth; it is played silently by a
      # background player).  Returns a Sampler::AudioCapture: `cap.sample`
      # is the Sample once it is done (`cap.done?`, `cap.wait`).
      #
      #     cap = capture_audio(4.bars, on: :bar)
      #     loop = cap.wait.sample.looped
      def capture_audio(length, from: :master, root: 60, at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        session = Session.current
        length = length.bars if length.is_a?(Numeric)
        frames = Length.samples(length, sample_rate: session.sample_rate, transport: session.transport).round
        raise ArgumentError, "A capture needs a positive length (got #{length.inspect})" unless frames > 0

        cap = Sampler::AudioCapture.new(frames, root: root, bpm: session.transport.bpm, channels: from == :master ? session.channels : 1)
        if from == :master
          session.capture_audio(frames, output: cap, at: point, start_time: point.given? ? nil : Session.context&.[](:time))
          session.ensure_running
        else
          raise ArgumentError, "capture_audio records :master or a graph node (got #{from.inspect})" unless from.respond_to?(:sample)
          bg(:"capture_#{cap.object_id}", GraphNode::CaptureTap.new(from, cap), at: point)
        end
        cap
      end

      # An SFZ instrument (Sampler::Instrument) from +path+ (see
      # Sampler::SFZ), its voices reading tables at level spacing +mips+
      # (:octave by default, the lighter one for big sets).
      #
      #     piano = sfz('piano/piano.sfz')
      #     synth(midi) { |v| piano.play(v) }
      def sfz(path, name: nil, mips: :octave)
        Sampler::SFZ.load(path, name: name, mips: mips)
      end

      # A SoundFont 2 instrument (Sampler::Instrument) from +path+ (see
      # Sampler::SF2): +preset+ a GM program number in bank 0 (0 is the
      # piano), [bank, program] ([128, 0] the GM drum kit), or a name
      # ('Strings'; exact, else the one name containing it).  Without a
      # preset, the SF2::Font: `font.presets` lists them, `font[0]`,
      # `font['Pad']`, `font[128, 0]` choose one, and `font.play(v)` plays
      # the first.  Voices read tables at level spacing +mips+ (:octave by
      # default); +attenuation+ scales the font's initialAttenuation (0.4,
      # FluidSynth's and the EMU hardware's factor, by default; 1.0 for the
      # specification's own centibels).
      #
      #     sf2('GM.sf2').presets
      #     piano = sf2('GM.sf2', preset: 0)
      #     synth(midi) { |v| piano.play(v) }
      #     bg :kit, beat.sampler(sf2('GM.sf2', preset: [128, 0]), voices: 8)
      def sf2(path, selector = nil, preset: selector, name: nil, mips: :octave, attenuation: Sampler::SF2::EMU_ATTENUATION)
        font = Sampler::SF2.open(path)
        return font if preset.nil? && name.nil? && mips == :octave && attenuation == Sampler::SF2::EMU_ATTENUATION
        font.instrument(preset, name: name, mips: mips, attenuation: attenuation, path: path)
      end
      alias soundfont sf2

      # A chop pattern for +slices+ (see Sample::Slices#chop).
      #
      #     amen = chop(brk, :k, T, :h, :g, [:s, 2], brk[:s].rev)
      def chop(slices, *steps, per: 1/16r)
        raise ArgumentError, "chop takes slices first (rec.slices(16)), got #{slices.inspect}" unless slices.is_a?(Sample::Slices)
        slices.chop(*steps, per: per)
      end

      # A synth playing MIDI +source+ (a clip, stream, file, live MIDI) on
      # +instrument+ (a Sampler::Instrument, Sample, or Slices) with
      # +voices+ (1 by default; see Sampler::Instrument#sampler).
      #
      #     bg :breaks, sampler(amen, brk)
      def sampler(source, instrument, voices: 1, **options, &block)
        inst = case instrument
               when Sampler::Instrument then instrument
               when Sample::Slices then instrument.instrument
               when Sample then instrument.to_instrument
               when Sampler::SF2::Font then instrument.instrument
               else raise ArgumentError, "Give sampler an Instrument, Sample, or Slices (got #{instrument.inspect})"
               end
        inst.sampler(source, voices: voices, **options, &block)
      end
    end
  end
end
