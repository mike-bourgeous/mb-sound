RSpec.describe(MB::Sound::Filter::FourPole, 'mode: :diode') do
  fp = MB::Sound::Filter::FourPole
  ff = MB::Sound::FastFilter

  def diode(**opts)
    MB::Sound::Filter::FourPole.new(mode: :diode, **opts)
  end

  # Magnitude response in dB from a long impulse response (0.73 Hz bins)
  def measured_db(filter, n: 65536)
    imp = Numo::SFloat.zeros(n)
    imp[0] = 1
    filter.reset(0)
    mag = Numo::Pocketfft.rfft(Numo::DFloat.cast(filter.process(imp))).abs
    ->(hz) { 20 * Math.log10(mag[(hz * n / 48000.0).round]) }
  end

  def analytic_db(filter, hz)
    20 * Math.log10(filter.response(2 * Math::PI * hz / filter.sample_rate).abs)
  end

  describe 'C and Ruby versions' do
    let(:noise) { MB::Sound.with_seed(3) { Numo::SFloat.cast(MB::Sound.noise.sample(4801)) } }
    let(:cutoffs) { Numo::DFloat.new(4801).seq.map { |i| 25000 * Math.sin(i * 0.003)**2 - 300 } }
    let(:resonances) { Numo::SFloat.new(4801).seq.map { |i| 1.3 * Math.sin(i * 0.0021)**2 - 0.1 } }

    [[0, 0, 0, 0.0], [1, 0, 0, 0.0], [1, 0, 0, 2.5], [0, 2, 0, 2.5], [1, 2, 1, 2.5], [2, 0, 0, 1.0], [3, 0, 0, 1.0], [3, 2, 1, 2.0]].each do |curve, drive_mode, clip, drive|
      it "give identical samples with curve #{curve}, drive mode #{drive_mode}, clip #{clip}, drive #{drive}" do
        s1 = [0.0] * 4
        s2 = [0.0] * 4
        loud = noise * 4
        k_max = curve >= 2 ? 5.0 : 3.9
        [0...800, 800...801, 801...2400, 2400...4801].each do |r|
          c = ff.diode_ladder(loud[r].dup, cutoffs[r], resonances[r], s1, 48000, k_max, 0.375, drive, curve, drive_mode, clip)
          ruby = fp.diode_process_ruby(loud[r].dup, cutoffs[r], resonances[r], s2, 48000, k_max, 0.375, drive, curve, drive_mode, clip)
          expect(c).to eq(ruby)
          expect(s1).to eq(s2)
        end
        expect(s1.all?(&:finite?)).to eq(true)
      end
    end

    it 'give identical samples for constant parameters and odd values' do
      [[1000, 0.5], [0.0, 1.0], [Float::NAN, Float::NAN], [-5, -1], [1e9, 2]].each do |c, r|
        s1 = [0.3, -0.1, 0.0, 0.2]
        s2 = s1.dup
        a = ff.diode_ladder(noise.dup, c, r, s1, 44100, 3.9, 0.375, 1.0, 1)
        b = fp.diode_process_ruby(noise.dup, c, r, s2, 44100, 3.9, 0.375, 1.0, 1)
        expect(a).to eq(b)
        expect(s1).to eq(s2)
      end
    end

    it 'use the same curves' do
      Numo::DFloat.linspace(-0.1, 1.1, 121).to_a.each do |r|
        expect(ff.diode_resonance_curve(r)).to eq(fp.diode_resonance_curve(r))
        [0, 1, 2, 3].each do |curve|
          rc = r.clamp(0.0, 1.0)
          expect(ff.diode_loop_gain(rc, curve, curve >= 2 ? 5.0 : 3.9)).to eq(fp.diode_loop_gain(rc, curve, curve >= 2 ? 5.0 : 3.9))
        end
      end
    end

    it 'filter an inplace SFloat in place' do
      buf = noise.dup.inplace!
      out = ff.diode_ladder(buf, 1000, 0.5, [0.0] * 4, 48000, 3.9, 0.375, 0.0)
      expect(out).to equal(buf)
    end

    it 'raise for bad arguments' do
      expect { ff.diode_ladder(noise.dup, 1000, 0.5, [0.0] * 3, 48000, 3.9, 0.375, 0.0) }.to raise_error(ArgumentError, /four elements/)
      expect { ff.diode_ladder(noise.dup, 1000, 0.5, [0.0] * 4, 48000, 3.9, 0.375, 1.0, 1, 1) }.to raise_error(ArgumentError, /drive mode/)
      expect { ff.diode_ladder(noise.dup, 1000, 0.5, [0.0] * 4, 0, 3.9, 0.375, 0.0) }.to raise_error(ArgumentError, /Sample rate/)
      expect { ff.diode_ladder(noise.dup, 1000, 0.5, [0.0] * 4, 48000, 3.9, 0.375, -1.0) }.to raise_error(ArgumentError, /finite/)
      expect { ff.diode_ladder(noise.dup, 1000, 0.5, [0.0] * 4, 48000, 3.9, 0.375, 0.0, 4) }.to raise_error(ArgumentError, /curve/)
      expect { ff.diode_ladder(noise.dup, Numo::SFloat.zeros(3), 0.5, [0.0] * 4, 48000, 3.9, 0.375, 0.0) }.to raise_error(ArgumentError, /length/)
    end

    it 'flushes tiny states to zero' do
      st = [1e-35, -1e-35, 0.0, 1e-31]
      ff.diode_ladder(Numo::SFloat.zeros(1), 1000, 0, st, 48000, 3.9, 0.375, 0.0)
      expect(st).to eq([0.0] * 4)
    end

    it 'gives identical samples through #dynamic_process_ruby' do
      f1 = diode(cutoff: 500, resonance: 0.8, drive: 2)
      f2 = diode(cutoff: 500, resonance: 0.8, drive: 2)
      expect(f1.dynamic_process(noise, cutoff: cutoffs, resonance: 0.7)).to eq(f2.dynamic_process_ruby(noise, cutoff: cutoffs, resonance: 0.7))
      expect(f1.state).to eq(f2.state)
    end
  end

  describe 'model constants' do
    it 'oscillate where the open loop 1 / D(s) reaches -180 degrees, at loop gain 901/49' do
      w = 1 / fp::DIODE_INV_W180
      d = ->(s) { (((s + 7) * s + 15) * s + 10) * s + 1 }
      v = d.(Complex(0, w))
      expect(v.imag.abs).to be < 1e-12
      expect(-v.real).to be_within(1e-12).of(fp::DIODE_EDGE_K)
      expect(fp::DIODE_SCALE).to be_within(1e-15).of(fp::DIODE_EDGE_K / 4)
      expect(fp::DIODE_CURVE_K).to be_within(1e-12).of(0.975 * fp::DIODE_EDGE_K)
      expect(2**fp::DIODE_CURVE_LOG2_RATIO).to be_within(1e-9).of(40 + 39 * fp::DIODE_EDGE_K)
    end
  end

  describe 'response' do
    it 'matches the analytic response' do
      [0, 0.5, 0.9].each do |r|
        f = diode(cutoff: 1000, resonance: r)
        m = measured_db(f)
        [20, 300, 1000, 3000, 10000].each do |hz|
          hz = (hz * 65536 / 48000.0).round * 48000 / 65536.0 # on a bin
          expect(m.(hz)).to be_within(0.05).of(analytic_db(f, hz)), "#{hz} Hz at r #{r}"
        end
      end
    end

    it 'is -25.3 dB at the cutoff without resonance, with slopes of about 14, 18, and 22 dB/octave' do
      f = diode(cutoff: 1000, resonance: 0)
      expect(analytic_db(f, 1000)).to be_within(0.05).of(20 * Math.log10(49 / 901.0))
      expect(analytic_db(f, 1)).to be_within(0.01).of(0)
      f = diode(cutoff: 300, resonance: 0)
      slopes = [300, 600, 1200].map { |hz| analytic_db(f, hz) - analytic_db(f, 2 * hz) }
      expect(slopes[0]).to be_within(1.0).of(14)
      expect(slopes[1]).to be_within(1.0).of(18)
      expect(slopes[2]).to be_within(1.0).of(22)
    end

    it 'makes the gain at the cutoff linear in dB from -25.3 to +32.3 dB on the :db curve' do
      gains = [0, 0.25, 0.5, 0.75, 1].map { |r|
        f = diode(cutoff: 1000, resonance: r)
        analytic_db(f, 1000) - analytic_db(f, 0.01)
      }
      expect(gains[0]).to be_within(0.01).of(-25.29)
      expect(gains[-1]).to be_within(0.01).of(32.29)
      gains.each_cons(2) { |a, b| expect(b - a).to be_within(0.01).of(14.395) }
    end

    it 'peaks at the cutoff at high resonance, losing about 8 dB of bass' do
      f = diode(cutoff: 2000, resonance: 0.95)
      m = measured_db(f)
      peak = (1500..2500).step(5).max_by { |hz| m.(hz) }
      expect(peak).to be_within(30).of(2000)
      expect(m.(10)).to be_within(0.2).of(20 * Math.log10((1 + 0.375 * f.loop_gain) / (1 + f.loop_gain)))
      expect(m.(10)).to be_within(1).of(-7.6)
    end

    it 'loses more bass with compensation: 0' do
      f = diode(cutoff: 2000, resonance: 1, compensation: 0)
      expect(analytic_db(f, 1)).to be_within(0.05).of(20 * Math.log10(1 / (1 + fp::DIODE_CURVE_K)))
      expect(analytic_db(f, 1)).to be_within(0.1).of(-25.5)
    end
  end

  describe 'resonance' do
    def ring(filter, seconds)
      buf = Numo::SFloat.zeros((seconds * 48000).round)
      buf[0] = 1
      filter.process(buf)
    end

    it 'shares lp4 knob positions relative to the oscillation edge' do
      [0.3, 0.6, 0.9, 1.0].each do |r|
        lp4 = fp.new(resonance: r, resonance_curve: :linear)
        d = diode(resonance: r, resonance_curve: :linear)
        expect(d.loop_gain / fp::DIODE_EDGE_K).to be_within(1e-12).of(lp4.loop_gain / 4)
      end
      [0.5, 0.9, 0.95, 1.0].each do |r|
        lp4 = fp.new(resonance: r, self_oscillate: true)
        d = diode(resonance: r, self_oscillate: true)
        expect(d.loop_gain / fp::DIODE_EDGE_K).to be_within(1e-12).of(lp4.loop_gain / 4) if r > 0.9
        expect(d.loop_gain).to eq(fp::DIODE_EDGE_K) if r == 0.9
      end
    end

    it 'does not self-oscillate by default' do
      out = ring(diode(cutoff: 1000, resonance: 1), 2)
      expect(out[-4800..].abs.max).to be < 1e-6
      out = ring(diode(cutoff: 1000, resonance: 1, drive: 4), 2)
      expect(out[-4800..].abs.max).to be < 1e-6
    end

    it 'oscillates at the cutoff with self_oscillate: true, at a bounded level' do
      f = diode(cutoff: 440, resonance: 1, self_oscillate: true)
      out = ring(f, 2)
      tail = Numo::DFloat.cast(out[-48000..])
      # quieter than lp4's ~0.22: the ladder is -25 dB at the cutoff
      expect(tail.abs.max).to be_between(0.03, 0.07)
      crossings = (1...tail.length).count { |i| tail[i - 1] < 0 && tail[i] >= 0 }
      expect(crossings).to be_within(5).of(440)
    end

    it 'starts oscillating from silence above 0.9, not below' do
      quiet = diode(cutoff: 1000, resonance: 0.85, self_oscillate: true).process(Numo::SFloat.zeros(96000))
      expect(quiet[-4800..].abs.max).to be < 1e-4
      loud = diode(cutoff: 1000, resonance: 1, self_oscillate: true).process(Numo::SFloat.zeros(96000))
      expect(loud[-4800..].abs.max).to be > 0.03
    end

    it 'maps quality: to the same gain at the cutoff' do
      [0.707, 2, 10].each do |q|
        r = fp.quality_to_resonance(q, diode: true)
        f = diode(cutoff: 1000, resonance: r)
        expect(10**((analytic_db(f, 1000) - analytic_db(f, 0.01)) / 20)).to be_within(1e-6).of(q)
      end
      expect(fp.quality_to_resonance(Numo::SFloat[0.01, 2, 1000], diode: true).to_a.map { |v| v.round(5) }).to eq(
        [0, fp.quality_to_resonance(2, diode: true).round(5), 1]
      )
      expect(fp.quality_to_resonance(2, curve: :linear, diode: true)).to be_within(1e-12).of(fp.diode_resonance_curve(fp.quality_to_resonance(2, diode: true)))
    end
  end

  describe 'stability' do
    let(:loud) { MB::Sound.with_seed(5) { Numo::SFloat.cast(MB::Sound.noise.sample(48000)) * 10 } }

    [
      { cutoff: 1, resonance: 1 },
      { cutoff: 23990, resonance: 1 },
      { cutoff: 1e9, resonance: 1 },
      { cutoff: 1000, resonance: 1, drive: 8 },
      { cutoff: 1000, resonance: 1, drive: 2, drive_mode: :feedback, clip: :hard },
      { cutoff: 23000, resonance: 1, self_oscillate: true },
      { cutoff: 1, resonance: 1, self_oscillate: true },
    ].each do |opts|
      it "stays bounded with #{opts}" do
        out = diode(**opts).process(loud)
        expect(out.isfinite.all?).to eq(true)
        expect(out.abs.max).to be < 200
      end
    end

    it 'stays bounded with the cutoff jumping between extremes every sample' do
      f = diode(resonance: 1)
      fc = Numo::SFloat.new(loud.length).seq.map { |i| i.to_i.even? ? 1 : 24000 }
      peaks = Array.new(5) {
        out = f.dynamic_process(loud, cutoff: fc, resonance: 1)
        expect(out.isfinite.all?).to eq(true)
        out.abs.max
      }
      expect(peaks.last).to be <= peaks.first * 1.01
    end
  end

  describe '#reset' do
    it 'sets the steady state for a constant input' do
      f = diode(cutoff: 300, resonance: 0.8)
      f.reset(0.5)
      out = f.process(Numo::SFloat.ones(100) * 0.5)
      k = f.loop_gain
      expect(out.to_a).to all(be_within(1e-6).of(0.5 * (1 + 0.375 * k) / (1 + k)))
    end
  end

  it 'rejects drive_mode: :stages' do
    expect { diode(drive_mode: :stages) }.to raise_error(ArgumentError, /diode/)
  end

  describe 'graph nodes' do
    it 'are made by #diode, #diode_ladder, lp4(mode: :diode), and filter(:diode)' do
      a = 110.hz.ramp.diode(800, resonance: 0.7, drive: 2)
      b = 110.hz.ramp.diode_ladder(800, resonance: 0.7, drive: 2)
      c = 110.hz.ramp.lp4(800, resonance: 0.7, mode: :diode, drive: 2)
      d = 110.hz.ramp.filter(:diode, cutoff: 800, resonance: 0.7)
      [a, b, c, d].each { |n| expect(n.filter).to be_diode }
      out = [a, b, c].map { |n| n.sample(1000) }
      expect(out[0]).to eq(out[1])
      expect(out[0]).to eq(out[2])
      expect(out[0].abs.max).to be > 0.05
    end

    it 'takes nodes for the cutoff and resonance, and quality:' do
      n = 110.hz.ramp.diode(2.hz.lfo.at(200..2000), resonance: 0.5.constant)
      expect(n.sample(4800).isfinite.all?).to eq(true)
      q = 110.hz.ramp.diode(800, quality: 4)
      expect(q.resonance).to be_within(1e-12).of(fp.quality_to_resonance(4, diode: true))
    end
  end
end
