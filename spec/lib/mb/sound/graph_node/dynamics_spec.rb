RSpec.describe(MB::Sound::GraphNode::Dynamics, :aggregate_failures) do
  let(:rng) { Random.new(11) }

  def arr(x)
    MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(x)])
  end

  # Samples every output of +node+ in +size+-sample blocks until +total+
  # samples or the end; returns one SFloat per channel.
  def render(node, total, size = 800)
    outs = node.outputs
    data = Array.new(outs.length) { [] }
    done = 0
    while done < total
      bufs = outs.map { |o| o.sample([size, total - done].min) }
      break if bufs.any?(&:nil?)
      bufs.each_with_index { |b, i| data[i] << b.dup }
      done += bufs[0].length
    end
    data.map { |d| d.empty? ? Numo::SFloat[] : Numo::SFloat.cast(d.reduce { |a, b| a.concatenate(b) }) }
  end

  def bursty(n, level: 1.0)
    Numo::SFloat.cast(Array.new(n) { |i| (rng.rand - 0.5) * 2 * level * ((i / 301).even? ? 1 : 0.02) })
  end

  def db(x)
    20 * Math.log10(x.abs)
  end

  # Giannoulis et al.'s soft-knee compressor curve.
  def knee_curve(x, t, r, w)
    x = x.to_f
    r = r.to_f
    if 2 * (x - t) < -w
      x
    elsif 2 * (x - t).abs <= w
      x + (1.0 / r - 1) * (x - t + w / 2.0)**2 / (2 * w)
    else
      t + (x - t) / r
    end
  end

  describe '#compress' do
    it 'follows the soft-knee static curve for steady levels' do
      (-60..6).step(3).each do |level|
        c = 10.0**(level / 20.0)
        node = c.constant.compress(threshold: -20.db, ratio: 4, knee: 10, attack: 0, release: 0)
        out = node.sample(10)
        expect(db(out[-1])).to be_within(1e-4).of(knee_curve(level, -20, 4, 10)), "level #{level}"
      end
    end

    it 'measures slow RMS tones within 0.1 dB of the curve' do
      [-40, -25, -15, -5].each do |level|
        amp = 10.0**(level / 20.0) * Math.sqrt(2)
        node = 50.hz.sine.at(amp).compress(threshold: -20.db, ratio: 3, knee: 6, detector: :rms, rms: 0.2, attack: 0.3, release: 0.3)
        out = render(node, 192000)[0][144000..]
        rms = Math.sqrt((out**2).mean)
        expect(db(rms)).to be_within(0.1).of(knee_curve(level, -20, 3, 6)), "level #{level}"
      end
    end

    it 'gives the same output at any buffer size' do
      x = bursty(4000)
      kick = bursty(4000, level: 0.5)
      ref = nil
      [1, 7, 128, 800, 4000].each do |size|
        node = arr(x).compress(threshold: -30.db, ratio: 5, attack: 2.ms, release: 30.ms, hold: 5.ms, lookahead: 32.samples,
                               sidechain: arr(kick), makeup: :auto, upward_threshold: -50.db)
        out = render(node, 5000, size)[0]
        ref ||= out
        expect(out).to eq(ref), "size #{size}"
      end
      expect(ref.length).to eq(4032)
    end

    it 'attacks and releases with one-pole time constants in dB' do
      x = Numo::SFloat.ones(2400) * 0.01
      x[480...1440] = 1.0
      node = arr(x).compress(threshold: -40.db, ratio: Float::INFINITY, knee: 0, attack: 0.001, release: 0.01)
      out = render(node, 2400)[0]
      gain = ->(i) { db(out[i] / x[i]) }
      # 40 dB of reduction wanted; 1 - 1/e of it after 48 samples
      expect(gain.(480 + 47)).to be_within(0.05).of(-40 * (1 - Math.exp(-48 / 48.0)))
      expect(gain.(1439)).to be_within(1e-6).of(-40)
      expect(gain.(1440 + 479)).to be_within(0.05).of(-40 * Math.exp(-480 / 480.0))
    end

    it 'holds the reduction before releasing' do
      x = Numo::SFloat.ones(2000) * 0.01
      x[0...500] = 1.0
      node = arr(x).compress(threshold: -40.db, ratio: Float::INFINITY, knee: 0, attack: 0, release: 0.001, hold: 100.samples)
      out = render(node, 2000)[0]
      expect(db(out[599] / x[599])).to be_within(1e-6).of(-40)
      expect(db(out[800] / x[800])).to be > -1
    end

    it 'delays the audio by the lookahead and flushes it after the input ends' do
      x = bursty(1000, level: 0.01)
      node = arr(x).compress(threshold: -20.db, ratio: 4, lookahead: 25.samples)
      out = render(node, 2000, 128)[0]
      expect(out.length).to eq(1025)
      expect(out[25..]).to eq(x)
    end

    it 'links stereo channels by default and not with link: false' do
      st = MB::Sound.stereo(1.constant, 0.01.constant)
      linked = render(st.compress(threshold: -20.db, ratio: Float::INFINITY, knee: 0, attack: 0, release: 0), 10)
      apart = render(st.compress(threshold: -20.db, ratio: Float::INFINITY, knee: 0, attack: 0, release: 0, link: false), 10)
      expect(db(linked[0][-1])).to be_within(1e-4).of(-20)
      expect(db(linked[1][-1])).to be_within(1e-4).of(-60)
      expect(db(apart[1][-1])).to be_within(1e-4).of(-40)
    end

    it 'lifts quiet levels with upward compression, up to max_gain' do
      node = ->(level) { (10.0**(level / 20.0)).constant.compress(threshold: -10.db, ratio: 2, knee: 0, upward_threshold: -40.db, upward_ratio: 2, max_gain: 12.db, attack: 0, release: 0) }
      expect(db(node.(-50).sample(4)[-1])).to be_within(1e-4).of(-45)
      expect(db(node.(-80).sample(4)[-1])).to be_within(1e-4).of(-68)
      expect(db(node.(-20).sample(4)[-1])).to be_within(1e-4).of(-20)
    end

    it 'rejects ratios below 1 and bad thresholds' do
      expect { 1.constant.compress(ratio: 0.5) }.to raise_error(ArgumentError, /ratio/)
      expect { 1.constant.compress(threshold: :loud) }.to raise_error(ArgumentError, /threshold/)
      expect { 1.constant.compress(upward_threshold: -10.db, threshold: -20.db) }.to raise_error(ArgumentError, /below/)
    end

    it 'reads bare thresholds as linear gains' do
      a = 0.5.constant.compress(threshold: -20.db, attack: 0, release: 0).sample(4)
      b = 0.5.constant.compress(threshold: 0.1, attack: 0, release: 0).sample(4)
      expect(a).to eq(b)
      expect { 0.5.constant.compress(threshold: -20) }.to raise_error(ArgumentError, /threshold: -20 is a linear gain.*write -20\.db/)
    end

    it 'adds :auto makeup of half the gain change at 0 dBFS' do
      node = 1.constant.compress(threshold: -20.db, ratio: 3, knee: 0, makeup: :auto, attack: 0, release: 0)
      expect(db(node.sample(4)[-1])).to be_within(1e-4).of(-20 + 20 / 3.0 + (20 - 20 / 3.0) / 2)
    end
  end

  describe 'levels' do
    let(:sig) { 0.5.constant }

    # A fresh call site each time, so the once-per-site warnings show
    def fresh_site(code)
      eval(code, binding, "level_site_#{rand(1 << 30)}.rb", 1) # rubocop:disable Security/Eval
    end

    it 'reads Decibels exactly as dB, without warnings' do
      expect {
        sig.compress(threshold: -20.db, upward_threshold: -40.db)
        sig.expand(threshold: -45.db, range: -30.db)
        sig.noise_gate(threshold: -30.db)
        sig.duck(1.constant, amount: -10.db, threshold: -30.db)
        sig.limit(ceiling: -1.db)
        sig.squeeze(:eleven)
        sig.compress
        sig.limit
      }.not_to output.to_stderr
      expect(MB::Sound::GraphNode::DynamicsMethods.level_db(-20.db, 'threshold')).to eq(-20.0)
      expect(MB::Sound::GraphNode::DynamicsMethods.level(-1.db, 'ceiling')).to eq((-1).db.to_f)
    end

    it 'rejects bare negative numbers, which are linear gains' do
      expect { sig.compress(threshold: -20) }.to raise_error(ArgumentError, /threshold: -20 is a linear gain, and gains can't be negative; for -20 dB write -20\.db/)
      expect { sig.compress(threshold: -20.db, upward_threshold: -40) }.to raise_error(ArgumentError, /upward_threshold: -40/)
      expect { sig.limit(ceiling: -1) }.to raise_error(ArgumentError, /ceiling: -1 is a linear gain/)
      expect { sig.duck(1.constant, amount: -10) }.to raise_error(ArgumentError, /amount: -10/)
      expect { sig.noise_gate(threshold: -30.db, range: -60) }.to raise_error(ArgumentError, /range: -60/)
      expect { sig.compress(makeup: -3) }.to raise_error(ArgumentError, /makeup: -3 .*write -3\.db/)
      expect { sig.compand(-60 => -80, 0 => -12) }.to raise_error(ArgumentError, /compand point input: -60/)
      expect { sig.compand(-60.db => -80.db, 0.db => 0.db, min_gain: -20) }.to raise_error(ArgumentError, /min_gain: -20/)
      expect { sig.squeeze(gain: -3) }.to raise_error(ArgumentError, /gain: -3/)
    end

    it 'rejects a bare 0 where -inf dB means nothing, and takes it as a full cut' do
      expect { sig.compress(threshold: 0) }.to raise_error(ArgumentError, /threshold: 0 is a linear gain of zero \(-inf dB\); for 0 dB write 0\.db/)
      expect { sig.compress(makeup: 0) }.to raise_error(ArgumentError, /makeup: 0/)
      expect { sig.limit(ceiling: 0) }.to raise_error(ArgumentError, /ceiling: 0/)
      expect { sig.compand(0 => 0.5) }.to raise_error(ArgumentError, /compand point input: 0/)

      gate = render(sig.noise_gate(threshold: 0.9, range: 0, ratio: 1000, knee: 0, attack: 0, release: 0, hold: 0), 4)[0]
      expect(gate[-1]).to eq(0)
      ducked = sig.duck(1.constant, amount: 0, threshold: -30.db, knee: 0, attack: 0, hold: 0).sample(4)
      expect(db(ducked[-1] / 0.5)).to be_within(1e-3).of(-30) # unlimited by amount: 1 dB per dB above -30 dB
    end

    it 'reads bare negative numbers as dB in live mode, with a warning (and 0 as 0 dB)' do
      MB::Sound.live = true
      a = b = nil
      expect { a = fresh_site('2.times.map { sig.compress(threshold: -20, makeup: -1, attack: 0, release: 0) }.last').sample(4) }.to output(
        /\Alevel_site_\d+\.rb:1: warning: threshold: -20 is read as -20 dB in live mode; write -20\.db \(bare numbers are linear gains\)\n.*makeup: -1 is read as -1 dB in live mode.*\n\z/
      ).to_stderr
      expect(a).to eq(sig.compress(threshold: -20.db, makeup: -1.db, attack: 0, release: 0).sample(4))
      expect { b = fresh_site('sig.compress(threshold: -20.db, makeup: 0, attack: 0, release: 0)').sample(4) }.to output(/makeup: 0 is a linear gain of zero.*live mode: ignored/).to_stderr
      expect(b).to eq(sig.compress(threshold: -20.db, makeup: 0.db, attack: 0, release: 0).sample(4))
      expect { fresh_site('sig.compand(-60 => -80, 0 => -12)') }.to output(/compand point input: -60 is read as -60 dB/).to_stderr
    ensure
      MB::Sound.live = false
    end

    it 'warns about linear levels above full scale' do
      expect { fresh_site('2.times { sig.compress(threshold: 6) }') }.to output(/\Alevel_site_\d+\.rb:1: warning: threshold: 6 is a linear gain of 15\.6 dB, above full scale; did you mean -6\.db\?\n\z/).to_stderr
      expect { fresh_site("sig.limit(ceiling: 2)\nsig.limit(ceiling: 2)") }.to output(/:1: warning.*\n.*:2: warning/).to_stderr
      expect { fresh_site('sig.compress(threshold: 0.1)') }.not_to output.to_stderr
      expect(MB::Sound::GraphNode::DynamicsMethods.level_db(0.1, 'threshold')).to eq(-20.0)
    end

    it 'reads Decibels makeup, gains, and compander points as dB, and bare numbers as linear gains' do
      a = sig.compress(threshold: -20.db, makeup: 6.db, attack: 0, release: 0).sample(4)[-1]
      b = sig.compress(threshold: -20.db, makeup: 2, attack: 0, release: 0).sample(4)[-1]
      expect(db(a / b)).to be_within(1e-4).of(6 - 20 * Math.log10(2))

      c = sig.compand(-60.db => -80.db, 0.db => -12.db, attack: 0, release: 0).sample(4)
      d = sig.compand(0.001 => 0.0001, 1 => 0.251188643150958, attack: 0, release: 0).sample(4)
      expect(c[-1]).to be_within(1e-6).of(d[-1])

      e = sig.squeeze(gain: 3.db, max_gain: 12.db).sample(800)
      f = sig.squeeze(gain: 3.db.to_f, max_gain: 12.db.to_f).sample(800)
      expect(e).to eq(f)

      g = sig.compand(-40.db => -40.db, 0.db => -40.db, min_gain: -6.db, attack: 0, release: 0).sample(4)[-1]
      h = sig.compand(-40.db => -40.db, 0.db => -40.db, min_gain: 0.5, attack: 0, release: 0).sample(4)[-1]
      expect(db(g / 0.5)).to be_within(1e-4).of(-6)
      expect(db(h / 0.5)).to be_within(1e-4).of(20 * Math.log10(0.5))
    end

    it 'loads graph documents before format 3 in their old meaning, with a warning' do
      old = <<~DOC
        graph 2, name: "old"
        0.5.constant.compress(threshold: -20, makeup: 3, attack: 0, release: 0).compand({ -60 => -80, 0 => -12 }, min_gain: -Float::INFINITY, max_gain: 6).limit(ceiling: -1).duck(1.constant, amount: 0)
      DOC
      g = nil
      expect { g = MB::Sound::GraphIO.load(old) }.to output(/format 2 document: bare dB values .* read as dB.*\n\z/).to_stderr
      expected = sig.compress(threshold: -20.db, makeup: 3.db, attack: 0, release: 0).compand({ -60.db => -80.db, 0.db => -12.db }, max_gain: 6.db).limit(ceiling: -1.db).duck(1.constant, amount: 0.db)
      expect(g.sample(800)).to eq(expected.sample(800))
      expect(g.to_ruby).to include('compress(threshold: -20.db, makeup: 3.db', 'compand({ -60.db => -80.db, 0.db => -12.db }, max_gain: 6.db)', 'limit(ceiling: -1.db)', 'amount: 0.db')

      # Format 2 positive levels were linear gains already; Decibels load as they are
      expect { g = MB::Sound::GraphIO.load(%(graph 2\n0.5.constant.compress(threshold: 0.1, makeup: 3.db))) }.not_to output.to_stderr
      expect(g.sample(4)).to eq(sig.compress(threshold: 0.1, makeup: 3.db).sample(4))

      # Format 3 reads bare numbers as linear gains
      expect { MB::Sound::GraphIO.load(%(graph 3\n0.5.constant.compress(threshold: -20))) }.to raise_error(MB::Sound::GraphIO::LoadError, /:2: .*threshold: -20 is a linear gain/)
      g = MB::Sound::GraphIO.load(%(graph 3\n0.5.constant.compress(threshold: 0.1, makeup: 2)))
      expect(g.sample(4)).to eq(sig.compress(threshold: 0.1, makeup: 2).sample(4))
    end

    it 'prints Decibels levels back as k.db' do
      expect(sig.compress(threshold: -18.db, makeup: 2.db).to_ruby).to eq('0.5.constant.compress(threshold: -18.db, makeup: 2.db)')

      g = sig.compress(threshold: 0.125, makeup: 2).limit(ceiling: -0.5.db)
      code = g.to_ruby
      expect(code).to eq('0.5.constant.compress(threshold: 0.125, makeup: 2).limit(ceiling: -0.5.db)')
      h = nil
      expect { h = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(g, name: 'levels')) }.not_to output.to_stderr
      expect(h.sample(800)).to eq(g.sample(800))
    end
  end

  describe '#duck' do
    it 'ducks by the amount while the sidechain is loud, then releases' do
      kick = Numo::SFloat.zeros(96000)
      kick[0...2400] = 1.0
      node = 0.5.constant.duck(arr(kick), amount: -12.db, threshold: -30.db, attack: 0, release: 0.05, hold: 0, knee: 0)
      out = render(node, 96000)[0]
      expect(db(out[2000] / 0.5)).to be_within(1e-4).of(-12)
      expect(db(out[2400 + 2399] / 0.5)).to be_within(0.01).of(-12 * Math.exp(-1))
      expect(db(out[95999] / 0.5)).to be > -0.001
    end

    it 'defaults to a deep pump: -18 dB, held 20 ms, released over a 1/16 note' do
      MB::Sound.bpm(120)
      kick = Numo::SFloat.zeros(96000)
      kick[0...2400] = 1.0
      out = render(0.5.constant.duck(arr(kick), knee: 0), 96000)[0]
      expect(db(out[2000] / 0.5)).to be_within(1e-3).of(-18)
      expect(db(out[2400 + 900] / 0.5)).to be_within(1e-3).of(-18) # held for 20 ms
      t = 2400 + 960 + 6000 # one 1/16 (0.125 s) into the release
      expect(db(out[t] / 0.5)).to be_within(0.2).of(-18 * Math.exp(-1))
      expect(db(out[95999] / 0.5)).to be > -0.01
    end

    it 'needs a sidechain, and ducks by the magnitude of any dB amount (never boosts)' do
      expect { 1.constant.duck(nil) }.to raise_error(ArgumentError, /sidechain/)
      expect { 1.constant.duck(1.constant, amount: 6) }.to raise_error(ArgumentError, /amount: 6 is a linear gain above 1.*write -6\.db/)
      expect { 1.constant.duck(1.constant, amount: -6) }.to raise_error(ArgumentError, /amount: -6 is a linear gain/)

      kick = Numo::SFloat.ones(4800)
      d = ->(amount) { render(0.5.constant.duck(arr(kick), amount: amount, threshold: -30.db, attack: 0, hold: 0, knee: 0), 4800)[0][4000] }
      expect(d.(12.db)).to eq(d.(-12.db))
      expect(db(d.(-12.db) / 0.5)).to be_within(1e-4).of(-12)
      expect(db(d.(0.25) / 0.5)).to be_within(1e-3).of(20 * Math.log10(0.25))
    end
  end

  describe '#expand and #noise_gate' do
    it 'expands below the threshold down to the range' do
      g = ->(level, **o) { db((10.0**(level / 20.0)).constant.expand(threshold: -40.db, ratio: 3, knee: 0, attack: 0, release: 0, **o).sample(4)[-1]) }
      expect(g.(-30)).to be_within(1e-4).of(-30)
      expect(g.(-50)).to be_within(1e-4).of(-70)
      expect(g.(-70)).to be_within(1e-4).of(-110)
      expect(g.(-90, range: -60.db)).to be_within(1e-4).of(-150)
    end

    it 'gates, holding open after the level falls' do
      x = Numo::SFloat.ones(3000) * 0.001
      x[0...1000] = 0.5
      out = render(arr(x).noise_gate(threshold: -40.db, hold: 200.samples, release: 0, attack: 0), 3000)[0]
      expect(out[1100]).to eq(x[1100])
      expect(db(out[1300] / x[1300])).to be_within(1e-3).of(-80)
    end
  end

  describe '#compand' do
    it 'follows linear points for steady levels and continues the end slopes' do
      [[-70, -100], [-60, -80], [-50, -60], [-40, -40], [-10, -18], [0, -15], [10, -12]].each do |level, expected|
        node = (10.0**(level / 20.0)).constant.compand(-60.db => -80.db, -40.db => -40.db, -10.db => -18.db, 0.db => -15.db, attack: 0, release: 0)
        expect(db(node.sample(4)[-1])).to be_within(1e-3).of(expected), "level #{level}"
      end
    end

    it 'measures slow RMS tones within 0.1 dB of a cubic curve at its points' do
      pts = { -60 => -70, -30 => -30, 0 => -10 }
      pts.each do |level, expected|
        amp = 10.0**(level / 20.0) * Math.sqrt(2)
        node = 40.hz.sine.at(amp).compand(pts.to_h { |a, b| [a.db, b.db] }, interpolation: :cubic, detector: :rms, rms: 0.25, attack: 0.3, release: 0.3)
        out = render(node, 192000)[0][144000..]
        expect(db(Math.sqrt((out**2).mean))).to be_within(0.1).of(expected), "level #{level}"
      end
    end

    it 'takes per-segment shapes, a block, or a Transfer' do
      a = 0.1.constant.compand([[-60.db, -80.db], [-40.db, -40.db, :smooth], [0.db, -12.db]], attack: 0, release: 0).sample(4)[-1]
      b = 0.1.constant.compand(attack: 0, release: 0) { |d| d < -50 ? d * 1.5 + 25 : d }.sample(4)[-1]
      t = MB::Sound::GraphNode::Dynamics::Transfer.points({ -40 => -40, 0 => -20 })
      c = 0.1.constant.compand(t, attack: 0, release: 0).sample(4)[-1]
      expect(db(a)).to be_between(-40, -12)
      expect(db(b)).to be_within(1e-3).of(-20)
      expect(db(c)).to be_within(1e-3).of(-30)
    end

    it 'rejects decreasing outputs, unknown options, and mixed forms' do
      expect { 1.constant.compand(-40.db => -40.db, -20.db => -50.db) }.to raise_error(ArgumentError, /decrease/)
      expect { 1.constant.compand(-40.db => -40.db, 0.db => 0.db, bogus: 1) }.to raise_error(ArgumentError, /bogus/)
      expect { 1.constant.compand(-40.db => -40.db, 0.db => 0.db) { |d| d } }.to raise_error(ArgumentError, /both/)
      expect { 1.constant.compand([[-40.db, -40.db, :bounce], [0.db, 0.db]]) }.to raise_error(ArgumentError, /monotonic/)
    end
  end

  describe MB::Sound::GraphNode::Dynamics::Transfer do
    it 'has continuous values and slopes at knee edges' do
      t = described_class.corners(-40, [[-40, 3.0, 1.0], [-20, 1.0, 0.2]], knee: 8)
      [-44, -36, -24, -16].each do |x|
        e = 1e-7
        expect(t.(x + e)).to be_within(1e-6).of(t.(x - e))
        s1 = (t.(x - e) - t.(x - 2 * e)) / e
        s2 = (t.(x + 2 * e) - t.(x + e)) / e
        expect(s2).to be_within(1e-3).of(s1)
      end
    end

    it 'makes monotone cubics through random monotone points' do
      r = Random.new(5)
      20.times do
        xs = Array.new(6) { r.rand(-100.0..10.0) }.sort.uniq
        ys = xs.map { r.rand * 30 }.sort.map { |v| v - 80 }
        ys[2] = ys[1] if r.rand < 0.5 # flat stretches stay flat
        t = described_class.points(xs.zip(ys), interpolation: :cubic)
        xs.zip(ys).each { |x, y| expect(t.(x)).to be_within(1e-9).of(y) }
        samples = Numo::DFloat.linspace(xs[0] - 10, xs[-1] + 10, 2000).to_a.map { |x| t.(x) }
        expect(samples.each_cons(2).all? { |a, b| b >= a - 1e-9 }).to eq(true)
      end
    end

    it 'mixes per-segment cubic and linear shapes' do
      t = described_class.points([[-60, -80], [-40, -40, :cubic], [-20, -25], [0, -15]])
      expect(t.(-50)).to be_within(1e-9).of(-60)
      expect(t.(-40)).to eq(-40)
      expect(t.(-20)).to be_within(1e-9).of(-25)
      expect(t.(-10)).to be_within(1e-9).of(-20)
    end
  end

  describe '#limit' do
    it 'keeps sample and true peaks under the ceiling' do
      x = bursty(48000, level: 4)
      out = render(arr(x).limit(ceiling: -1.db, release: 50.ms), 60000)[0]
      expect(out.length).to eq(48000 + 72 + 6)
      expect(out.abs.max).to be <= -1.db + 1e-7
      tp = MB::Sound::Loudness::TruePeak.new.process(out).peak
      expect(db(tp)).to be <= -1 + 0.1
    end

    it 'delays by the lookahead (plus 6 samples with true peak) and leaves quiet signals alone' do
      x = bursty(1000, level: 0.1)
      a = render(arr(x).limit(lookahead: 10.samples, true_peak: false), 2000)[0]
      b = render(arr(x).limit(lookahead: 10.samples), 2000)[0]
      expect(a[10...1010]).to eq(x)
      expect(b[16...1016]).to eq(x)
      expect(arr(x).limit.original_source.latency).to eq(78)
    end

    it 'gives the same output at any buffer size and links stereo' do
      l = bursty(3000, level: 3)
      r = bursty(3000, level: 0.2)
      ref = nil
      [1, 13, 800].each do |size|
        out = render(MB::Sound.stereo(arr(l), arr(r)).limit(ceiling: -3.db), 4000, size)
        ref ||= out
        expect(out).to eq(ref)
      end
      quiet = Numo::SFloat.cast(r)
      gains = ref[1][78...3078] / quiet
      expect(gains.min).to be < 0.5
    end
  end

  describe 'in a master chain' do
    let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
    let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
    let(:session) { MB::Sound::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true) }

    after { session.close }

    def run(frames)
      Array.new(frames / 800) { session.process_buffer.map(&:dup) }.transpose.map { |c| c.reduce(:concatenate) }
    end

    it 'limits the mix with the latency of the lookahead plus the true-peak delay' do
      x = Numo::SFloat.zeros(4800)
      x[1000] = 4.0
      x[3000] = 0.1
      session.master { |mix| mix.limit(ceiling: -6.db, release: 10.ms) }
      session.add([arr(x), 220.hz.sine.at(3)])
      l, r = run(9600)
      expect(l.abs.max).to be <= -6.db + 1e-6
      expect(r.abs.max).to be <= -6.db + 1e-6
      expect(l.abs.max_index).to eq(1078)
    end

    it 'ducks the mix from a sidechain node' do
      kick = Numo::SFloat.zeros(9600)
      kick[0...800] = 1
      session.master { |mix| mix.duck(arr(kick), amount: -20.db, attack: 0, release: 0.001, knee: 0) }
      session.add([0.5.constant, 0.5.constant])
      l, _r = run(9600)
      expect(db(l[400] / 0.5)).to be_within(1e-4).of(-20)
      expect(db(l[9000] / 0.5)).to be > -0.001
    end
  end

  describe '#bands' do
    # The DFT of +x+ at bin +k+.
    def dft(x, k)
      n = Numo::DFloat.new(x.length).seq
      w = -2 * Math::PI * k / x.length
      xd = Numo::DFloat.cast(x)
      Complex((xd * Numo::DFloat::Math.cos(n * w)).sum, (xd * Numo::DFloat::Math.sin(n * w)).sum)
    end

    def impulse_sum(order, freqs)
      x = Numo::SFloat.zeros(16384)
      x[0] = 1
      node = arr(x).bands(*freqs, order: order) { |*bs| bs }
      render(node, 16384)[0]
    end

    # The allpass cascade the bands should sum to, at bilinear frequency w.
    def allpass(order, freqs, w, rate = 48000)
      freqs.reduce(Complex(1, 0)) { |acc, f|
        g = Math.tan(Math::PI * f / rate)
        z = Complex.polar(1, w)
        s = (z - 1) / (z + 1) / g
        h = case order
            when 2 then (1 - s) / (1 + s)
            when 4 then (s * s - Math.sqrt(2) * s + 1) / (s * s + Math.sqrt(2) * s + 1)
            else
              [2 * Math.cos(Math::PI / 8), 2 * Math.cos(3 * Math::PI / 8)].reduce(1) { |a, k| a * (s * s - k * s + 1) / (s * s + k * s + 1) }
            end
        acc * h
      }
    end

    [2, 4, 8].each do |order|
      it "sums LR#{order} bands to a flat allpass with the expected phase" do
        freqs = [150, 1200, 9000]
        x = impulse_sum(order, freqs)
        [10, 100, 500, 1000, 3000].each do |bin|
          w = 2 * Math::PI * bin / 16384.0
          h = dft(x, bin)
          expect(h.abs).to be_within(1e-5).of(1)
          expect((h - allpass(order, freqs, w)).abs).to be < 1e-5, "bin #{bin}"
        end
      end
    end

    it 'separates bands by frequency' do
      lo, hi = 50.hz.sine.bands(1000)
      a, b = render(MB::Sound.channels(lo, hi), 4800).map { |d| d[2400..].abs.max } # bands sampled in turn
      expect(a).to be > 0.99
      expect(b).to be < 0.01
    end

    it 'runs any node per band on stereo bundles and sums them' do
      st = MB::Sound.stereo(100.hz.sine, 5000.hz.sine)
      out = st.bands(1000) { |lo, hi| [lo, hi * 0] }
      expect(out).to be_a(MB::Sound::GraphNode::Channels)
      l, r = render(out, 9600)
      expect(l[4800..].abs.max).to be > 0.9
      expect(r[4800..].abs.max).to be < 0.01
    end
  end

  describe '#mono_below' do
    it 'makes the lows mono and leaves the highs' do
      low = MB::Sound.stereo(40.hz.sine, 40.hz.sine.with_phase(0.5)) # all side
      l, r = render(low.mono_below(120), 48000)
      expect(db(((l - r) / 2)[24000..].abs.max)).to be < -30
      high = MB::Sound.stereo(2000.hz.sine, 2000.hz.sine.with_phase(0.5))
      l, r = render(high.mono_below(120), 48000)
      expect(db(((l - r) / 2)[24000..].abs.max)).to be_within(0.1).of(0)
    end

    it 'returns one-channel nodes unchanged and prints itself' do
      s = 100.hz.sine
      expect(s.mono_below(120)).to equal(s)
      expect(MB::Sound.stereo(100.hz.sine, 101.hz.sine).mono_below(120).to_ruby).to end_with('.mono_below(120)')
    end
  end

  describe '#squeeze' do
    it 'rejects unknown presets and bad knobs' do
      expect { 1.constant.squeeze(:twelve) }.to raise_error(ArgumentError, /preset/)
      expect { 1.constant.squeeze(depth: 2) }.to raise_error(ArgumentError, /depth/)
      expect { 1.constant.squeeze(split: [100]) }.to raise_error(ArgumentError, /two/)
    end

    it 'lifts quiet sounds more at :eleven' do
      level = ->(node) { v = render(node, 48000)[0][24000..]; db(Math.sqrt((v**2).mean)) }
      gentle = level.(1000.hz.sine.at(-60.db).squeeze)
      eleven = level.(1000.hz.sine.at(-60.db).squeeze(:eleven))
      expect(gentle).to be > -63 + 6
      expect(eleven).to be > gentle + 6
    end

    it 'processes a stereo bundle with finite output' do
      st = MB::Sound.stereo(arr(bursty(9600, level: 0.5)), arr(bursty(9600, level: 0.05)))
      l, r = render(st.squeeze(:eleven, depth: 0.7, time: 0.5), 9600)
      expect(l.length).to eq(9600)
      expect(l.isfinite.all? && r.isfinite.all?).to eq(true)
      expect(l.abs.max).to be > 0
    end
  end
end
