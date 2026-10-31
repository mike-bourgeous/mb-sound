# Preset params become knobs on tracks (library-instruments-1, item 2):
# a track whose patch loads a graph document gets each param it doesn't
# give as the Session knob :"track/param", at the param's value with its
# Param's range and curve, read by the graph: the same samples until it is
# turned; `bind :bass, cutoff: :cut` makes the param follow another knob.
RSpec.describe(MB::Sound::Arrangement::TrackKnobs, :aggregate_failures) do
  BASS_RIFF = MB::Sound.seq(MB::Sound::F1, MB::Sound::T, MB::Sound::R, MB::Sound::Ab1, MB::Sound::C2.n4).n8.loop
  DRUM_GRID = MB::Sound.grid(16, kick: 'x...', snare: '..x.', closed_hat: 'xxxx').loop

  before { @sessions = [] }
  after {
    @sessions.each(&:close)
    MB::Sound.rewind
  }

  # A Session that runs +setup+, then plays +buffers+ buffers, running
  # +acts+ ({ buffer => Proc }) on the way; returns [session, left, right].
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
    [s, *out.captured.map { |c| Numo::DFloat.cast(c) }]
  end

  # The shipped instrument presets with params (graph documents).
  def self.preset_names
    MB::Sound::Library.index.entries(kind: :instrument, family: :preset)
      .select { |e| e.settings.is_a?(Hash) && e.settings[:document] && !e.params.empty? && e.shelf.shipped? }.map(&:name)
  end

  # The curated knobs of the shipped instrument presets (item 3: saved
  # from the scripts' knob tables, e.g. bin/synths/dnb.rb's DNB_KNOBS; the
  # same sound at their defaults: bin/save_presets.rb --check and the
  # renders against master-ai's documents).
  CURATED = {
    dnb_reese: %i[cutoff resonance drive glide], dnb_sub: %i[cutoff release], dnb_neuro: %i[cutoff decay grit],
    dnb_pad: %i[cutoff attack release], dnb_pluck: %i[cutoff decay echo], dnb_boom: %i[decay drop],
    jungle_breaks: %i[cutoff grit], jungle_sub: %i[release], jungle_reese: %i[glide release], jungle_keys: %i[decay],
    jungle_pad: %i[cutoff attack release], jungle_flute: %i[glide attack echo],
    funk_bass: %i[bite decay], funk_keys: %i[body decay], funk_clav: %i[cutoff decay], funk_talkbox: %i[glide echo],
    funk_choir: %i[dub keep attack release],
    ambient_bowl: %i[space decay], ambient_rin: %i[space decay], ambient_koto: %i[space wear decay],
    ambient_drone: %i[attack release], ambient_rainstick: %i[tip],
    tine_piano: %i[bark pickup decay release amp], tine_crunch: %i[bark pickup decay release amp], reed_piano: %i[bark pickup decay release],
  }.freeze

  it 'ships the curated knobs as preset params' do
    CURATED.each do |name, params|
      expect(MB::Sound::GraphIO.parse(MB::Sound::GraphIO.find_preset(name)).params.keys).to match_array(params), name.inspect
    end
  end

  it 'finds the shipped instrument presets with params' do
    expect(self.class.preset_names).to include(:dnb_reese, :digibrass, :sq80_classic, :ambient_gong)
  end

  # (a few in the everyday tier, every one under SLOW=1)
  [:dnb_reese, :digibrass, :reed_piano, *SlowTier.slow_tier(preset_names - %i[dnb_reese digibrass reed_piano], keep: 0)].each do |n|
    it "plays #{n} bit for bit like its params given as numbers, with them as the track's knobs" do
      doc = MB::Sound::GraphIO.parse(MB::Sound::GraphIO.find_preset(n))
      defaults = doc.params.transform_values { |v| v[:value] }
      clip = n.to_s.match?(/drum|beat|perc/) ? DRUM_GRID : BASS_RIFF
      _, *ref = run(->(_s) { MB::Sound.track(:t) { |c| MB::Sound.preset(n, midi: c, **defaults) }; MB::Sound.bg(:t, clip) }, buffers: 30)
      s, *got = run(->(_s) { MB::Sound.track(:t, n); MB::Sound.bg(:t, clip) }, buffers: 30)
      expect(s.knobs.keys).to eq(defaults.keys.map { |k| MB::Sound::Session::Name.param(:t, k) })
      expect(got).to eq(ref)
      expect(ref[0].abs.max).to be > 0.001
      expect(s.knobs.values.map(&:value)).to eq(doc.declarations.values_at(*defaults.keys).map { |p| MB::Sound::Param.magnitude(p.default).to_f })
    end
  end

  it 'gives each track its own knobs with the param\'s range and curve, turned, in scenes, and undone' do
    s, base = run(->(_s) { MB::Sound.track(:bass, :dnb_reese); MB::Sound.bg(:bass, BASS_RIFF) })
    k = s.knobs[:"bass/cutoff"]
    param = MB::Sound::GraphIO.parse(MB::Sound::GraphIO.find_preset(:dnb_reese)).declarations[:cutoff]
    expect(k.spec.range).to eq(param.magnitude_range)
    expect(k.spec.curve).to eq(:exp) # (a plain-number cutoff: the names table's curve)
    expect(s.knobs[:"bass/cutoff"].spec.range).to eq(20.0..10000.0)
    expect(k.spec.param.description).to eq(param.description)

    s2, turned = run(
      ->(_s) { MB::Sound.track(:bass, :dnb_reese); MB::Sound.track(:bass2, :dnb_reese); MB::Sound.bg(:bass, BASS_RIFF) },
      acts: { 30 => ->(_s) { MB::Sound.turn(:"bass/cutoff", 300.0) } }
    )
    expect(s2.knobs.keys).to include(:"bass/cutoff", :"bass2/cutoff")
    expect(turned[0...24_000]).to eq(base[0...24_000])
    expect((turned[30_000..] - base[30_000..]).abs.max).to be > 0.01
    expect(s2.knobs[:"bass2/cutoff"].value).to eq(2400.0)

    # A scene's knob value; the turn undone
    s3, = run(->(_s) {
      MB::Sound.track(:bass, :dnb_reese)
      MB::Sound.scene(:dark, bass: BASS_RIFF, "bass/cutoff": 400.0)
      MB::Sound.go(:dark, on: :now)
    }, buffers: 10)
    expect(s3.knobs[:"bass/cutoff"].value).to eq(400.0)
    MB::Sound::Session.with_context(session: s3) { MB::Sound.turn(:"bass/cutoff", 900.0); MB::Sound.undo(on: :now) }
    4.times { s3.process_buffer }
    expect(s3.knobs[:"bass/cutoff"].value).to eq(400.0)
  end

  it 'makes no knobs for params the patch gives, nor for presets outside tracks' do
    s, = run(->(s) {
      MB::Sound.knob(:cut, 2400.0, range: 150.0..8000.0)
      MB::Sound.track(:a) { |c| MB::Sound.preset(:digibrass, midi: c, cutoff: 800, grit: :cut) }
      MB::Sound.bg(:pad, MB::Sound.preset(:dnb_reese, midi: BASS_RIFF))
      MB::Sound.bg(:a, BASS_RIFF)
    }, buffers: 4)
    expect(s.knobs.keys).to contain_exactly(:cut, :"a/resonance")
  end

  # knobs-1 (D5): knobs are named in full, whatever short alias a document
  # or a literal used (digibrass declares `param :reso`); the short name
  # still turns it, with a one-line note the first time.
  it 'names params in full and resolves short names with a note' do
    s, = run(->(_s) { MB::Sound.track(:a, :digibrass); MB::Sound.bg(:a, BASS_RIFF) }, buffers: 2)
    expect(s.knobs.keys).to include(:"a/resonance")
    expect(s.knobs.keys).not_to include(:"a/reso")
    expect(MB::Sound::Session::Name.param(:a, :reso)).to eq(:"a/resonance")
    expect(MB::Sound::Session::Name.param(:a, :q)).to eq(:"a/quality")
    expect(MB::Sound::Session::Name.full_name(:"a/freq")).to eq(:"a/frequency")
    expect(MB::Sound::Session::Name.full_name(:"a/cutoff")).to be_nil
    expect(MB::Sound::Session::Name.full_name(:reso)).to be_nil # (plain names are the user's own)

    expect {
      MB::Sound::Session.with_context(session: s) { MB::Sound.turn(:"a/reso", 0.6) }
    }.to output(/knob :"a\/reso" is :"a\/resonance"/).to_stderr
    s.process_buffer
    expect(s.knobs[:"a/resonance"].value).to eq(0.6)
    # (noted once per name; the journal, takes, and scenes keep the full name)
    entry = nil
    expect { MB::Sound::Session.with_context(session: s) { entry = MB::Sound.turn(:"a/reso", 0.5) } }.not_to output.to_stderr
    expect(entry.to_s).to include('a/resonance')
    MB::Sound::Session.with_context(session: s) { MB::Sound.scene(:soft, "a/reso": 0.3) }
    expect(s.arrangement.scenes[:soft].values.keys).to eq([:"a/resonance"])
    MB::Sound::Session.with_context(session: s) { MB::Sound.section(:verse, 4, "a/reso": 0.4) }
    expect(s.arrangement.sections[:verse].knobs.keys).to eq([:"a/resonance"])
    expect(s.knob!(:"a/reso")).to equal(s.knobs[:"a/resonance"])
    expect(s.knob(:"a/reso")).to equal(s.knobs[:"a/resonance"])
  end

  # ui-scaffold-1 (the library picker loads one instrument after another
  # into a playing track): a reused knob takes the new instrument's value,
  # at the track's launch point, one undo step; a turned one too since
  # carry-1 (the maintainer, 2026-10-30: "Always reset"; it carried when
  # the new range held it before)
  it 'gives a playing track\'s reused knobs the new instrument\'s values, turned ones too, at its launch point' do
    s, = run(->(_s) { MB::Sound.track(:bass, :dnb_sub); MB::Sound.bg(:bass, BASS_RIFF) }, buffers: 10)
    cut = s.knobs[:"bass/cutoff"]
    expect(cut.value).to eq(110.0)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:bass, :dnb_reese)
      2.times { s.process_buffer }
      expect(cut.value).to eq(110.0) # (dnb_sub plays on until the launch point)
      120.times { s.process_buffer }
      expect(s.knobs[:"bass/cutoff"].value).to eq(2400.0) # (untouched: dnb_reese's own)

      MB::Sound.turn(:"bass/cutoff", 3000.0, on: :now)
      2.times { s.process_buffer }
      MB::Sound.track(:bass, :jungle_pad) # (another range: 20..16000)
      120.times { s.process_buffer }
      k = s.knobs[:"bass/cutoff"]
      expect(k.value).to eq(2400.0) # (turned, but a new instrument: jungle_pad's own)
      expect(k.spec.range).to eq(20.0..16000.0)
      expect(s.knobs[:"bass/release"].value).to eq(1.8) # (dnb_sub's 0.05 was untouched)

      MB::Sound.track(:bass, :dnb_reese)
      MB::Sound.undo(on: :now) # (one step: the instrument and its knobs)
      4.times { s.process_buffer }
      expect(MB::Sound::Arrangement::InstrumentPatch.entry_of(s.arrangement.tracks[:bass].patch).name).to eq(:jungle_pad)
      expect(s.knobs[:"bass/cutoff"].value).to eq(2400.0)

      # (the same instrument given again keeps a turned knob)
      MB::Sound.turn(:"bass/cutoff", 3000.0, on: :now)
      2.times { s.process_buffer }
      MB::Sound.track(:bass, :jungle_pad)
      120.times { s.process_buffer }
      expect(s.knobs[:"bass/cutoff"].value).to eq(3000.0)
    end
  end

  it 'saves the knobs in set documents and loads them back, turned' do
    text = nil
    s, = run(->(s) {
      MB::Sound.track(:bass, :dnb_reese)
      MB::Sound.scene(:a, bass: BASS_RIFF.named(:riff))
    }, buffers: 0)
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.turn(:"bass/cutoff", 900.0, on: :now)
      s.process_buffer
      text = MB::Sound::GraphIO::SetWriter.new(s.arrangement).to_s
    end
    expect(text).to include('knob :"bass/cutoff", (20.0..10000.0).at(900.0)', "track :bass, :dnb_reese\n")
    s2, = run(->(s) { MB::Sound::GraphIO.load(text, session: s); MB::Sound.go(:a, on: :now) }, buffers: 4)
    expect(s2.knobs[:"bass/cutoff"].value).to eq(900.0)
  end

  it 'replays a take with an instrument track and its knob turned, bit for bit' do
    lines = {
      0 => ['track :bass, :dnb_sub', 'bg :bass, seq(F1, T, R, Ab1).n8.loop'],
      40 => ['turn :"bass/cutoff", 300.0, over: 1'],
      120 => ['track :bass, :jungle_sub'],
    }
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), channels: 2, buffer_size: 800, realtime: false, raise_errors: true)
    @sessions << session
    b = MB::Sound::Take.console_binding
    out = []
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    240.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    live = SpecBuffers.join(out)
    expect(live.abs.max).to be > 0.05
    expect(session.knobs[:"bass/cutoff"].value).to eq(300.0)
    MB::Sound.seed(5)
    data = []
    t.replay.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: [800], tail: 0) { |mix| data << mix[0].dup }
    data = SpecBuffers.join(data)
    expect((data[0...live.length] - live).abs.max).to eq(0)
  end

  it 'binds a preset param to an existing knob (bind :bass, cutoff: :cut), and explains the other spellings' do
    clip = BASS_RIFF
    s, = run(->(_s) {
      MB::Sound.knob(:cut, 2400.0, range: 150.0..8000.0)
      MB::Sound.track(:bass, :dnb_reese)
      MB::Sound.bg(:bass, clip)
    }, buffers: 4)
    MB::Sound::Session.with_context(session: s) do
      expect { MB::Sound.bind(:bass, :cut) }.to raise_error(MB::Sound::Arrangement::LiteralBinding::Error, /did you mean bind :bass, cutoff: :cut\?/)
      expect { expect(MB::Sound.bind(:bass, :cutoff)).to eq(:"bass/cutoff") }.to output(/already knob :"bass\/cutoff"/).to_stdout
      expect { MB::Sound.bind(:bass, cutoff: :cutt) }.to raise_error(MB::Sound::Arrangement::LiteralBinding::Error, /no knob :cutt.*:cut/m)
      entry = MB::Sound.bind(:bass, cutoff: :cut, on: :now)
      expect(entry.to_s).to start_with('bg :bass')
    end
    4.times { s.process_buffer }
    code = MB::Sound::UI::Inspect.roots(s.ui_graphs[:bass]).first.to_ruby
    expect(code).to include('knob(:cut)')
    expect(code).not_to include('bass/cutoff')
    # the inspector's knob rows: the knob the graph reads
    info = MB::Sound::UI::Inspect::Gatherer.new.call(s, { track: :bass, node: nil })
    expect(info.knobs).to include(:cut, :"bass/resonance", :"bass/drive", :"bass/glide")
    expect(info.knobs).not_to include(:"bass/cutoff")

    s2, = run(->(_s) { MB::Sound.track(:bass, :digibrass); MB::Sound.bg(:bass, clip) }, buffers: 4)
    info = MB::Sound::UI::Inspect::Gatherer.new.call(s2, { track: :bass, node: nil })
    expect(info.knobs).to contain_exactly(:"bass/grit", :"bass/cutoff", :"bass/resonance")
  end
end
