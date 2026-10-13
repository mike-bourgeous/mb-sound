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
