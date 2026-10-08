RSpec.describe(MB::Sound::GraphNode::Chorus) do
  # Reads +seconds+ of every output of +bundle+ in turn, as a Session does,
  # returning one NArray per channel.
  def render(bundle, seconds, buffer: 480)
    rate = bundle.sample_rate
    outs = bundle.outputs
    bufs = Array.new(outs.length) { [] }
    (seconds * rate / buffer).ceil.times do
      outs.each_with_index { |o, i| bufs[i] << o.sample(buffer).dup }
    end
    bufs.map { |b| Numo::SFloat.cast(b).flatten }
  end

  # Impulses every +spacing+ samples for +seconds+ at +rate+.
  def clicks(seconds, rate: 48000, spacing: 480)
    data = Numo::SFloat.zeros((seconds * rate).round)
    data[(0...data.length).step(spacing).to_a] = 1
    MB::Sound::ArrayInput.new(data: [data], sample_rate: rate)
  end

  # The delay in samples of each click's echo in +out+ (the largest sample
  # within +spacing+ after the click).
  def echo_delays(out, spacing: 480)
    (0...(out.length - spacing)).step(spacing).map { |k| out[k...(k + spacing)].abs.max_index }
  end

  # Wet-only echo delays of both sides for +mode+ over +seconds+.
  def delays_for(mode, seconds: 2, sample_rate: 48000, **opts)
    c = clicks(seconds + 0.02, rate: sample_rate).chorus(mode, dry: 0, **opts)
    render(c, seconds).map { |out| echo_delays(out) }
  end

  # How many times +delays+ cross their middle.
  def crossings(delays)
    mid = (delays.min + delays.max) / 2.0
    delays.map { |d| d > mid }.each_cons(2).count { |a, b| a != b }
  end

  describe 'GraphNode#chorus' do
    it 'turns a mono node into a stereo bundle' do
      c = 220.hz.ramp.chorus
      expect(c).to be_a(MB::Sound::GraphNode::Channels)
      expect(c.channel_count).to eq(2)
      expect(c.outputs.map(&:graph_node_name)).to eq(['Juno chorus L', 'Juno chorus R'])
    end

    it 'choruses a stereo bundle as one (not per channel)' do
      c = MB::Sound.stereo(220.hz.ramp, 330.hz.ramp).chorus(:juno2)
      expect(c.channel_count).to eq(2)
    end

    it 'keeps the dry sides of a stereo input' do
      ldata = Numo::SFloat.new(4800).rand(-1, 1)
      rdata = Numo::SFloat.new(4800).rand(-1, 1)
      l = MB::Sound::ArrayInput.new(data: [ldata.dup])
      r = MB::Sound::ArrayInput.new(data: [rdata.dup])
      out = render(MB::Sound.stereo(l, r).chorus(wet: 0), 0.09)
      expect(out[0][0...4320]).to eq(ldata[0...4320])
      expect(out[1][0...4320]).to eq(rdata[0...4320])
    end

    it 'feeds the delay line with the average of a stereo input' do
      stereo = MB::Sound.stereo(clicks(0.2), clicks(0.2) * 0).chorus(dry: 0)
      mono = clicks(0.2).chorus(dry: 0)
      a = render(stereo, 0.15)
      b = render(mono, 0.15)
      expect((a[0] - b[0] * 0.5).abs.max).to be < 1e-6
      expect((a[1] - b[1] * 0.5).abs.max).to be < 1e-6
    end

    it 'raises for more than two channels' do
      expect { MB::Sound.channels(1.hz, 2.hz, 3.hz).chorus }.to raise_error(ArgumentError, /one or two/)
    end

    it 'raises for unknown modes' do
      expect { 220.hz.chorus(:dimension_d) }.to raise_error(ArgumentError, /Unknown chorus mode/)
    end

    it 'raises for a depth that would make negative delays' do
      expect { 220.hz.chorus(depth: 3) }.to raise_error(ArgumentError, /below zero/)
    end
  end

  describe 'modulation' do
    {
      juno1: [0.00166, 0.00535, 0.513],
      juno2: [0.00166, 0.00535, 0.863],
      juno12: [0.0033, 0.0037, 9.75],
    }.each do |mode, (lo, hi, rate)|
      it "sweeps #{mode} over #{lo * 1000}-#{hi * 1000} ms at #{rate} Hz, the right side inverted" do
        seconds = mode == :juno1 ? 4 : 2
        l, r = delays_for(mode, seconds: seconds)

        expect(l.min).to be_within(1.5).of(lo * 48000)
        expect(l.max).to be_within(1.5).of(hi * 48000)
        expect(r.min).to be_within(1.5).of(lo * 48000)
        expect(r.max).to be_within(1.5).of(hi * 48000)

        sums = l.zip(r).map(&:sum)
        expect(sums.max - sums.min).to be <= 3
        expect(sums.sum.to_f / sums.length).to be_within(1).of((lo + hi) * 48000)

        expect(crossings(l)).to be_within(2).of(2 * rate * seconds)
      end
    end

    it 'gives the modes different modulation' do
      a = delays_for(:juno1)[0]
      b = delays_for(:juno2)[0]
      c = delays_for(:juno12)[0]
      expect(a).not_to eq(b)
      expect(b).not_to eq(c)
      expect(a).not_to eq(c)
    end

    it 'accepts a rate, depth, and delay range' do
      l, _ = delays_for(:juno1, rate: 1, depth: 0.5, delay: 2.ms..6.ms, seconds: 2)
      expect(l.min).to be_within(2.5).of(0.003 * 48000)
      expect(l.max).to be_within(2.5).of(0.005 * 48000)
      expect(crossings(l)).to be_within(1).of(4)
    end

    it 'accepts a node depth' do
      a, _ = delays_for(:juno2, seconds: 1)
      b, _ = delays_for(:juno2, seconds: 1, depth: 1.constant)
      expect(b).to eq(a)
    end

    it 'gives a fixed delay at depth 0' do
      l, r = delays_for(:juno1, depth: 0, seconds: 0.5)
      expect(l.uniq).to eq([168])
      expect(r.uniq).to eq([168])
    end

    it 'accepts a tempo-synced rate' do
      c = 220.hz.ramp.chorus(rate: 1.bar)
      expect(render(c, 0.1).map { |o| o.abs.max }).to all(be > 0.5)
    end
  end

  describe 'sample rate changes' do
    it 'keeps delay times in seconds' do
      l, r = delays_for(:juno12, seconds: 1, sample_rate: 96000)
      expect(l.max).to be_within(2).of(0.0037 * 96000)
      expect(l.min).to be_within(2).of(0.0033 * 96000)
      expect(r.max).to be_within(2).of(0.0037 * 96000)
      expect(crossings(l)).to be_within(2).of(2 * 9.75)
    end

    it 'matches a chorus built at the new rate after sample_rate=' do
      a = 1000.hz.sine.chorus(:juno2, bbd: true, seed: 1)
      a.sample_rate = 96000
      expect(a.sample_rate).to eq(96000)
      b = 1000.hz.sine.at_rate(96000).chorus(:juno2, bbd: true, seed: 1)
      expect(b.sample_rate).to eq(96000)
      x = render(a, 0.3)
      y = render(b, 0.3)
      expect((x[0] - y[0]).abs.max).to be < 1e-5
      expect((x[1] - y[1]).abs.max).to be < 1e-5
    end
  end

  describe 'determinism' do
    it 'renders the same samples twice' do
      a = render(220.hz.ramp.chorus(:juno2), 0.5)
      b = render(220.hz.ramp.chorus(:juno2), 0.5)
      expect(a).to eq(b)
    end

    it 'repeats BBD hiss from the root seed and from seed:' do
      MB::Sound.seed(3)
      a = render(220.hz.ramp.chorus(bbd: true), 0.2)
      MB::Sound.seed(3)
      b = render(220.hz.ramp.chorus(bbd: true), 0.2)
      expect(a).to eq(b)

      c = render(220.hz.ramp.chorus(bbd: true, seed: 7), 0.2)
      d = render(220.hz.ramp.chorus(bbd: true, seed: 7), 0.2)
      expect(c).to eq(d)
      expect(c).not_to eq(a)
    end

    it 'has independent hiss on each side' do
      l, r = render(0.constant.chorus(hiss: -40), 0.2)
      expect(l.abs.max).to be_within(6.db).of(-40.db)
      expect(l).not_to eq(r)
    end
  end

  describe 'mix:' do
    let(:input) { -> { 220.hz.ramp.at(0.5) } }

    def same(a, b, tol = 1e-6)
      a.zip(b).each { |x, y| expect((x - y).abs.max).to be < tol }
    end

    it 'gives the dry signal at 0' do
      same(render(input.call.chorus(mix: 0), 0.2), render(input.call.chorus(wet: 0), 0.2))
    end

    it 'gives the wet signal at 1' do
      same(render(input.call.chorus(mix: 1), 0.2), render(input.call.chorus(dry: 0), 0.2))
    end

    it 'crossfades linearly, multiplying dry: and wet:' do
      full = render(input.call.chorus, 0.2)
      half = render(input.call.chorus(mix: 0.5), 0.2)
      same(half, full.map { |c| c * 0.5 })

      a = render(input.call.chorus(dry: 0.5, wet: 0.8, mix: 0.25), 0.2)
      b = render(input.call.chorus(dry: 0.375, wet: 0.2), 0.2)
      same(a, b)
    end

    it 'accepts a node, clamped to 0..1' do
      same(render(input.call.chorus(mix: 0.3.constant), 0.2), render(input.call.chorus(mix: 0.3), 0.2))
      same(render(input.call.chorus(mix: 1.5.constant), 0.2), render(input.call.chorus(mix: 1), 0.2))
    end

    it 'raises for numbers outside 0..1' do
      expect { 220.hz.chorus(mix: 1.2) }.to raise_error(ArgumentError, /mix/)
      expect { 220.hz.chorus(mix: -0.1) }.to raise_error(ArgumentError, /mix/)
    end
  end

  describe ':lush (stacked I and II)' do
    it 'is the equal-power sum of modes I and II, differing from I+II' do
      in1 = clicks(1.2).chorus(:juno1, dry: 0)
      in2 = clicks(1.2).chorus(:juno2, dry: 0)
      lush = clicks(1.2).chorus(:lush, dry: 0)
      a = render(in1, 1)
      b = render(in2, 1)
      c = render(lush, 1)
      2.times do |ch|
        expect((c[ch] - (a[ch] + b[ch]) * Math.sqrt(0.5)).abs.max).to be < 1e-5
      end

      d = render(clicks(1.2).chorus(:juno12, dry: 0), 1)
      expect((c[0] - d[0]).abs.max).to be > 0.1
    end

    it 'contains both sweeps (two echoes per click, at the I and II delays)' do
      l, _ = render(clicks(1.2).chorus(:lush, dry: 0), 1)
      d1 = delays_for(:juno1, seconds: 1)[0]
      d2 = delays_for(:juno2, seconds: 1)[0]
      (0...(l.length / 480 - 1)).each do |k|
        seg = l[(k * 480)...((k + 1) * 480)]
        expect(seg[d1[k]].abs).to be > 0.3
        expect(seg[d2[k]].abs).to be > 0.3
      end
    end

    it 'has the aliases :juno3 and :stacked' do
      a = render(220.hz.ramp.chorus(:lush), 0.1)
      expect(render(220.hz.ramp.chorus(:juno3), 0.1)).to eq(a)
      expect(render(220.hz.ramp.chorus(:stacked), 0.1)).to eq(a)
    end

    it 'no longer accepts :juno_both, keeping :juno_i_ii' do
      expect { 220.hz.chorus(:juno_both) }.to raise_error(ArgumentError, /Unknown/)
      expect(render(220.hz.ramp.chorus(:juno_i_ii), 0.1)).to eq(render(220.hz.ramp.chorus(:juno12), 0.1))
    end

    it 'takes one rate per LFO, or a number keeping their ratio' do
      a = render(clicks(1.2).chorus(:lush, dry: 0, rate: [1, 1.5]), 1)
      b = render(clicks(1.2).chorus(:lush, dry: 0, rate: 1), 1)
      c = render(clicks(1.2).chorus(:lush, dry: 0, rate: [1, 0.863 / 0.513]), 1)
      expect(a).not_to eq(b)
      expect((b[0] - c[0]).abs.max).to be < 1e-6
      expect { 220.hz.chorus(:lush, rate: [1]) }.to raise_error(ArgumentError, /2 rates/)
      expect { 220.hz.chorus(:lush, rate: 1.bar) }.to raise_error(ArgumentError, /2 LFOs/)
    end
  end

  describe 'ending' do
    it 'ends after the input plus the delay tail, with the delayed signal in the tail' do
      data = Numo::SFloat.zeros(4800)
      data[-1] = 1
      c = MB::Sound::ArrayInput.new(data: [data]).chorus(dry: 0, depth: 0, bbd: true, seed: 1)
      outs = c.outputs
      lengths = 0
      bufs = []
      100.times do
        b = outs.map { |o| o.sample(480) }
        break if b.any?(&:nil?)
        bufs << b[0].dup
        lengths += b[0].length
      end
      out = Numo::SFloat.cast(bufs).flatten
      tail = ((0.00166 + 0.00535) / 2 + MB::Sound::GraphNode::Chorus::TAIL_EXTRA) * 48000
      expect(lengths).to be_within(480).of(4800 + tail)
      expect(out[4800..].abs.max).to be > 0.1
    end

    it 'fades the hiss out once an upstream Ringdown has ended' do
      input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(4800)]).ringdown
      l, r = render(input.chorus(hiss: -40, seed: 1), 0.5)
      expect(l[0...4800].abs.max).to be > -46.db
      tail = (0.00535 + MB::Sound::GraphNode::Chorus::TAIL_EXTRA) * 48000
      expect(l[(4800 + tail.ceil + 480)..].abs.max).to eq(0)
      expect(r[(4800 + tail.ceil + 480)..].abs.max).to eq(0)
    end

    it 'keeps the hiss for inputs that never end' do
      l, _ = render(0.constant.chorus(hiss: -40), 1)
      expect(l[-4800..].abs.max).to be > -46.db
    end
  end

  describe 'BBD flavour' do
    # The analog all-pole response in dB of +poles+ at +f+ Hz.
    def analog_db(poles, f, scale = 1)
      s = Complex(0, f)
      poles.sum { |pf, q|
        pf *= scale
        h = q ? pf**2 / (pf**2 - f**2 + s * pf / q) : pf / (pf + s)
        20 * Math.log10(h.abs)
      }
    end

    # The wet-only level in dB of a +freq+ sine through the chorus.
    def wet_db(freq, **opts)
      out = render(freq.hz.sine.chorus(:juno1, dry: 0, depth: 0, **opts), 0.2)[0][4800..]
      out.abs.max.to_db
    end

    let(:poles) { MB::Sound::GraphNode::Chorus::BBD_PRE_POLES + MB::Sound::GraphNode::Chorus::BBD_POST_POLES }

    it 'follows the Juno-60 filters (Holters and Parker) through the wet path' do
      [500, 2000, 5420, 8000].each do |f|
        expect(wet_db(f, cutoff: 5420)).to be_within(0.5).of(analog_db(poles, f))
      end
      # The bilinear transform cuts more near Nyquist (24 kHz)
      expect(wet_db(12000, cutoff: 5420)).to be_between(analog_db(poles, 12000) - 7, analog_db(poles, 12000))
      expect(wet_db(5420, bbd: true, hiss: -200)).to be_within(0.6).of(-3)
      expect(wet_db(500, bbd: true, hiss: -200)).to be_within(0.1).of(0)
    end

    it 'scales every pole with cutoff:, also as a node' do
      expect(wet_db(2710, cutoff: 2710)).to be_within(0.5).of(analog_db(poles, 2710, 0.5))
      expect(wet_db(2710, cutoff: 2710.constant)).to be_within(0.6).of(analog_db(poles, 2710, 0.5))
      # A node cutoff plays the real pole as a double pole (steeper)
      expect(wet_db(6000, cutoff: 2710.constant)).to be_within(2.5).of(analog_db(poles, 6000, 0.5))
    end
  end

  describe 'shared buffers', :check_shared do
    it 'does not modify an input shared with other branches' do
      sig = 220.hz.ramp
      c = sig.chorus(bbd: true)
      other = sig * 2
      expect {
        20.times do
          c.outputs.each { |o| o.sample(128) }
          other.sample(128)
        end
      }.not_to raise_error
    end

    it 'does not modify a shared stereo input' do
      l = 220.hz.ramp
      r = 330.hz.ramp
      c = MB::Sound.stereo(l, r).chorus(dry: 0.5.constant, wet: 0.7)
      others = [l * 1, r * 1]
      expect {
        20.times do
          c.outputs.each { |o| o.sample(128) }
          others.each { |o| o.sample(128) }
        end
      }.not_to raise_error
    end
  end
end
