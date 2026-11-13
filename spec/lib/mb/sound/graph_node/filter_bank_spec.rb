RSpec.describe(MB::Sound::GraphNode::FilterBank, :aggregate_failures) do
  let(:klass) { MB::Sound::GraphNode::FilterBank }

  def collect(node, total, size = 800, channel: nil)
    sizes = Array(size).cycle
    out = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      buf = channel.nil? ? node.sample(len) : node.outputs.map { |o| o.sample(len) }[channel]
      break if buf.nil?
      out << buf.dup
      n += buf.length
    end
    Numo::SFloat.hstack(out)
  end

  # Both channels of a stereo bundle, sampled together.
  def collect_stereo(bundle, total, size = 800)
    sizes = Array(size).cycle
    l = []
    r = []
    n = 0
    while n < total
      len = [sizes.next, total - n].min
      a, b = bundle.outputs.map { |o| o.sample(len) }
      break if a.nil?
      l << a.dup
      r << b.dup
      n += a.length
    end
    [Numo::SFloat.hstack(l), Numo::SFloat.hstack(r)]
  end

  def rms(x)
    Math.sqrt((Numo::DFloat.cast(x) ** 2).mean)
  end

  let(:noise_data) { MB::Sound.with_seed(3) { Numo::SFloat.cast(MB::Sound.noise.sample(48000)) } }
  def noise_input(n = 48000)
    MB::Sound::ArrayInput.new(data: [noise_data[0...n].dup])
  end

  describe 'kernel' do
    let(:rng) { Random.new(11) }

    def noise(n, scale = 1.0, offset = 0.0)
      Numo::SFloat.cast(Array.new(n) { (rng.rand - 0.5) * scale + offset })
    end

    # Runs FastFilter.filter_bank and the mirror on +node+'s config from the
    # same state with +signals+, expecting identical samples and states.
    def compare(n, x, node, signals)
      outs_a = Array.new(node.channels) { Numo::SFloat.zeros(n) }
      outs_b = Array.new(node.channels) { Numo::SFloat.zeros(n) }
      sa = Numo::DFloat.cast(noise(2 * node.band_count + 1, 0.01))
      sa[-1] = 790 # (a flush grid point within the block)
      sb = sa.dup
      MB::Sound::FastFilter.filter_bank(outs_a, x, node.config, signals, sa, 48000)
      klass.process_ruby(outs_b, x, node.config, signals, sb, 48000)
      # (as bytes: NaN samples compare unequal)
      outs_a.zip(outs_b).each_with_index { |(a, b), c| expect(a.to_binary).to eq(b.to_binary), "channel #{c}" }
      expect(sa.to_binary).to eq(sb.to_binary)
      outs_a
    end

    # Five distinct nodes (bank signals 0..4).
    let(:sig) { Array.new(5) { |i| (i + 1).constant } }

    it 'matches the Ruby mirror: parallel, stereo node pans, every width mode, normalized' do
      f, r, w, g, pn = sig
      bands = [
        { frequency: f, ratio: r, harmonic: 0, width: w, gain: g, pan: pn },
        { frequency: f, ratio: r, harmonic: 1, width: 30.cents, gain: 0.5, pan: 0.3 },
        { frequency: f, ratio: r, harmonic: 2, width: 40.hz, gain: g, pan: pn },
        { type: :bandpass_skirt, frequency: 900, width: 2, gain: 0.25 },
      ]
      node = klass.new(110.hz.saw, bands: bands, normalize: true)
      expect(node.channels).to eq(2)
      x = noise(1500)
      compare(1500, x, node, [200.0, 1.0, 14.0, 1.0, 0.0])
      compare(1500, x, node, [noise(1500, 400, 300), noise(1500, 1, 1), noise(1500, 20, 12), noise(1500, 1, 0.5), noise(1500, 2.4)])
      compare(1500, Numo::DFloat.cast(x), node, [noise(1500, 400, 300), 1.5, Numo::DFloat.cast(noise(1500, 20, 12)), 0.7, noise(1500, 2.4)])
    end

    it 'matches the Ruby mirror for serial banks and every type and design' do
      types = MB::Sound::Filter::SVF::FILTER_TYPES
      bands = types.map.with_index { |t, i|
        first = MB::Sound::Filter::SVF::FIRST_ORDER_TYPES.include?(t)
        { type: t, frequency: 300 * (i + 1), width: first ? nil : (i.even? ? 0.8 : 0.5.oct), gain: 1.2 }.compact
      }
      f = 2.constant
      matched = MB::Sound::Filter::SVF::MATCHED_TYPES.map { |t| { type: t, response: :matched, frequency: f, gain: 1.0 } }
      x = noise(900)
      compare(900, x, klass.new(110.hz.saw, bands: bands, serial: true), [])
      compare(900, x, klass.new(110.hz.saw, bands: bands + matched), [noise(900, 3000, 9000)])
    end

    it 'matches the Ruby mirror for edge-case settings (NaN, infinities, negatives, zero)' do
      odd = Numo::SFloat.cast([Float::NAN, -1, 2, 0, 0.5, 1, Float::INFINITY, -Float::INFINITY] * 30)
      f, r, w, g, pn = sig
      bands = [
        { frequency: f, ratio: r, harmonic: 1, width: w, gain: g, pan: pn },
        { frequency: f, width: 30.cents, gain: g },
        { frequency: f, width: 1.hz.lfo, gain: 1 },
      ]
      node = klass.new(110.hz.saw, bands: bands, normalize: true)
      compare(odd.length, noise(odd.length), node, [odd * 1000, odd, odd * 10, odd, odd, odd * 50])
    end

    it 'raises for bad arguments' do
      node = klass.new(110.hz.saw, bands: [{ frequency: 300 }, { frequency: 2.constant }])
      cfg = node.config
      st = Numo::DFloat.zeros(5)
      out = [Numo::SFloat.zeros(4)]
      [MB::Sound::FastFilter.method(:filter_bank), klass.method(:process_ruby)].each do |k|
        expect { k.call(out, 0.0, cfg, [], st, 48000) }.to raise_error(ArgumentError, /signals/)
        expect { k.call(out, 0.0, cfg, [1.0], Numo::DFloat.zeros(4), 48000) }.to raise_error(ArgumentError, /state/)
        expect { k.call(out, 0.0, cfg, [1.0], st, 0) }.to raise_error(ArgumentError, /rate/)
        expect { k.call(out * 2, 0.0, cfg, [1.0], st, 48000) }.to raise_error(ArgumentError, /channels/)
        expect { k.call(out, 0.0, cfg[0...20], [1.0], st, 48000) }.to raise_error(ArgumentError, /length/)
        expect { k.call(out, Numo::SFloat.zeros(3), cfg, [1.0], st, 48000) }.to raise_error(ArgumentError, /length/)
        bad = cfg.dup
        bad[klass::HEADER] = 99
        expect { k.call(out, 0.0, bad, [1.0], st, 48000) }.to raise_error(ArgumentError, /type/)
        bad = cfg.dup
        bad[klass::HEADER + 1] = 5
        expect { k.call(out, 0.0, bad, [1.0], st, 48000) }.to raise_error(ArgumentError, /slot/)
      end
      expect { MB::Sound::FastFilter.filter_bank([Numo::DFloat.zeros(4)], 0.0, cfg, [1.0], st, 48000) }.to raise_error(ArgumentError, /SFloat/)
    end
  end

  describe 'widths' do
    it 'reads Intervals as octaves (the cookbook bandwidth), frequencies as Hz, numbers and nodes as Q' do
      w = ->(v) { klass.width_of(v).then { |x| [x.mode, x.value.is_a?(Numeric) ? x.value : :node] } }
      expect(w.(30.cents)).to eq([:octaves, 0.025])
      expect(w.(1.oct)).to eq([:octaves, 1.0])
      expect(w.(40.hz)).to eq([:hz, 40.0])
      expect(w.(14.14)).to eq([:q, 14.14])
      expect(w.(3r)).to eq([:q, 3.0])
      expect(w.(2.hz.lfo)).to eq([:q, :node])
      expect(w.(2.hz.lfo.at(20..80).freq)).to eq([:hz, :node])
      expect { klass.width_of(0) }.to raise_error(ArgumentError, /positive/)
      expect { klass.width_of(-6.db) }.to raise_error(ArgumentError, /width/)
      expect { klass.width_of(:wide) }.to raise_error(ArgumentError, /Interval/)

      expect(klass.width_quality(:octaves, 1.0 / 3, 1000, 48000)).to eq(MB::Sound::Filter::Cookbook.new(:peak, 48000, 1000, db_gain: 0, bandwidth_oct: 1.0 / 3).quality)
      expect(klass.width_quality(:hz, 40.0, 1000, 48000)).to eq(25.0)
    end

    it 'keeps the same musical width on every band with cents, and the same Hz width with a frequency' do
      cents = 110.hz.saw.bandpass_series(200, count: 4, width: 50.cents)
      hz = 110.hz.saw.bandpass_series(200, count: 4, width: 20.hz)
      qs = ->(node) { node.band_list.map { |b| klass.width_quality(b[:width].mode, b[:width].value, 200.0 * (1 + b[:harmonic]), 48000) } }
      expect(qs.(cents).map { |q| q.round(1) }.uniq.length).to eq(1) # (within the bilinear prewarp at low frequencies)
      expect(qs.(hz)).to eq([10.0, 20.0, 30.0, 40.0])

      # A moving fundamental: the Hz width follows (Q = f / bw on every change)
      a = collect(noise_input.bandpass_series(100.constant, count: 3, width: 20.hz), 4000)
      b = collect(noise_input.filter_bank([100, 200, 300], quality: [5, 10, 15]), 4000)
      expect((a - b).abs.max).to be < 1e-6
    end
  end

  describe 'normalization' do
    it 'has the closed form of the pink-noise power of an analog bandpass' do
      [0.2, 0.5, 0.7071, 3, 30].each do |q|
        x = Numo::DFloat.linspace(-12, 12, 200_001)
        dx = x[1] - x[0]
        integral = (1.0 / (1 + 4 * q * q * Numo::NMath.sinh(x)**2)).sum * dx
        expect(klass.pink_power(q)).to be_within(1e-6 * integral).of(integral), "Q #{q}"
      end
      expect(klass::NORMALIZE_REFERENCE).to eq(Math.log(100.0))
    end

    it 'keeps pink power through the bank as widths and counts change' do
      # (the analytic responses of the bands' sum on a log grid, 100 Hz-10
      # kHz, times the normalization scale, against the reference band)
      levels = [[8, 10], [8, 40], [16, 20], [4, 3]].map { |count, q|
        node = 110.hz.saw.bandpass_series(150, count: count, quality: q, normalize: true)
        freqs = Numo::NMath.exp(Numo::DFloat.linspace(Math.log(20), Math.log(22000), 100_000))
        power = (node.response(freqs).abs**2)
        dlnf = Math.log(freqs[1] / freqs[0])
        sum = node.band_list.sum { |b| klass.pink_power(b[:width].value) }
        10 * Math.log10(power.sum * dlnf * klass::NORMALIZE_REFERENCE / sum / klass::NORMALIZE_REFERENCE)
      }
      # (narrow bands hold within 0.3 dB; bands that overlap, as fixed-Q
      # bands do up a harmonic series, add between their peaks, which the
      # sum of powers leaves out: +0.9 dB at Q 10 over 8 harmonics of 150
      # Hz, +1.0 at Q 20 over 16, +1.7 at Q 3 over 4)
      expect(levels[1].abs).to be < 0.3
      levels.each { |l| expect(l.abs).to be < 2.5 }

      wide = rms(collect(noise_input.bandpass_series(300, count: 8, quality: 5, normalize: true), 48000))
      narrow = rms(collect(noise_input.bandpass_series(300, count: 8, quality: 40, normalize: true), 48000))
      expect((narrow / wide).to_db.abs).to be < 4 # (white noise: higher bands weigh more than pink)
      plain = rms(collect(noise_input.bandpass_series(300, count: 8, quality: 40), 48000))
      expect((plain / wide).to_db).to be < -6
    end

    it 'takes only bandpass bands' do
      expect { 110.hz.saw.filter_bank([300], type: :peak, gain: 2, normalize: true) }.to raise_error(ArgumentError, /bandpass/)
      expect { 110.hz.saw.peq_series(100) }.not_to raise_error
    end
  end

  describe 'channels and pans' do
    it 'pans bands with the pan laws, constant and moving alike' do
      c = collect_stereo(noise_input.bandpass_series(500, count: 3, pan: [-1, 0, 0.5]), 4800)
      m = collect_stereo(noise_input.bandpass_series(500, count: 3, pan: [-1.constant, 0.constant, 0.5.constant]), 4800)
      expect(m).to eq(c)

      left = collect(noise_input.filter_bank([500], pan: -1), 4800, channel: 1)
      expect(left.abs.max).to be < 1e-7
      g = MB::Sound::GraphNode::ChannelMixer::PanLaws.gains(:equal_power, 0.5)
      bank = noise_input.filter_bank([500], pan: 0.5)
      expect(bank.outputs.length).to eq(2)
      expect(bank.outputs[0].sources[:owner].bank.band_list[0][:pan]).to eq(0.5)
      mono = collect(noise_input.filter_bank([500]), 4800)
      l, r = collect_stereo(noise_input.filter_bank([500], pan: 0.5), 4800)
      expect((l - mono * g[0]).abs.max).to be < 1e-6
      expect((r - mono * g[1]).abs.max).to be < 1e-6
      l2, = collect_stereo(noise_input.filter_bank([500], pan: 0.5, pan_law: :linear), 4800)
      expect((l2 - mono * 0.25).abs.max).to be < 1e-6
    end

    it 'takes any constant gain vector per band (the surround path)' do
      node = klass.new(noise_input, bands: [{ frequency: 400, gains: [1, 0, 0.5] }, { frequency: 2000, gains: [0, 1, 0.5] }])
      expect(node.channels).to eq(3)
      a, b, c = node.outputs
      la = []
      3.times { la << [a, b, c].map { |o| o.sample(400).dup } }
      one = collect(klass.new(noise_input, bands: [{ frequency: 400 }]), 1200)
      expect((Numo::SFloat.hstack(la.map(&:first)) - one).abs.max).to be < 1e-6
      expect { klass.new(110.hz.saw, bands: [{ frequency: 400 }], channels: 3) }.to raise_error(ArgumentError, /gains/)
      expect { klass.new(110.hz.saw, bands: [{ frequency: 400, pan: 0.5 }], channels: 3) }.to raise_error(ArgumentError, /two channels/)
    end

    it 'samples a multichannel bank through its outputs only' do
      bank = 110.hz.saw.bandpass_series(200, count: 2, pan: -1..1)
      expect(bank).to be_a(MB::Sound::GraphNode::Channels)
      expect { bank.outputs[0].sources[:owner].bank.sample(10) }.to raise_error(NotImplementedError, /outputs/)
    end
  end

  describe 'serial banks' do
    it 'chains bands, rounding to float32 between them as a chain of SVFs did' do
      a = collect(noise_input.filter_bank([200, 3000], type: [:lowshelf, :highshelf], quality: 0.7, gain: [3.db, -4.db], serial: true), 4800)
      b = collect(noise_input.filter(:lowshelf, cutoff: 200, quality: 0.7, gain: 3.db).filter(:highshelf, cutoff: 3000, quality: 0.7, gain: -4.db), 4800)
      expect((a - b).abs.max).to be < 1e-6
      expect { 110.hz.saw.filter_bank([200], serial: true, pan: 0.5) }.to raise_error(ArgumentError, /mono/)
      expect { 110.hz.saw.filter_bank([200], serial: true, normalize: true) }.to raise_error(ArgumentError, /normalize/)
    end
  end

  it 'gives the same output at any buffer size with moving settings' do
    make = -> {
      noise_input.bandpass_series(0.5.hz.lfo.at(150..300), count: 5, ratio: 0.3.hz.lfo.at(0.9..1.2), width: 0.2.hz.lfo.at(5..30),
                                  gain: [1, 0.7.hz.lfo.at(0.2..1)], pan: 1.hz.lfo, normalize: true)
    }
    expect(collect_stereo(make.(), 9600, [1, 7, 128, 33])).to eq(collect_stereo(make.(), 9600, 800))
  end

  it 'reads a node shared by every band once (one signal per distinct node)' do
    f0 = 2.hz.lfo.at(200..300)
    node = noise_input.bandpass_series(f0, count: 12, quality: 20)
    expect(node.config[6]).to eq(1)
    expect(node.sources.keys).to eq([:input, :param_1])
  end

  it 'ends when its input or a parameter node ends' do
    input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.ones(1000)])
    expect(collect(input.bandpass_series(300), 5000).length).to eq(1000)

    f = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(300) + 500])
    expect(collect(110.hz.saw.bandpass_series(f), 5000).length).to eq(300)
  end

  it 'carries its state by snapshot (and starts fresh from a snapshot of another size)' do
    a = noise_input.bandpass_series(300, count: 3)
    a.sample(500)
    b = 110.hz.saw.bandpass_series(300, count: 3)
    b.plan_restore(a.plan_snapshot)
    expect(b.plan_snapshot).to eq(a.plan_snapshot)
    c = 110.hz.saw.bandpass_series(300, count: 4)
    c.plan_restore(a.plan_snapshot)
    expect(c.plan_snapshot.uniq).to eq([0.0])
    expect(MB::Sound::NodeTraits.of(a)).to be_snapshot
  end

  it 'rejects bad settings with helpful messages' do
    expect { 110.hz.saw.filter_bank([]) }.to raise_error(ArgumentError, /at least one/)
    expect { 110.hz.saw.filter_bank([300], type: :bogus) }.to raise_error(ArgumentError, /Unknown filter type/)
    expect { 110.hz.saw.filter_bank([300], width: 2, quality: 3) }.to raise_error(ArgumentError, /not both/)
    expect { 110.hz.saw.filter_bank([:x]) }.to raise_error(ArgumentError, /frequencies/)
    expect { 110.hz.saw.filter_bank([300], type: :lowpass1p, width: 3) }.to raise_error(ArgumentError, /width/)
    expect { 110.hz.saw.filter_bank([300], gain: -6) }.to raise_error(ArgumentError, /gain/)
    expect { 110.hz.saw.bandpass_series(300, count: 0) }.to raise_error(ArgumentError, /count/)
    expect { 110.hz.saw.filter_bank([300], pan_law: :balance) }.to raise_error(ArgumentError, /pan law/)
  end

  it 'prints itself back as Ruby and loads from a graph document' do
    g = 110.hz.saw.bandpass_series(110, count: 6, width: MB::Sound.per_harmonic(15.cents..90.cents, curve: :exp), pan: -1..1, gain: MB::Sound.per_harmonic(0.db, -3.db))
    expect(g.to_ruby).to include('bandpass_series(110, count: 6, width: per_harmonic(15.cents..90.cents, curve: :exp), pan: -1..1, gain: per_harmonic(0.db, -3.db))')
    loaded = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g))
    expect(collect_stereo(loaded, 2000)).to eq(collect_stereo(g, 2000))

    m = 110.hz.saw.filter_bank([300, 900.hz], width: 40.hz, gain: [1, -6.db], type: :peak, serial: true)
    expect(m.to_ruby).to include('filter_bank([300, 900.hz], width: 40.hz, gain: [1, -6.db], type: :peak, serial: true)')
    expect(collect(MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(m)), 2000)).to eq(collect(m, 2000))
    expect(m.to_s).to eq('FilterBank 2 peak serial')
  end
end
