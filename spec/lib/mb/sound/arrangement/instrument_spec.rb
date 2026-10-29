# Library instruments as tracks' patches (library-instruments-1): an
# instrument Entry or a preset's name given to `track` (with or without the
# clip it plays) is the patch `{ |clip| preset :x, midi: clip }`; effects
# say where they go; a playing track given another instrument is built
# again at its launch point (one undo step); set documents print it as
# `track :bass, :dnb_reese`.
RSpec.describe(MB::Sound::Arrangement::InstrumentPatch, :aggregate_failures) do
  RIFF = MB::Sound.seq(MB::Sound::F1, MB::Sound::T, MB::Sound::R, MB::Sound::Ab1).n8.loop

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  # A Session that runs +setup+ (in its context), then plays +buffers+
  # buffers (running +acts+ { buffer index => Proc } on the way); returns
  # [session, left channel].
  def run(setup, buffers: 120, acts: {})
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
    s = MB::Sound::Session.new(output: out, realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) { setup.call(s) }
    buffers.times do |i|
      (a = acts[i]) && MB::Sound::Session.with_context(session: s) { a.call(s) }
      s.process_buffer
    end
    [s, Numo::DFloat.cast(out.captured[0])]
  end

  it 'plays an instrument Entry, a preset name, and a clip with an instrument like the patch block' do
    _, ref = run(->(_s) { MB::Sound.track(:bass) { |clip| MB::Sound.preset(:dnb_reese, midi: clip) }; MB::Sound.bg(:bass, RIFF) })
    expect(ref.abs.max).to be > 0.01
    [
      -> { MB::Sound.track(:bass, MB::Sound::L.inst.dnb.dnb_reese) },
      -> { MB::Sound.track(:bass, :dnb_reese) },
      -> { MB::Sound.track(:bass, RIFF, :dnb_reese) },
      -> { MB::Sound.track(:bass, MB::Sound::L.inst.dnb.dnb_reese, RIFF) },
      -> { MB::Sound.track(:bass, &MB::Sound::L.inst.dnb.dnb_reese) },
    ].each do |define|
      result = nil
      s, got = run(->(_s) { result = define.call; MB::Sound.bg(:bass, RIFF) })
      expect(result).to eq(:bass)
      expect(got).to eq(ref)
      expect(s.arrangement.tracks[:bass].patch?).to eq(true)
    end
  end

  it 'keeps the clip given with an instrument as the track clip, so a scene saying :on plays it' do
    s, got = run(->(_s) { MB::Sound.track(:bass, RIFF, :dnb_sub); MB::Sound.scene(:a, bass: :on); MB::Sound.go(:a, on: :now) })
    expect(s.arrangement.tracks[:bass].clip).to equal(RIFF)
    expect(got.abs.max).to be > 0.01
  end

  it 'plays an SQ-80 patch, a genre patch, and a drum machine from the track clip' do
    {
      MB::Sound::L.inst.sq80.classic => RIFF,
      :house_bass => RIFF,
      :tr909 => MB::Sound.grid(16, kick: 'x...x...').loop,
    }.each do |inst, clip|
      _, got = run(->(_s) { MB::Sound.track(:x, inst); MB::Sound.bg(:x, clip) }, buffers: 60)
      expect(got.abs.max).to be > 0.001, inst.inspect
    end
  end

  it 'explains effects with a spelling that runs, and suggests names' do
    s = MB::Sound::Session.new(realtime: false)
    @sessions << s
    MB::Sound::Session.with_context(session: s) do
      err = nil
      expect { MB::Sound.track(:bass, MB::Sound::L.fx.hall) }.to raise_error(described_class::Error) { |e| err = e }
      expect(err.message).to include('L.fx.hall is an effect (reverb :hall)', 'track(:bass) { |clip| preset(:dnb_reese, midi: clip).then(&L.fx.hall) }')
      # (the example in the message runs)
      example = err.message[/e\.g\. (.*?), or on a bus/, 1]
      expect(MB::Sound.module_eval(example)).to eq(:bass)
      expect(s.arrangement.tracks[:bass].patch?).to eq(true)
      bus_example = err.message[/on a bus: (bus\(.*\})\z/, 1]
      expect(bus_example).to eq('bus(:fx) { |sig| sig.then(&L.fx.hall) }')

      expect { MB::Sound.track(:x, :dnbreese) }.to raise_error(described_class::Error, /no instrument dnbreese \(did you mean :dnb_reese\?\)/)
      expect { MB::Sound.track(:x) }.to raise_error(ArgumentError, /track :x, L\.inst\.dnb\.dnb_reese/)
      expect { MB::Sound.track(:x, :dnb_reese) { |c| c } }.to raise_error(ArgumentError, /an instrument or a patch block, not both/)
      expect { MB::Sound.track(:x, RIFF, RIFF, :dnb_reese) }.to raise_error(ArgumentError, /one clip/)
      expect { MB::Sound.swap(:bass, MB::Sound::L.inst.dnb.dnb_reese) }.to raise_error(ArgumentError, /swap changes a player's clips; L\.inst\.dnb_reese is an instrument: track :bass, L\.inst\.dnb_reese/)
      expect { MB::Sound::L.inst.dnb.dnb_reese.call }.to raise_error(MB::Sound::GraphIO::LoadError, /missing input midi .*track :x, :dnb_reese/)
    end
  end

  it 'gives a playing track another instrument at its launch point, as one undo step' do
    steps = nil
    s, got = run(
      ->(_s) { MB::Sound.track(:bass, :dnb_sub); MB::Sound.bg(:bass, RIFF, on: :now) },
      buffers: 300,
      acts: { 10 => ->(_s) { MB::Sound.track(:bass, :jungle_sub) }, 150 => ->(s) { steps = s.undo_steps.map(&:to_s); MB::Sound.undo } }
    )
    expect(steps.last).to eq('track :bass -> L.inst.jungle_sub lands 2:1')
    expect(s.journal.entries.map(&:to_s)).to include('bg :bass landed 2:1', 'restore :bass landed 3:1')
    expect(MB::Sound::Arrangement::InstrumentPatch.entry_of(s.arrangement.tracks[:bass].patch).name).to eq(:dnb_sub) # (undone)
    # (lands on the next bar line, 2 s at 120 BPM; undo brings the old graph back at bar 3)
    _, sub = run(->(_s) { MB::Sound.track(:bass, :dnb_sub); MB::Sound.bg(:bass, RIFF, on: :now) }, buffers: 300)
    expect(got[0...96_000]).to eq(sub[0...96_000])
    expect((got[96_000...192_000] - sub[96_000...192_000]).abs.max).to be > 1e-3
  end

  it 'saves instrument tracks in set documents as `track :x, :name`, playing them back bit for bit' do
    text = nil
    _, ref = run(->(s) {
      MB::Sound.track(:bass, MB::Sound::L.inst.dnb.dnb_sub, q: 1)
      MB::Sound.scene(:a, bass: RIFF.named(:riff))
      text = MB::Sound::GraphIO::SetWriter.new(s.arrangement).to_s
      MB::Sound.go(:a, on: :now)
    })
    expect(text).to include("track :bass, :dnb_sub, q: 1\n")
    _, got = run(->(s) { MB::Sound::GraphIO.load(text, session: s); MB::Sound.go(:a, on: :now) })
    expect(got).to eq(ref)
  end
end
