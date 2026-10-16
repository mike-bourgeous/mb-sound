RSpec.describe('Sampler graph documents', :aggregate_failures) do
  let(:io) { MB::Sound::GraphIO }

  def render(graph, buffers: 8, size: 800)
    Array.new(buffers) { graph.sample(size)&.dup }.compact
  end

  def max_diff(a, b)
    a.zip(b).map { |x, y| (x - y).abs.max }.max
  end

  let(:rec) {
    MB::Sound.bounce(1.bar, bpm: 140) { MB::Sound.tr808(MB::Sound.grid(16, kick: 'X...X...X...X...', snare: '....X.......X...')) }
  }

  it 'prints slices, chops, and views through their lineage' do
    brk = rec.slices(16).name(k: 0..1, s: 4..5)
    path = tmp_path('break.flac')
    rec.save(path)
    file = MB::Sound::Sample[path]
    fb = file.slices(16).name(k: 0..1, s: 4..5)
    g = fb.chop(:k, MB::Sound::Tie, :s, [:s, 3], fb[:k].rev).loop.sampler(fb)
    code = g.to_ruby
    expect(code).to include(%{Sample[#{File.expand_path(path).inspect}].slices(16).name(k: 0..1, s: 4..5).chop(:k, Tie, :s, [:s, 3]})
    expect(code).to include('[:k].reverse')
    expect(MB::Sound::Sample[path]).to equal(file) # the file cache
    expect(brk[3].at(0.25.n16).fade(out: 1.ms).lineage[1]).to eq(:fade)
  end

  it 'saves samples into bundles as assets and loads them back' do
    brk = rec.slices(16).name(k: 0..1, s: 4..5)
    g = brk.chop(:k, MB::Sound::Tie, :s, [:s, 3], brk[:k].rev, MB::Sound::Rest).loop.sampler(brk) { |v, s| s * v.env(0.001, 0.01, 1, 0.01, gm: false) }
    dir = File.dirname(tmp_path('x'))
    MB::Sound.seed(1)
    path = io.save(File.join(dir, 'chops'), g, name: 'chops')
    expect(path).to end_with('chops.mbg/chops.mbg.rb')
    text = File.read(path)
    expect(text).to match(/^asset "assets\/bounce.flac", sha256: "\h{64}"$/)
    expect(text).to include('Sample["assets/bounce.flac"].slices(16)')
    back = io.load(path)
    ref = render(g)
    expect(max_diff(ref, render(back))).to be < 1e-6 # FLAC's 24 bits
    expect(ref.map { |b| b.abs.max }.max).to be > 0.1

    # A changed asset is refused
    File.binwrite(File.join(dir, 'chops.mbg', 'assets', 'bounce.flac'), File.binread(File.join(dir, 'chops.mbg', 'assets', 'bounce.flac')) + 'x')
    expect { io.load(path) }.to raise_error(io::LoadError, /sha256|SHA-256|changed/i)
  end

  it 'leaves the default steal_fade out of documents and keeps steal_fade: false' do
    brk = rec.slices(4)
    dir = File.dirname(tmp_path('x'))
    # quarter-bar slices every sixteenth on 2 voices: every hit from the third steals a voice
    graphs = [{}, { steal_fade: false }].map { |o| brk.chop(0, 1, 2, 3).n16.loop.sampler(brk, voices: 2, **o) }
    texts = graphs.each_with_index.map { |g, i| File.read(io.save(File.join(dir, "steal#{i}"), g, name: "steal#{i}")) }
    expect(texts[0]).not_to include('steal_fade')
    expect(texts[1]).to include('.sampler(Sample["assets/bounce.flac"].slices(4), voices: 2, steal_fade: false, seed: drawn_seed(')
    refs = graphs.map { |g| render(g, buffers: 16) }
    expect(max_diff(*refs)).to be > 0.1 # the stolen voices ring on without the fade
    graphs.each_index do |i|
      expect(max_diff(refs[i], render(io.load(File.join(dir, "steal#{i}.mbg", "steal#{i}.mbg.rb")), buffers: 16))).to be < 1e-6
    end
  end

  it 'saves tempo-following loops into bundles' do
    g = rec.follow + rec.stretch(0.5, mode: :slice).follow(:resample, align: :launch) * 0.5
    dir = File.dirname(tmp_path('x'))
    path = io.save(File.join(dir, 'follow'), g, name: 'follow')
    text = File.read(path)
    expect(text).to include('.follow')
    back = io.load(path)
    ref = render(g)
    expect(max_diff(ref, render(back))).to be < 1e-6
    expect(ref.map { |b| b.abs.max }.max).to be > 0.1
  end

  it 'saves grain clouds and spectral stretches into bundles' do
    pad = rec.stretch(2, mode: :spectral)
    g = pad.grains(position: 0.3, density: 60, size: 30.ms, pitch: [0, 12], seed: 4).mixdown +
      MB::Sound.seq(MB::Sound::C4, MB::Sound::G4).n8.loop.synth { |v| v.grains(rec, density: 80, size: 20.ms, seed: 5)[0] * v.env(0.001, 0.01, 1, 0.01, gm: false) }
    dir = File.dirname(tmp_path('x'))
    MB::Sound.seed(1)
    path = io.save(File.join(dir, 'grains'), g, name: 'grains')
    text = File.read(path)
    expect(text).to include('.grains(')
    back = io.load(path)
    ref = render(g)
    expect(max_diff(ref, render(back))).to be < 1e-5
    expect(ref.map { |b| b.abs.max }.max).to be > 0.05
  end

  it 'keeps lofi drop-sample reads and read_as views in bundles' do
    dirty = rec.lofi(:s950).slices(8)
    clean = rec.lofi(:sp1200).read_as(:clean).slices(8)
    clip = MB::Sound.seq(MB::Sound::C2, MB::Sound::D2.pitch(7), MB::Sound::E2.pitch(12)).n8.loop
    g = clip.sampler(dirty) + clip.sampler(clean)
    dir = File.dirname(tmp_path('x'))
    MB::Sound.seed(1)
    path = io.save(File.join(dir, 'lofi'), g, name: 'lofi')
    text = File.read(path)
    expect(text).to include('.read_as(:clean).slices(8)')
    back = io.load(path)
    ref = render(g)
    expect(max_diff(ref, render(back))).to be < 1e-6
    expect(ref.map { |b| b.abs.max }.max).to be > 0.1
    reads = Dir[File.join(dir, 'lofi.mbg', 'assets', '*.flac')].map { |f| MB::Sound::Sample[f] }.map { |x| [x.interpolation, x.mips] }
    expect(reads).to contain_exactly([:none, false], [:none, false])
  end

  it 'saves choke groups of instruments built region by region' do
    m = MB::Sound
    hat = m::Sample[Numo::SFloat.cast(Numo::DFloat.new(9600).seq.map { |i| Math.sin(i * 0.1) * 0.5 })]
    inst = m::Sampler::Instrument.new { |i|
      i.region(hat, keys: m::As2, group: :open, off_by: :closed)
      i.region(hat, keys: m::Fs2, tune: 7, choke: 3)
    }
    clip = m.events([0, 1/32r, m::As2, 1.0], [1/16r, 1/32r, m::Fs2, 1.0], [1/8r, 1/32r, m::Fs2, 1.0], length: 1).loop
    g = clip.synth(voices: 4) { |v| inst.play(v, seed: 1) }
    dir = File.dirname(tmp_path('x'))
    path = io.save(File.join(dir, 'chokes'), g, name: 'chokes', bundle: true)
    text = File.read(path)
    expect(text).to include('group: :open, off_by: :closed')
    expect(text).to include('choke: 3')
    back = io.load(path)
    ref = render(g, buffers: 12)
    expect(max_diff(ref, render(back, buffers: 12))).to be < 1e-4 # (FLAC assets at 24 bits)
    expect(ref[7..].map { |b| b.abs.max }.max).to be > 0.1
  end

  it 'reads SFZ instruments named by documents, inside the document directory only' do
    dir = File.dirname(tmp_path('x'))
    FileUtils.mkdir_p(File.join(dir, 'kit'))
    MB::Sound.write(File.join(dir, 'kit', 'tick.wav'), [Numo::SFloat.new(2000).fill(0.5)], overwrite: true)
    File.write(File.join(dir, 'kit', 'kit.sfz'), "<region> sample=tick.wav key=60\n")
    File.write(File.join(dir, 'kit', 'bad.sfz'), "<region> sample=../../outside.wav key=60\n")
    doc = <<~DOC
      graph 2, name: "s"
      inputs :midi
      synth(midi, voices: 1) { |v| sfz("kit/kit.sfz").play(v) }
    DOC
    File.write(File.join(dir, 'ok.mbg.rb'), doc)
    notes = MB::Sound.seq(MB::Sound::C4.n8).notes
    g = io.load(File.join(dir, 'ok.mbg.rb'), inputs: { midi: notes })
    expect(render(g, buffers: 2).first[0...800].abs.max).to be_within(0.01).of(0.5 * (95 / 127.0)**2) # SFZ amp_veltrack 100 at velocity 0.75

    File.write(File.join(dir, 'bad.mbg.rb'), doc.sub('kit/kit.sfz', 'kit/bad.sfz'))
    expect { io.load(File.join(dir, 'bad.mbg.rb'), inputs: { midi: notes }) }.to raise_error(io::LoadError, /inside its directory|relative to the document/)
    File.write(File.join(dir, 'abs.mbg.rb'), doc.sub('kit/kit.sfz', File.join(dir, 'kit/kit.sfz')))
    expect { io.load(File.join(dir, 'abs.mbg.rb'), inputs: { midi: notes }) }.to raise_error(io::LoadError, /relative to the document/)
  end
end
