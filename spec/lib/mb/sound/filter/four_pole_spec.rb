RSpec.describe(MB::Sound::Filter::FourPole) do
  FP = MB::Sound::Filter::FourPole unless defined?(FP)

  # Magnitude response in dB from a long impulse response (65536 samples at
  # 48 kHz, so 0.73 Hz bins); returns a lambda from Hz to dB.
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
    let(:noise) {
      MB::Sound.with_seed(3) { Numo::SFloat.cast(MB::Sound.noise.sample(4801)) }
    }
    let(:cutoffs) { Numo::DFloat.new(4801).seq.map { |i| 25000 * Math.sin(i * 0.003)**2 - 300 } }
    let(:resonances) { Numo::SFloat.new(4801).seq.map { |i| 1.3 * Math.sin(i * 0.0021)**2 - 0.1 } }

    FP::MODES.each do |mode, mix|
      [0.0, 1.5].each do |drive|
        it "give identical samples for #{mode} with modulated parameters#{drive > 0 ? ' and drive' : ''}" do
          s1 = [0.0] * 4
          s2 = [0.0] * 4
          [0...800, 800...801, 801...2400, 2400...4801].each do |r|
            c = MB::Sound::FastFilter.four_pole(noise[r].dup, cutoffs[r], resonances[r], s1, 48000, 4.3, 0.375, drive, mix)
            ruby = FP.process_ruby(noise[r].dup, cutoffs[r], resonances[r], s2, 48000, 4.3, 0.375, drive, mix)
            expect(c).to eq(ruby)
            expect(s1).to eq(s2)
          end
          expect(s1.all?(&:finite?)).to eq(true)
        end
      end
    end

    it 'give identical samples for constant parameters, complex inputs, and odd values' do
      [
        [1000, 0.5], [1, 1], [23999, 1], [Float::NAN, Float::NAN], [-5, -5], [nil, nil],
        [Numo::DComplex.cast(cutoffs) * (1 + 1i), Numo::SComplex.cast(resonances)],
      ].each do |fc, res|
        s1 = [0.25, -0.1, Float::NAN, 0.0]
        s2 = s1.dup
        c = MB::Sound::FastFilter.four_pole(noise.dup, fc, res, s1, 44100, 3.9, 0.375, 0.0, FP::MODES[:lp4])
        ruby = FP.process_ruby(noise.dup, fc, res, s2, 44100, 3.9, 0.375, 0.0, FP::MODES[:lp4])
        expect(c).to eq(ruby)
        expect(s1).to eq(s2)
      end
    end

    it 'filter an inplace SFloat in place' do
      buf = noise.dup.inplace!
      out = MB::Sound::FastFilter.four_pole(buf, 1000, 0.5, [0.0] * 4, 48000, 3.9, 0.375, 0.0, FP::MODES[:lp4])
      expect(out).to equal(buf)
    end

    it 'flushes tiny states to zero' do
      s = [1e-35, -1e-31, 0.5, 1e-29]
      MB::Sound::FastFilter.four_pole(Numo::SFloat[0], 1, 0, s, 48000, 3.9, 0.375, 0.0, FP::MODES[:lp4])
      expect(s[0]).to eq(0)
      expect(s[1]).to eq(0)
      s2 = [1e-35, -1e-31, 0.5, 1e-29]
      FP.process_ruby(Numo::SFloat[0], 1, 0, s2, 48000, 3.9, 0.375, 0.0, FP::MODES[:lp4])
      expect(s2).to eq(s)
    end

    it 'raise for bad arguments' do
      expect { MB::Sound::FastFilter.four_pole(noise, Numo::SFloat.zeros(3), 0, [0.0] * 4, 48000, 3.9, 0.375, 0.0, FP::MODES[:lp4]) }.to raise_error(ArgumentError, /length/)
      expect { FP.process_ruby(noise, Numo::SFloat.zeros(3), 0, [0.0] * 4, 48000, 3.9, 0.375, 0.0, FP::MODES[:lp4]) }.to raise_error(ArgumentError, /length/)
      expect { MB::Sound::FastFilter.four_pole(noise, 1, 0, [0.0] * 3, 48000, 3.9, 0.375, 0.0, FP::MODES[:lp4]) }.to raise_error(ArgumentError, /state/)
      expect { MB::Sound::FastFilter.four_pole(noise, 1, 0, [0.0] * 4, 0, 3.9, 0.375, 0.0, FP::MODES[:lp4]) }.to raise_error(ArgumentError, /rate/)
      expect { MB::Sound::FastFilter.four_pole(noise, 1, 0, [0.0] * 4, 48000, 3.9, 0.375, -1.0, FP::MODES[:lp4]) }.to raise_error(ArgumentError, /drive/)
      expect { MB::Sound::FastFilter.four_pole(noise, 1, 0, [0.0] * 4, 48000, 3.9, 0.375, 0.0, [1]) }.to raise_error(ArgumentError, /mix/)
    end

    it 'use the same tan and tanh approximations' do
      [0, 1e-6, 0.1, 0.5, 1, 1.5, 0.49 * Math::PI].each do |w|
        expect(MB::Sound::FastFilter.tan(w)).to eq(FP.tan(w))
        expect(FP.tan(w)).to be_within(4e-7 * Math.tan(w)).of(Math.tan(w))
      end
      [-4, -3, -1, -0.1, 0, 0.3, 1, 2.9, 3, 10].each do |x|
        expect(MB::Sound::FastFilter.tanh(x)).to eq(FP.tanh(x))
        expect(FP.tanh(x)).to be_within(0.025).of(Math.tanh(x))
      end
    end
  end

  describe 'response' do
    it 'is -12 dB at the cutoff with no resonance, 0 dB at DC, and 24 dB/octave above' do
      f = FP.new(cutoff: 1000, resonance: 0)
      db = measured_db(f)
      expect(db.(1)).to be_within(0.01).of(0)
      expect(db.(1000)).to be_within(0.05).of(-12.04)

      db100 = measured_db(FP.new(cutoff: 100))
      expect(db100.(1600) - db100.(3200)).to be_within(0.5).of(24)
    end

    it 'matches the analytic linear response' do
      [[1000, 0], [300, 0.7], [5000, 1], [20000, 0.5]].each do |fc, r|
        f = FP.new(cutoff: fc, resonance: r)
        db = measured_db(f)
        [50, 200, fc * 0.8, fc, [fc * 1.3, 23000].min, 12000].each do |hz|
          hz = (hz * 65536 / 48000.0).round * 48000.0 / 65536 # the FFT bin's frequency
          expected = analytic_db(f, hz)
          expect(db.(hz)).to be_within(expected > -90 ? 0.01 : 1).of(expected) # float32 output noise
        end
      end
    end

    it 'keeps the cutoff frequency at high cutoffs (prewarped)' do
      f = FP.new(cutoff: 15000, resonance: 0)
      expect(measured_db(f).(15000)).to be_within(0.05).of(-12.04)
    end

    it 'peaks near the cutoff with resonance, losing about 6 dB of bass at full resonance' do
      peaks = [0.5, 0.75, 0.9, 1.0].map { |r|
        f = FP.new(cutoff: 1000, resonance: r)
        db = measured_db(f)
        [db.(1), (900..1010).map { |hz| db.(hz) }.max]
      }
      dc = peaks.map(&:first)
      peak = peaks.map(&:last)

      expect(dc.last).to be_within(0.1).of(-6.0)
      expect(peak).to eq(peak.sort)
      expect(peak.last - dc.last).to be_between(35, 40)
      expect(peak.first - dc.first).to be_between(5, 10)
    end

    it 'loses about 14 dB of bass at full resonance with compensation: 0' do
      expect(measured_db(FP.new(cutoff: 1000, resonance: 1, compensation: 0)).(1)).to be_within(0.1).of(20 * Math.log10(1 / 4.9))
    end

    it 'gives unity passbands for the other modes without resonance' do
      expect(measured_db(FP.new(cutoff: 1000, mode: :lp2)).(1000)).to be_within(0.05).of(-6.02)
      expect(measured_db(FP.new(cutoff: 1000, mode: :bp2)).(1000)).to be_within(0.05).of(0)
      expect(measured_db(FP.new(cutoff: 1000, mode: :bp4)).(1000)).to be_within(0.05).of(0)
      expect(measured_db(FP.new(cutoff: 1000, mode: :hp2)).(20000)).to be_within(0.1).of(0)
      expect(measured_db(FP.new(cutoff: 1000, mode: :hp4)).(1000)).to be_within(0.05).of(-12.04)
      expect(measured_db(FP.new(cutoff: 1000, mode: :hp4, resonance: 0.9)).(20000)).to be_within(0.3).of(0)
    end
  end

  describe 'resonance' do
    def ring(filter, seconds)
      buf = Numo::SFloat.zeros((seconds * 48000).round)
      buf[0] = 1
      filter.process(buf)
    end

    it 'does not self-oscillate by default' do
      out = ring(FP.new(cutoff: 1000, resonance: 1), 2)
      expect(out[-4800..].abs.max).to be < 1e-6
    end

    it 'does not self-oscillate with drive' do
      out = ring(FP.new(cutoff: 1000, resonance: 1, drive: 4), 2)
      expect(out[-4800..].abs.max).to be < 1e-6
    end

    it 'oscillates near the cutoff with self_oscillate: true, at a bounded level' do
      f = FP.new(cutoff: 440, resonance: 1, self_oscillate: true)
      expect(f.drive).to eq(1.0)
      expect(f).to be_self_oscillate
      out = ring(f, 2)
      tail = Numo::DFloat.cast(out[-48000..])
      expect(tail.abs.max).to be_between(0.05, 1.0)

      crossings = (1...tail.length).count { |i| tail[i - 1] < 0 && tail[i] >= 0 }
      expect(crossings).to be_within(10).of(440)
    end

    it 'does not oscillate with self_oscillate: true below the threshold' do
      out = ring(FP.new(cutoff: 440, resonance: 0.9, self_oscillate: true), 2)
      expect(out[-4800..].abs.max).to be < 1e-4
    end
  end

  describe 'stability' do
    let(:loud) { MB::Sound.with_seed(5) { Numo::SFloat.cast(MB::Sound.noise.sample(48000)) * 10 } }

    [
      { cutoff: 1, resonance: 1 },
      { cutoff: 0.001, resonance: 1 },
      { cutoff: 23990, resonance: 1 },
      { cutoff: 1e9, resonance: 1 },
      { cutoff: 1000, resonance: 1, drive: 8 },
      { cutoff: 23000, resonance: 1, self_oscillate: true },
      { cutoff: 1, resonance: 1, self_oscillate: true },
    ].each do |opts|
      it "stays bounded with #{opts}" do
        out = FP.new(**opts).process(loud)
        expect(out.isfinite.all?).to eq(true)
        expect(out.abs.max).to be < 200
      end
    end

    it 'stays bounded with the cutoff jumping between extremes every sample' do
      # Pumping the cutoff at Nyquist amplifies (about 50x for noise at full
      # resonance), but the output doesn't grow over time.
      f = FP.new(resonance: 1)
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
      f = FP.new(cutoff: 300, resonance: 0.8)
      f.reset(0.5)
      out = f.process(Numo::SFloat.ones(100) * 0.5)
      expected = 0.5 * (1 + 0.375 * 0.8 * 3.9) / (1 + 0.8 * 3.9)
      expect(out.to_a).to all(be_within(1e-6).of(expected))
    end
  end

  describe '#sample_rate=' do
    it 'keeps the cutoff in Hz' do
      f = FP.new(cutoff: 1000, sample_rate: 48000)
      f.sample_rate = 96000
      imp = Numo::SFloat.zeros(65536)
      imp[0] = 1
      mag = Numo::Pocketfft.rfft(Numo::DFloat.cast(f.process(imp))).abs
      expect(20 * Math.log10(mag[(1000 * 65536 / 96000.0).round])).to be_within(0.1).of(-12.04)
    end
  end

  it 'rejects unknown modes and bad drives' do
    expect { FP.new(mode: :notch) }.to raise_error(ArgumentError, /mode/)
    expect { FP.new(drive: -1) }.to raise_error(ArgumentError, /Drive/)
  end

  describe '#dynamic_process_ruby' do
    it 'matches #dynamic_process' do
      a = FP.new(cutoff: 500, resonance: 0.7, drive: 2)
      b = FP.new(cutoff: 500, resonance: 0.7, drive: 2)
      input = Numo::SFloat.new(1000).rand(-1, 1)
      fc = Numo::SFloat.new(1000).seq(100, 10)
      expect(a.dynamic_process(input, cutoff: fc, resonance: 0.7)).to eq(b.dynamic_process_ruby(input, cutoff: fc, resonance: 0.7))
      expect(a.state).to eq(b.state)
      expect(a.cutoff).to eq(fc[-1])
    end
  end
end
