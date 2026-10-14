RSpec.describe(MB::Sound::GraphNode::Grains, :aggregate_failures) do
  let(:ramp) { MB::Sound::Sample[Numo::SFloat.new(48000).seq / 48000] }
  let(:ones) { MB::Sound::Sample[Numo::SFloat.ones(4800)] }
  let(:noise) {
    r = Random.new(5)
    MB::Sound::Sample[Numo::SFloat.cast(Array.new(48000) { r.rand * 2 - 1 })]
  }

  # Both channels of +bundle+ for +total+ samples in blocks of +block+.
  def render(bundle, total, block = 800)
    l = []
    r = []
    while l.length < total
      n = [block, total - l.length].min
      l.concat(bundle[0].sample(n).to_a)
      r.concat(bundle[1].sample(n).to_a)
    end
    [l, r]
  end

  def core(bundle)
    bundle[0].instance_variable_get(:@grains)
  end

  it 'gives the same samples at any buffer size' do
    outs = [1, 128, 367, 800].map { |b|
      render(noise.grains(seed: 3, density: 200, size: 0.02, spread: 0.3, pitch_spread: 2, pan_spread: 1, reverse: 0.3, scan: 0.5), 4000, b)
    }
    outs.each { |o| expect(o).to eq(outs[0]) }
    expect(outs[0][0].map(&:abs).max).to be > 0.05
  end

  it 'starts regular grains on exact samples' do
    l, r = render(ones.grains(seed: 1, density: 100, size: 0.001, jitter: 0, pan_spread: 0, window: :rect), 2000)
    expect(l).to eq(r)
    [0, 480, 960, 1440].each do |onset|
      expect(l[onset]).to eq(0) # the window starts at 0
      expect(l[onset + 1]).to be > 0
      expect(l[onset - 1]).to eq(0) if onset > 0
      expect(l[onset + 20]).to be_within(1e-3).of(1)
    end
  end

  it 'freezes at a position' do
    l, _ = render(ramp.grains(seed: 2, position: 0.42, density: 5, size: 0.01, jitter: 0, pan_spread: 0, window: :rect), 48000)
    vals = l.reject { |v| v.abs < 0.4 }
    expect(vals).not_to be_empty
    expect(vals.max).to be < 0.4255
    expect(vals.sort[vals.length / 2]).to be_within(0.002).of(0.42)
  end

  it 'scans through the sample when no position is given' do
    g = ramp.grains(seed: 2, density: 10, size: 0.01, jitter: 0, pan_spread: 0, window: :rect)
    l, _ = render(g, 24000)
    # the grain at 0.5 s reads around the sample's 0.5 s
    expect(l[24000 - 4800 + 240]).to be_within(0.01).of(0.4)
    g2 = ramp.grains(seed: 2, density: 10, size: 0.01, jitter: 0, pan_spread: 0, window: :rect, scan: 0.5)
    l2, _ = render(g2, 48000)
    expect(l2[38400 + 240]).to be_within(0.01).of(0.4)
  end

  it 'never plays more than max_grains' do
    g = noise.grains(seed: 4, density: 2000, size: 0.5, max_grains: 5)
    peak = 0
    10.times do
      g[0].sample(100)
      g[1].sample(100)
      peak = [peak, core(g).active_grains].max
    end
    expect(peak).to eq(5)
  end

  it 'keeps dense clouds near the level of the sample' do
    src = Math.sqrt((noise.data**2).mean)
    db = ->(l) { 20 * Math.log10(Math.sqrt(l.sum { |v| v * v } / l.length) / src) }
    l, r = render(noise.grains(seed: 6, density: 400, size: 0.05, pan_spread: 0, position: 0.5, spread: 0.4), 48000)
    expect(db.(l)).to be_within(1.5).of(0)
    expect(l).to eq(r)

    # grains lined up into the original sound (scan 1, pitch 0) add up
    # coherently: normalize: :amplitude
    l, _ = render(noise.grains(seed: 6, density: 400, size: 0.05, pan_spread: 0, jitter: 0, normalize: :amplitude), 48000)
    expect(db.(l[4800..])).to be_within(1).of(0)
    l, _ = render(noise.grains(seed: 6, density: 400, size: 0.05, pan_spread: 0, jitter: 0), 48000)
    expect(db.(l[4800..])).to be > 8
  end

  it 'tracks a frequency input against the root and picks pitch choices' do
    root = MB::Sound.tuning.frequency_of(60).to_f
    g = MB::Sound::GraphNode::Grains.new(ones, seed: 1, freq: root * 2, density: 1000, size: 0.001)
    2.times { g.outputs.each { |o| o.sample(100) } }
    steps = g.instance_variable_get(:@slots)[true, 2].to_a.reject(&:zero?)
    expect(steps.uniq).to eq([2.0])

    g = MB::Sound::GraphNode::Grains.new(ones, seed: 1, pitch: [0, 12], density: 2000, size: 0.001, max_grains: 64)
    g.outputs.each { |o| o.sample(400) }
    steps = g.instance_variable_get(:@slots)[true, 2].to_a.reject(&:zero?).uniq.sort
    expect(steps).to eq([1.0, 2.0])
  end

  it 'plays in synth voices with v.grains' do
    clip = MB::Sound.seq(MB::Sound::C4.n4, MB::Sound::C5.n4)
    syn = clip.synth(voices: 2) { |v| v.grains(noise, density: 100, size: 0.02, seed: 1)[0] * v.env(0.001, 0.1, 1, 0.05) }
    out = 30.times.flat_map { syn.sample(800).to_a }
    expect(out.map(&:abs).max).to be > 0.05
  end

  it 'caps voices at 16 grains unless max_grains: says otherwise' do
    notes = MB::Sound.seq(MB::Sound::C4.n4).notes
    expect(core(notes.grains(noise)).max_grains).to eq(16)
    expect(core(notes.grains(noise, max_grains: 40)).max_grains).to eq(40)
    expect(core(noise.grains).max_grains).to eq(32)
  end

  it 'repeats from its seed and differs by seed' do
    a = render(noise.grains(seed: 9, density: 100), 3000)
    b = render(noise.grains(seed: 9, density: 100), 3000)
    c = render(noise.grains(seed: 10, density: 100), 3000)
    expect(a).to eq(b)
    expect(a).not_to eq(c)
  end

  it 'reads drop-sample with read: :drop' do
    g = noise.grains(read: :drop, seed: 1)
    expect(core(g).instance_variable_get(:@interpolation)).to eq(:none)
    expect(render(g, 1000)[0].map(&:abs).max).to be > 0
  end

  it 'accepts lengths, intervals, and windows of several kinds' do
    g = noise.grains(size: 30.ms, position: 0.25.seconds, spread: 10.ms, pitch: 3.semitones, density: 1.n16, window: ->(x) { Math.sin(Math::PI * x) })
    expect(render(g, 2000)[0].map(&:abs).max).to be > 0
    expect(render(noise.grains(window: [0, 1, 0.5, 0]), 1000)[0].length).to eq(1000)
  end

  it 'raises on bad options' do
    expect { noise.grains(window: :nope) }.to raise_error(ArgumentError, /window/)
    expect { noise.grains(max_grains: 0) }.to raise_error(ArgumentError, /max_grains/)
    expect { noise.grains(density: 'x') }.to raise_error(ArgumentError, /numbers or nodes/)
    expect { MB::Sound::GraphNode::Grains.new(:x) }.to raise_error(ArgumentError, /Sample/)
  end

  it 'is a plan boundary' do
    expect(core(noise.grains).plan_unsupported_reason).to match(/boundary/)
  end
end
