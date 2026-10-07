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

    [[1, 0, 0], [0, 1, 0], [1, 1, 0], [1, 2, 0], [1, 2, 1], [0, 2, 1]].each do |curve, drive_mode, clip|
      it "give identical samples with curve #{curve}, drive mode #{drive_mode}, clip #{clip}" do
        s1 = [0.0] * 4
        s2 = [0.0] * 4
        loud = noise * 4
        [0...800, 800...801, 801...2400, 2400...4801].each do |r|
          c = MB::Sound::FastFilter.four_pole(loud[r].dup, cutoffs[r], resonances[r], s1, 48000, 4.3, 0.375, 2.5, FP::MODES[:lp4], curve, drive_mode, clip)
          ruby = FP.process_ruby(loud[r].dup, cutoffs[r], resonances[r], s2, 48000, 4.3, 0.375, 2.5, FP::MODES[:lp4], curve, drive_mode, clip)
          expect(c).to eq(ruby)
          expect(s1).to eq(s2)
        end
        expect(s1.all?(&:finite?)).to eq(true)
      end
    end

    it 'use the same secant gains' do
      [-10, -3.5, -1.1, -0.5, 0, 0.3, 0.8, 0.9, 1.2, 2.9, 3, 10].each do |x|
        [0, 1].each do |clip|
          expect(MB::Sound::FastFilter.secant(x, clip)).to eq(FP.secant(x, clip))
        end
        expect(FP.secant(x, 0) * x).to be_within(1e-15).of(FP.tanh(x))
        expect((FP.secant(x, 1) * x).abs).to be <= 1
      end
    end

    it 'raise for bad curve, drive mode, and clip numbers' do
      args = [noise, 1000, 0.5, [0.0] * 4, 48000, 3.9, 0.375, 1.0, FP::MODES[:lp4]]
      expect { MB::Sound::FastFilter.four_pole(*args, 2) }.to raise_error(ArgumentError, /curve/)
      expect { MB::Sound::FastFilter.four_pole(*args, 0, 3) }.to raise_error(ArgumentError, /Drive mode/)
      expect { MB::Sound::FastFilter.four_pole(*args, 0, 0, 2) }.to raise_error(ArgumentError, /Clip/)
      expect { MB::Sound::FastFilter.four_pole(*args, 0, 0, 0, 0) }.to raise_error(ArgumentError, /arguments/)
      expect { FP.process_ruby(*args, 2) }.to raise_error(ArgumentError, /curve/)
      expect { FP.process_ruby(*args, 0, 3) }.to raise_error(ArgumentError, /Drive mode/)
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
        f = FP.new(cutoff: 1000, resonance: r, resonance_curve: :linear)
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

  describe 'resonance curve' do
    # Peak gain over the passband (DC) from the analytic response.
    def peak_db(filter)
      w = Numo::DFloat.logspace(Math.log10(2 * Math::PI * 20 / 48000), Math.log10(2 * Math::PI * 8000 / 48000), 4000)
      20 * Math.log10(filter.response(w).abs.max / filter.response(0).abs)
    end

    it 'defaults to :db and keeps 0 and 1 at k 0 and k_max' do
      expect(FP.new.resonance_curve).to eq(:db)
      expect(FP.new(resonance: 0).loop_gain).to eq(0)
      expect(FP.new(resonance: 1).loop_gain).to eq(3.9)
      expect(FP.new(resonance: 1, self_oscillate: true).loop_gain).to eq(4.3)
      expect(FP.resonance_curve(-1)).to eq(0)
      expect(FP.resonance_curve(Float::NAN)).to eq(0)
      expect(FP.resonance_curve(2)).to eq(1)
    end

    it 'rises monotonically and matches the C curve' do
      r = (0..1000).map { |i| i / 1000.0 }
      ks = r.map { |v| FP.resonance_curve(v) }
      expect(ks).to eq(ks.sort)
      expect(ks.uniq.length).to eq(ks.length)
      r.each_slice(37) { |(v)| expect(MB::Sound::FastFilter.resonance_curve(v)).to eq(FP.resonance_curve(v)) }
      expect(FP.resonance_curve(0.999)).to be_within(1e-3).of(1)
    end

    it 'makes the gain at the cutoff linear in dB from -12 to +33.8 dB' do
      [0.1, 0.3, 0.5, 0.7, 0.9].each do |r|
        f = FP.new(cutoff: 1000, resonance: r)
        at_cutoff = 20 * Math.log10(f.response(2 * Math::PI * 1000 / 48000).abs / f.response(0).abs)
        expect(at_cutoff).to be_within(0.01).of(-12.04 + r * (33.80 + 12.04))
      end
    end

    it 'makes the resonant peak rise roughly linearly in dB above resonance 0.2' do
      peaks = (2..10).map { |i| peak_db(FP.new(cutoff: 1000, resonance: i / 10.0)) }
      steps = peaks.each_cons(2).map { |a, b| b - a }
      expect(steps).to all(be_between(3.5, 5.2))
      expect(peaks.last).to be_within(0.5).of(36.9)
      expect(peak_db(FP.new(cutoff: 1000, resonance: 0.5))).to be_within(0.5).of(14.5)
      expect(peak_db(FP.new(cutoff: 1000, resonance: 0.5, resonance_curve: :linear))).to be_within(0.5).of(7.5)
    end

    it 'rejects unknown curves' do
      expect { FP.new(resonance_curve: :log) }.to raise_error(ArgumentError, /curve/)
    end
  end

  describe 'drive modes' do
    let(:sine) { Numo::SFloat.new(48000).seq.map { |i| Math.sin(2 * Math::PI * 110 * i / 48000) } }

    # Ratio of the energy above the fundamental's bin to the fundamental's
    # (in dB) for a 110 Hz sine through +filter+ (the last 0.5 s).
    def thd_db(filter, amp)
      out = Numo::DFloat.cast(filter.process(sine * amp))[24000..]
      hann = 0.5 - 0.5 * Numo::NMath.cos(Numo::DFloat.new(24000).seq * (2 * Math::PI / 24000))
      mag = Numo::Pocketfft.rfft(out * hann).abs
      f0 = 55 # 110 Hz in 2 Hz bins
      fund = mag[(f0 - 2)..(f0 + 2)].sum
      harm = (2..20).sum { |h| mag[(h * f0 - 2)..(h * f0 + 2)].sum }
      20 * Math.log10(harm / fund)
    end

    it 'defaults to :input, with drive 1 for the other modes' do
      expect(FP.new.drive_mode).to eq(:input)
      expect(FP.new.drive).to eq(0)
      expect(FP.new(drive_mode: :stages).drive).to eq(1)
      expect(FP.new(drive_mode: :feedback, clip: :hard).drive).to eq(1)
      expect(FP.new(drive_mode: :feedback, drive: 3).drive).to eq(3)
    end

    it 'rejects unknown modes and clips, and clip: without :feedback' do
      expect { FP.new(drive_mode: :tape) }.to raise_error(ArgumentError, /drive mode/)
      expect { FP.new(drive_mode: :feedback, clip: :diode) }.to raise_error(ArgumentError, /clip/)
      expect { FP.new(drive_mode: :stages, clip: :hard) }.to raise_error(ArgumentError, /clip/)
    end

    [:input, :stages, :feedback].each do |mode|
      it "is linear for small signals with drive_mode: #{mode}" do
        lin = FP.new(cutoff: 800, resonance: 0.5).process(sine * 1e-3)
        out = FP.new(cutoff: 800, resonance: 0.5, drive_mode: mode).process(sine * 1e-3)
        expect((out - lin).abs.max).to be < 1e-8
      end

      it "adds harmonics to loud signals with drive_mode: #{mode}" do
        expect(thd_db(FP.new(cutoff: 150, resonance: 0.8, drive_mode: mode, drive: 3), 1)).to be > -40
        expect(thd_db(FP.new(cutoff: 150, resonance: 0.8, drive_mode: mode, drive: 3), 1e-3)).to be < -70
      end
    end

    it 'keeps the passband clean with drive_mode: :feedback while the resonance clips' do
      # Below the cutoff the feedback signal y4 - c x is small, so a loud
      # bass passes nearly undistorted
      fb = thd_db(FP.new(cutoff: 4000, resonance: 0.3, drive_mode: :feedback, drive: 3), 1)
      input = thd_db(FP.new(cutoff: 4000, resonance: 0.3, drive_mode: :input, drive: 3), 1)
      expect(fb).to be < input - 20
    end

    [[:stages, :soft], [:feedback, :soft], [:feedback, :hard]].each do |mode, clip|
      it "self-oscillates at a bounded level with drive_mode: #{mode}, clip: #{clip}" do
        f = FP.new(cutoff: 440, resonance: 1, self_oscillate: true, drive_mode: mode, clip: clip)
        out = f.process(Numo::SFloat.zeros(96000))
        tail = Numo::DFloat.cast(out[-48000..])
        expect(tail.abs.max).to be_between(0.05, 2.0)
        crossings = (1...tail.length).count { |i| tail[i - 1] < 0 && tail[i] >= 0 }
        expect(crossings).to be_within(20).of(440)
      end

      it "stays bounded with loud noise and extreme cutoffs with drive_mode: #{mode}, clip: #{clip}" do
        loud = MB::Sound.with_seed(5) { Numo::SFloat.cast(MB::Sound.noise.sample(24000)) * 10 }
        [1, 5000, 12000, 23500].each do |fc|
          [1, 3, 8].each do |drive|
            out = FP.new(cutoff: fc, resonance: 1, self_oscillate: true, drive_mode: mode, clip: clip, drive: drive).process(loud)
            expect(out.isfinite.all?).to eq(true)
            expect(out.abs.max).to be < 50
          end
        end
      end
    end

    it 'gives identical C and Ruby samples through #dynamic_process_ruby in every mode' do
      input = Numo::SFloat.new(2000).rand(-3, 3)
      fc = Numo::SFloat.new(2000).seq(100, 10)
      [[:stages, :soft], [:feedback, :soft], [:feedback, :hard]].each do |mode, clip|
        a = FP.new(cutoff: 500, resonance: 0.9, drive: 2, drive_mode: mode, clip: clip, self_oscillate: true)
        b = FP.new(cutoff: 500, resonance: 0.9, drive: 2, drive_mode: mode, clip: clip, self_oscillate: true)
        expect(a.dynamic_process(input, cutoff: fc, resonance: 0.9)).to eq(b.dynamic_process_ruby(input, cutoff: fc, resonance: 0.9))
        expect(a.state).to eq(b.state)
      end
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

    it 'starts oscillating from silence with self_oscillate: true' do
      f = FP.new(cutoff: 1000, resonance: 1, self_oscillate: true)
      out = f.process(Numo::SFloat.zeros(24000))
      expect(out[-4800..].abs.max).to be > 0.1
      expect(f.process(Numo::SFloat.zeros(24000)).abs.max).to be < 0.2
    end

    it 'does not oscillate with self_oscillate: true below the threshold' do
      out = ring(FP.new(cutoff: 440, resonance: 0.7, self_oscillate: true), 2)
      expect(out[-4800..].abs.max).to be < 1e-4
      out = ring(FP.new(cutoff: 440, resonance: 0.9, self_oscillate: true, resonance_curve: :linear), 2)
      expect(out[-4800..].abs.max).to be < 1e-4
    end

    it 'starts oscillating above resonance 0.74 with the dB curve (0.93 linear)' do
      f = FP.new(resonance: 0.75, self_oscillate: true)
      expect(f.loop_gain).to be > 4
      expect(f.loop_gain(0.73)).to be < 4
      expect(FP.new(resonance: 0.93, self_oscillate: true, resonance_curve: :linear).loop_gain).to be < 4
      expect(FP.new(resonance: 0.94, self_oscillate: true, resonance_curve: :linear).loop_gain).to be > 4
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
      k = FP.resonance_curve(0.8) * 3.9
      expected = 0.5 * (1 + 0.375 * k) / (1 + k)
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
