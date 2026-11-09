RSpec.describe(MB::Sound::GraphNode::Chebyshev, :aggregate_failures) do
  include BufferSizeHelpers

  let(:mod) { MB::Sound::GraphNode::Chebyshev }

  # Harmonic magnitudes 1..+count+ of +node+ for fundamental +f0+ (one
  # second after a 0.1 s settle; every whole Hz an rfft bin).
  def harmonics(node, f0, count = 9)
    node.sample(4800)
    d = Numo::DFloat.cast(node.sample(48000))
    spec = Numo::Pocketfft.rfft(d).abs * 2 / 48000
    (1..count).map { |k| spec[k * f0] }
  end

  # The Chebyshev polynomial T_n(x) by its definition.
  def t(n, x)
    Math.cos(n * Math.acos(x.clamp(-1.0, 1.0)))
  end

  it 'gives a full-scale sine exactly the harmonic amounts (exact shaper)' do
    got = harmonics(1000.hz.sine.chebyshev(1, 0.5, 0.25, 0, 0.1, antialias: false), 1000)
    want = [1, 0.5, 0.25, 0, 0.1, 0, 0, 0, 0]
    got.zip(want).each { |g, w| expect(g).to be_within(1e-4).of(w) }
    got = harmonics(500.hz.sine.chebyshev(h15: 1, antialias: false), 500, 15)
    expect(got[14]).to be_within(1e-3).of(1)
    expect(got[0...14].max).to be < 1e-3
  end

  it 'antialiases with the library shapers (amounts within 1% at 1 kHz, aliases cut)' do
    got = harmonics(1000.hz.sine.chebyshev(1, 0.5, 0.25), 1000)
    [1, 0.5, 0.25].each_with_index { |w, i| expect(got[i]).to be_within(0.012 * w).of(w) }
    # 3 kHz through h13: the 13th harmonic (39 kHz) folds to 9 kHz
    plain = Numo::Pocketfft.rfft(Numo::DFloat.cast(3000.hz.sine.chebyshev(h13: 1, antialias: false).tap { |n| n.sample(4800) }.sample(48000))).abs
    aa = Numo::Pocketfft.rfft(Numo::DFloat.cast(3000.hz.sine.chebyshev(h13: 1).tap { |n| n.sample(4800) }.sample(48000))).abs
    expect(aa[9000] / plain[9000]).to be < 0.5
  end

  it 'follows sum(a_n T_n(x)) - sum(a_n T_n(0)) on -1..1 and holds its ends beyond' do
    a = [0, 1.0, 0.3, 0.08, 0, 0.2]
    c = mod.curve(a)
    [-1, -0.7, -0.2, 0, 0.35, 0.9, 1].each do |x|
      want = (1..5).sum { |n| a[n] * (t(n, x) - t(n, 0)) }
      expect(-1 + 2 * c.call((x + 1) / 2.0)).to be_within(1e-12).of(want)
    end
    ramp = MB::Sound::ArrayInput.new(data: [Numo::SFloat[-3, -1, 0, 1, 3]])
    out = ramp.chebyshev(h1: 1, h3: 0.5, antialias: false).sample(5)
    expect(out[0]).to eq(out[1])
    expect(out[4]).to eq(out[3])
  end

  it 'keeps silence silent and blocks the DC of even harmonics' do
    expect(0.constant.chebyshev(:triode).sample(800).abs.max).to eq(0)
    out = 100.hz.sine.chebyshev(h2: 1)
    out.sample(48000)
    expect(out.sample(48000).mean.abs).to be < 1e-3
    expect(220.hz.sine.chebyshev(h3: 1).graph.grep(MB::Sound::Filter::SampleWrapper).map { |w| w.filter.class }).not_to include(MB::Sound::Filter::FirstOrder)
  end

  it 'scales the input with drive (numbers, Decibels, nodes)' do
    a = harmonics(1000.hz.sine.at(0.5).chebyshev(h3: 1, drive: 2, antialias: false), 1000, 3)
    expect(a[2]).to be_within(1e-4).of(1)
    b = harmonics(1000.hz.sine.at(0.5).chebyshev(h3: 1, drive: 2.constant, antialias: false), 1000, 3)
    expect(b[2]).to be_within(1e-4).of(1)
    c = harmonics(1000.hz.sine.at(0.5).chebyshev(h3: 1, drive: (20 * Math.log10(2)).db, antialias: false), 1000, 3)
    expect(c[2]).to be_within(1e-4).of(1)
  end

  it 'has presets in the library, overridable by harmonic keywords' do
    expect(mod.preset_names).to include(:triode, :pentode, :octaver, :drawbar, :reed)
    expect(MB::Sound::L.fx.chebyshev.names).to include(:triode)
    reed = harmonics(1000.hz.sine.chebyshev(:reed, antialias: false), 1000)
    expect(reed.values_at(0, 2, 4, 6, 8).map { |v| v.round(3) }).to eq([1, 0.5, 0.3, 0.2, 0.1])
    more = harmonics(1000.hz.sine.chebyshev(:reed, h2: 0.25, antialias: false), 1000)
    expect(more[1]).to be_within(1e-4).of(0.25)
    expect(harmonics(1000.hz.sine.chebyshev(antialias: false), 1000)[1]).to be_within(1e-4).of(0.3) # :triode
  end

  it 'runs per channel, gives the same output at any buffer size, and prints back as Ruby' do
    expect(MB::Sound.stereo(110.hz.saw, 165.hz.saw).chebyshev(:pentode).channel_count).to eq(2)
    expect_invariant(-> { 110.hz.saw.at(0.8).chebyshev(:drawbar, drive: 0.3.hz.lfo.at(0.5..1.5)) }, seconds: 0.5)
    g = -> { 220.hz.sine.until(0.2).chebyshev(h2: 0.5, h3: 0.2, drive: 2) }
    code = g.().to_ruby
    expect(code).to include('chebyshev(h2: 0.5, h3: 0.2, drive: 2)')
    ref = RecipeHelpers.render(g.(), buffers: 20)
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(RecipeHelpers.eval_recipe(code), buffers: 20))).to eq(0)
    expect(RecipeHelpers.max_diff(ref, RecipeHelpers.render(MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g.())), buffers: 20))).to eq(0)
  end

  it 'rejects bad arguments' do
    expect { 1.constant.chebyshev(h16: 1) }.to raise_error(ArgumentError, /h16/)
    expect { 1.constant.chebyshev(*Array.new(16, 0.1)) }.to raise_error(ArgumentError, /at most 15/)
    expect { 1.constant.chebyshev(0, 0) }.to raise_error(ArgumentError, /nonzero/)
    expect { 1.constant.chebyshev(:fuzzz) }.to raise_error(ArgumentError, /fuzzz/)
    expect { 1.constant.chebyshev(h2: :x) }.to raise_error(ArgumentError, /h2/)
    expect { 1.constant.chebyshev(drive: -1) }.to raise_error(ArgumentError, /drive/)
  end
end
