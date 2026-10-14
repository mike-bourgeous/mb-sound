RSpec.describe(MB::Sound::GraphNode::ModalResonator, :aggregate_failures) do
  def impulses(length, hits)
    data = Numo::SFloat.zeros(length)
    hits.each { |i, v| data[i] = v }
    MB::Sound::ArrayInput.new(data: [data])
  end

  # Samples +node+ in buffers of the given sizes (cycled) until it ends or
  # +limit+ samples.
  def collect(node, limit: 48000 * 60, sizes: [800])
    out = []
    total = 0
    sizes.cycle do |s|
      break if total >= limit
      buf = node.sample(s)
      break if buf.nil?
      out << buf.dup
      total += buf.length
    end
    out.empty? ? Numo::SFloat[] : Numo::SFloat.hstack(out)[0...[total, limit].min]
  end

  # The magnitude spectrum's peak frequencies (Hz) of +x+, strongest first.
  def peaks(x, count)
    n = 1 << 16
    padded = Numo::SFloat.zeros(n)
    padded[0...[x.length, n].min] = x[0...[x.length, n].min]
    mag = MB::Sound.real_fft(padded).abs
    found = []
    (2...(mag.length - 2)).each do |i|
      found << [mag[i], i] if mag[i] > mag[i - 1] && mag[i] >= mag[i + 1] && mag[i] > mag[i - 2] && mag[i] >= mag[i + 2]
    end
    found.sort.reverse.first(count).map { |_m, i| i * 48000.0 / n }
  end

  it 'rings the preset modes at their ratios' do
    out = collect(impulses(4800, { 0 => 1 }).resonate(:bar, 200), limit: 65536)
    found = peaks(out, 5).sort
    expected = [1.0, 2.756, 5.404, 8.933, 13.34].map { |r| r * 200 }
    found.zip(expected).each { |f, e| expect(f).to be_within(2).of(e) }
  end

  it 'takes the preset and frequency in either order, and Pitches' do
    a = collect(impulses(4800, { 0 => 1 }).resonate(:glass, 440), limit: 9600)
    b = collect(impulses(4800, { 0 => 1 }).resonate(440, :glass), limit: 9600)
    c = collect(impulses(4800, { 0 => 1 }).resonate(:glass, 440.hz), limit: 9600)
    expect(a).to eq(b)
    expect(a).to eq(c)
  end

  it 'normalizes so a strike of 1 never peaks above 1' do
    MB::Sound::GraphNode::ModalResonator::PRESETS.each_key do |name|
      out = collect(impulses(4800, { 0 => 1 }).resonate(name, 330), limit: 48000)
      expect(out.abs.max).to be <= 1.0
      expect(out.abs.max).to be > 0.1, name.to_s
    end
  end

  it 'scales with the strike height' do
    a = collect(impulses(4800, { 0 => 1 }).resonate(:gong, 110), limit: 9600)
    b = collect(impulses(4800, { 0 => 0.5 }).resonate(:gong, 110), limit: 9600)
    expect((b - a * 0.5).abs.max).to be < 1e-6
  end

  it 'matches the sum of pings for a bowl (the ambient bowl) within float32 rounding' do
    pre = MB::Sound::GraphNode::ModalResonator.preset(:bowl)
    strike = impulses(48000, { 0 => 1, 30000 => 0.6 })
    modal = collect(strike.resonate(:bowl, 220, normalize: false), limit: 48000)
    pings = MB::Sound::GraphNode::Tee.new(impulses(48000, { 0 => 1, 30000 => 0.6 }), pre.modes.length * 2).branches
    sum = pre.modes.each_with_index.map { |(r, amp, dec, mult), i|
      pings[2 * i].ping(220 * r, decay: pre.decay * dec) * amp +
        pings[2 * i + 1].ping(220 * r + pre.beat * mult, decay: pre.decay * dec * 0.8) * (amp * 0.7)
    }.reduce(:+)
    ref = collect(sum, limit: 48000)
    expect((modal - ref).abs.max).to be < 1e-4
  end

  it 'falls 60 dB over the decay (one mode)' do
    out = collect(impulses(48000, { 0 => 1 }).resonate([[1, 1, 1]], 480, decay: 0.5), limit: 48000)
    level = ->(t) { i = (t * 48000).round; out[i...(i + 100)].abs.max }
    expect((level.(0.5) / level.(0.0)).to_db).to be_within(0.5).of(-60)
  end

  it 'adds doublet partners that beat' do
    plain = impulses(4800, { 0 => 1 }).resonate(:bowl, 220, beat: 0)
    beating = impulses(4800, { 0 => 1 }).resonate(:bowl, 220)
    expect(plain.mode_rows.length).to eq(4)
    expect(beating.mode_rows.length).to eq(8)
    expect(beating.mode_rows[1][1]).to eq(0.7)
  end

  it 'silences modes the sample rate cannot hold' do
    out = collect(impulses(4800, { 0 => 1 }).resonate([[1, 1], [40, 1]], 1000, normalize: false), limit: 9600)
    expect(peaks(out, 1).first).to be_within(2).of(1000)
    expect(out.abs.max).to be <= 1.0
  end

  it 'rings out after the input ends, then ends on the same sample at any buffer size' do
    a = collect(impulses(1000, { 0 => 1 }).resonate(:marimba, 300))
    b = collect(impulses(1000, { 0 => 1 }).resonate(:marimba, 300), sizes: [1, 7, 128, 333, 800])
    expect(a.length).to be > 48000
    expect(a.length).to be < 48000 * 6
    expect(a).to eq(b)
  end

  it 'follows a moving frequency and decay node at any buffer size' do
    make = -> { MB::Sound.dust(20, seed: 3).resonate(:vibes, 2.hz.lfo.at(200..400), decay: 1.hz.lfo.at(0.5..2)) }
    a = collect(make.(), limit: 20000)
    b = collect(make.(), limit: 20000, sizes: [1, 7, 128, 333, 800])
    expect(a).to eq(b)
  end

  it 'spreads alternating modes into stereo' do
    out = impulses(4800, { 0 => 1 }).resonate(:bar, 200, spread: 1)
    expect(out.channel_count).to eq(2)
    l = []
    r = []
    82.times { l << out[0].sample(800).dup; r << out[1].sample(800).dup }
    l = Numo::SFloat.hstack(l)
    r = Numo::SFloat.hstack(r)
    # Modes 1, 3, 5 left; 2, 4 right (the other side at 1 - spread = 0)
    expect(peaks(l, 3).sort).to match([be_within(2).of(200), be_within(2).of(1080.8), be_within(2).of(2668)])
    expect(peaks(r, 2).sort).to match([be_within(2).of(551.2), be_within(2).of(1786.6)])

    mono = impulses(4800, { 0 => 1 }).resonate(:bar, 200, spread: 0)
    expect(mono[0].sample(800).dup).to eq(mono[1].sample(800))
  end

  it 'raises with suggestions for unknown presets and bad modes' do
    expect { impulses(10, {}).resonate(:bwol, 200) }.to raise_error(ArgumentError, /did you mean :bowl/)
    expect { impulses(10, {}).resonate(:bowl) }.to raise_error(ArgumentError, /frequency/)
    expect { impulses(10, {}).resonate([], 200) }.to raise_error(ArgumentError, /Modes/)
    expect { impulses(10, {}).resonate([[1, 'x']], 200) }.to raise_error(ArgumentError, /mode/)
  end
end
