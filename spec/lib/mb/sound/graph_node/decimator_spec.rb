RSpec.describe(MB::Sound::GraphNode::Decimator, :aggregate_failures) do
  # Samples +node+ in buffers of +size+ (an Integer or an Array cycled)
  # until +total+ samples.
  def collect(node, total, size = 800)
    sizes = Array(size).cycle
    out = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      buf = node.sample(len)
      break if buf.nil?
      out << buf.dup
      n += buf.length
    end
    Numo::SFloat.hstack(out)
  end

  # The frequency of the strongest FFT bin of +data+ (48 kHz).
  def peak_hz(data)
    spectrum = MB::Sound.real_fft(data).abs
    spectrum[0] = 0
    spectrum.max_index * 48000.0 / data.length
  end

  it 'folds a tone above half the hold rate back down' do
    out = 10000.hz.sine.decimate(12000).sample(48000)
    expect(peak_hz(out)).to be_within(1).of(2000)

    # Below half the rate, the tone stays the strongest part
    out = 1000.hz.sine.decimate(12000).sample(48000)
    expect(peak_hz(out)).to be_within(1).of(1000)
  end

  it 'holds every N samples for rates dividing the sample rate, and passes through at the sample rate' do
    ramp = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(48).seq])
    expect(ramp.decimate(8000).sample(48).to_a).to eq((0...48).map { |i| (i / 6) * 6 })

    sig = 440.hz.saw
    ref = 440.hz.saw
    expect(sig.decimate(48000).sample(1000)).to eq(ref.sample(1000))
  end

  it 'holds at fractional rates' do
    ramp = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(4800).seq])
    out = ramp.decimate(48000 / 2.5).sample(4800)
    steps = out.to_a.chunk_while { |a, b| a == b }.map(&:length)
    expect(steps.uniq.sort).to eq([2, 3])
    expect(steps.sum / steps.length.to_f).to be_within(0.01).of(2.5)
  end

  it 'gives the same output at any buffer size, with a modulated rate and jitter' do
    make = -> { 110.hz.saw.decimate(0.7.hz.lfo.at(500..9000), jitter: 0.4, seed: 7) }
    a = collect(make.(), 9600, 800)
    b = collect(make.(), 9600, [1, 7, 128, 33])
    expect(b).to eq(a)
  end

  it 'takes a Pitch or Note for its rate' do
    a = collect(220.hz.saw.decimate(3000.hz), 2000)
    b = collect(220.hz.saw.decimate(3000), 2000)
    expect(a).to eq(b)
  end

  it 'tracks a note when the rate follows its frequency' do
    clip = MB::Sound.seq(MB::Sound::A2.n4, MB::Sound::A3.n4)
    n = clip.notes
    node = n.hz.saw.decimate(n.freq * 4)
    expect(node.rate).to be_a(MB::Sound::GraphNode)
    expect(collect(node, 4800).abs.max).to be > 0.5
  end

  it 'repeats its jitter from the seed, and draws a seed only with jitter' do
    a = collect(220.hz.saw.decimate(5000, jitter: 0.5, seed: 3), 4800)
    b = collect(220.hz.saw.decimate(5000, jitter: 0.5, seed: 3), 4800)
    c = collect(220.hz.saw.decimate(5000, jitter: 0.5, seed: 4), 4800)
    d = collect(220.hz.saw.decimate(5000), 4800)
    expect(a).to eq(b)
    expect(a).not_to eq(c)
    expect(a).not_to eq(d)

    expect(220.hz.saw.decimate(5000).seed).to be_nil
    MB::Sound.seed(11)
    e = 220.hz.saw.decimate(5000, jitter: 0.5)
    MB::Sound.seed(11)
    f = 220.hz.saw.decimate(5000, jitter: 0.5)
    expect(e.seed).to eq(f.seed)
  end

  it 'has the aliases crush_rate and srr' do
    a = collect(220.hz.saw.decimate(3000), 1000)
    expect(collect(220.hz.saw.crush_rate(3000), 1000)).to eq(a)
    expect(collect(220.hz.saw.srr(3000), 1000)).to eq(a)
  end

  it 'runs per channel on bundles' do
    out = MB::Sound.stereo(220.hz.saw, 330.hz.saw).decimate(MB::Sound.channels(3000, 6000))
    expect(out).to be_a(MB::Sound::GraphNode::Channels)
    expect(out.outputs.map(&:rate)).to eq([3000.0, 6000.0])
  end

  it 'ends when its input or rate ends' do
    input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(1000)])
    node = input.decimate(4000)
    expect(collect(node, 5000).length).to eq(1000)

    rate = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(500) + 2000])
    node = 220.hz.saw.decimate(rate)
    expect(collect(node, 5000).length).to eq(500)
  end

  it 'rejects bad arguments' do
    expect { 220.hz.saw.decimate(3000, jitter: 1) }.to raise_error(ArgumentError, /jitter/)
    expect { 220.hz.saw.decimate(:x) }.to raise_error(ArgumentError, /rate/)
  end

  it 'prints itself back as Ruby' do
    node = 220.hz.saw.decimate(2500, jitter: 0.25, seed: 5)
    expect(node.to_ruby).to include('decimate(2500, jitter: 0.25, seed: 5)')
  end

  it 'describes itself' do
    expect(220.hz.saw.decimate(2500).to_s).to eq('Decimator 2500 Hz')
    expect(220.hz.saw.decimate(1.hz.lfo.at(100..200), jitter: 0.1).to_s).to eq('Decimator node Hz, jitter 0.1')
  end

  describe 'mix:' do
    it 'blends the crushed signal with the input' do
      dry = collect(220.hz.saw, 4800)
      wet = collect(220.hz.saw.decimate(3000), 4800)
      half = collect(220.hz.saw.decimate(3000, mix: 0.4), 4800)
      expect((half - (wet * 0.4 + dry * 0.6)).abs.max).to be < 1e-6
      expect(collect(220.hz.saw.decimate(3000, mix: 1), 4800)).to eq(wet)
      expect((collect(220.hz.saw.decimate(3000, mix: 0), 4800) - dry).abs.max).to be < 1e-7
    end

    it 'takes a node, the same at any buffer size' do
      make = -> { 110.hz.saw.decimate(0.7.hz.lfo.at(500..9000), jitter: 0.4, seed: 7, mix: 0.3.hz.lfo.at(0..1)) }
      a = collect(make.(), 9600, 800)
      b = collect(make.(), 9600, [1, 7, 128, 33])
      expect(b).to eq(a)
      node = make.()
      expect(node.mix).to be_a(MB::Sound::GraphNode)
      expect(node.sources.keys).to include(:mix)
    end

    it 'prints back as Ruby and rejects bad values' do
      node = 220.hz.saw.decimate(2500, mix: 0.4)
      expect(node.to_ruby).to include('decimate(2500, mix: 0.4)')
      expect(node.to_s).to include('mix 0.4')
      expect { 220.hz.saw.decimate(2500, mix: :x) }.to raise_error(ArgumentError, /mix/)
    end
  end

  describe 'interpolation: :linear' do
    it 'is the same at any buffer size, prints back, and rejects unknown names' do
      make = -> { 330.hz.triangle.decimate(0.5.hz.lfo.at(2000..6000), interpolation: :linear, jitter: 0.2, seed: 3) }
      a = collect(make.(), 9600)
      b = collect(make.(), 9600, [1, 7, 128, 33])
      expect(b).to eq(a)
      hold = collect(330.hz.triangle.decimate(4000), 4800)
      lin = collect(330.hz.triangle.decimate(4000, interpolation: :foh), 4800)
      expect(lin).not_to eq(hold)
      node = 220.hz.saw.decimate(2500, interpolation: :linear)
      expect(node.interpolation).to eq(:linear)
      expect(node.to_ruby).to include('decimate(2500, interpolation: :linear)')
      expect(node.to_s).to include('linear')
      expect { 220.hz.saw.decimate(2500, interpolation: :cubic) }.to raise_error(ArgumentError, /interpolation/)
    end
  end
end
