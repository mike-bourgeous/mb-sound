RSpec.describe(MB::Sound::GraphNode::Resonator, :aggregate_failures) do
  # An input of +length+ samples with impulses of the given heights at the
  # given samples, then the end.
  def impulses(length, hits)
    data = Numo::SFloat.zeros(length)
    hits.each { |i, v| data[i] = v }
    MB::Sound::ArrayInput.new(data: [data])
  end

  # Samples +node+ in 800-sample buffers until it ends (or +limit+ samples).
  def collect(node, limit: 480000)
    out = []
    total = 0
    while total < limit && (buf = node.sample(800))
      out << buf.dup
      total += buf.length
    end
    out.empty? ? Numo::SFloat[] : Numo::SFloat.hstack(out)
  end

  it 'rings at the height of each impulse' do
    out = impulses(4800, { 0 => 0.6 }).ping(1000, decay: 100).sample(4800)
    expect(out[0]).to eq(0)
    expect(out[0...100].abs.max).to be_within(0.01).of(0.6)
  end

  it 'falls 60 dB over the decay time' do
    out = impulses(48000, { 0 => 1 }).ping(480, decay: 0.5).sample(48000)
    level = ->(t) { i = (t * 48000).round; out[i...(i + 100)].abs.max }
    expect((level.(0.5) / level.(0.0)).to_db).to be_within(0.5).of(-60)
    expect((level.(0.25) / level.(0.0)).to_db).to be_within(0.5).of(-30)
  end

  it 'starts at the given phase' do
    out = impulses(100, { 0 => 1 }).ping(100, decay: 1, phase: Math::PI / 2).sample(100)
    expect(out[0]).to be_within(1e-6).of(1)
  end

  it 'keeps its ringing level while the frequency sweeps' do
    sweep = MB::Sound::ArrayInput.new(data: [Numo::SFloat.linspace(40, 400, 24000)])
    out = impulses(24000, { 0 => 1 }).ping(sweep, decay: 1e6).sample(24000)
    expect(out[0...2000].abs.max).to be_within(0.001).of(1)
    expect(out[22000..].abs.max).to be_within(0.001).of(1)
  end

  it 'takes a Pitch or Note as its frequency' do
    a = impulses(4800, { 0 => 1 }).ping(110.hz, decay: 1).sample(4800)
    b = impulses(4800, { 0 => 1 }).ping(110, decay: 1).sample(4800)
    expect(a).to eq(b)

    c = impulses(4800, { 0 => 1 }).ping(MB::Sound::A2, decay: 1).sample(4800)
    expect(c).to eq(b)
  end

  it 'takes lengths and nodes as its decay' do
    a = impulses(4800, { 0 => 1 }).ping(200, decay: 500.ms).sample(4800)
    b = impulses(4800, { 0 => 1 }).ping(200, decay: 0.5).sample(4800)
    c = impulses(4800, { 0 => 1 }).ping(200, decay: 24000.samples).sample(4800)
    d = impulses(4800, { 0 => 1 }).ping(200, decay: 0.5.constant).sample(4800)
    expect(a).to eq(b)
    expect(c).to eq(b)
    expect(d).to eq(b)
  end

  it 'adds new strikes to the ringing' do
    one = impulses(2000, { 0 => 1 }).ping(48, decay: 10).sample(2000)
    two = impulses(2000, { 0 => 1, 1000 => 1 }).ping(48, decay: 10).sample(2000)
    # Linear: the second ring adds to the first
    expect((two[1000..] - one[1000..] - one[0...1000]).abs.max).to be < 1e-5
    expect(two[1000..].abs.max).to be > 1.9
  end

  it 'rings out after its input ends, then ends' do
    out = collect(impulses(800, { 0 => 1 }).ping(100, decay: 0.1))
    expect(out.length).to be > 800
    expect(out.length).to be < 0.25 * 48000
    expect(out[-800..].abs.max).to be < 1e-5
  end

  it 'ends right away when nothing rings after the input ends' do
    node = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(800)]).ping(100, decay: 0.1)
    expect(node.sample(800)).to be_a(Numo::SFloat)
    expect(node.sample(800)).to be_nil
  end

  it 'matches the Ruby mirror through the node' do
    trig = MB::Sound::Sequence::Grid.parse(16, 'x.X.x...').loop.trigger
    freq = 50.hz.lfo.at(40..80)
    node = trig.ping(freq, decay: 0.3)
    buf = node.sample(4800)

    trig2 = MB::Sound::Sequence::Grid.parse(16, 'x.X.x...').loop.trigger
    freq2 = 50.hz.lfo.at(40..80)
    x = trig2.sample(4800)
    f = freq2.sample(4800)
    out = Numo::SFloat.zeros(4800)
    described_class.process_ruby(out, x, f, 0.3 * 48000, Numo::DFloat.zeros(2), 48000, 1.0, 0.0)
    expect(buf).to eq(out)
  end

  it 'lists its sources and describes itself' do
    node = impulses(10, {}).ping(100.constant, decay: 1)
    expect(node.sources.keys).to eq([:input, :freq])
    expect(node.to_s).to include('Resonator')
  end
end
