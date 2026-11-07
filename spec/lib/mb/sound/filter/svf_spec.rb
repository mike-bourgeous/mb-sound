require 'numo/pocketfft'

RSpec.describe(MB::Sound::Filter::SVF, :aggregate_failures) do
  SVFF = MB::Sound::Filter::SVF unless defined?(SVFF)
  CBF = MB::Sound::Filter::Cookbook unless defined?(CBF)

  # Gain in dB for the types that take one
  def type_gain(type)
    SVFF::GAIN_TYPES.include?(type) ? 6.0 : nil
  end

  describe 'C and Ruby versions' do
    let(:n) { 4801 }
    let(:noise) { MB::Sound.with_seed(3) { Numo::SFloat.cast(MB::Sound.noise.sample(n)) } }
    # Cutoffs from below 0 to above Nyquist, qualities through 0, gains through 0
    let(:cutoffs) { Numo::DFloat.new(n).seq.map { |i| 25000 * Math.sin(i * 0.003)**2 - 300 } }
    let(:qualities) { Numo::SFloat.new(n).seq.map { |i| 3 * Math.sin(i * 0.0021)**2 - 0.1 } }
    let(:gains) { Numo::SFloat.new(n).seq.map { |i| 4 * Math.sin(i * 0.0011)**2 } }

    SVFF::TYPE_IDS.each do |id|
      type = "#{SVFF::FILTER_TYPES[id % SVFF::DECRAMP]}#{' (decramped)' if id >= SVFF::DECRAMP}"
      it "give identical samples for #{type} with modulated parameters" do
        s1 = [0.0, 0.0]
        s2 = [0.0, 0.0]
        [0...800, 800...801, 801...2400, 2400...4801].each do |r|
          c = MB::Sound::FastFilter.svf(noise[r].dup, cutoffs[r], qualities[r], gains[r], id, s1, 48000)
          ruby = SVFF.process_ruby(noise[r].dup, cutoffs[r], qualities[r], gains[r], id, s2, 48000)
          expect(c).to eq(ruby)
          expect(s1).to eq(s2)
        end
        expect(s1.all?(&:finite?)).to eq(true)
      end

      it "give identical samples for #{type} with constant parameters and NaN inputs" do
        s1 = [0.0, 0.0]
        s2 = [0.0, 0.0]
        c = MB::Sound::FastFilter.svf(noise.dup, 1234.5, 0.7, nil, id, s1, 44100)
        ruby = SVFF.process_ruby(noise.dup, 1234.5, 0.7, nil, id, s2, 44100)
        expect(c).to eq(ruby)

        nan = Numo::SFloat.new(n).fill(Float::NAN)
        c = MB::Sound::FastFilter.svf(noise.dup, nan, nan, nan, id, s1, 44100)
        ruby = SVFF.process_ruby(noise.dup, nan, nan, nan, id, s2, 44100)
        expect(c).to eq(ruby)
        expect(c.isfinite.all?).to eq(true)
        expect(s1).to eq(s2)
      end
    end

    it 'filters an inplace SFloat in place and copies others' do
      buf = noise.dup.inplace!
      out = MB::Sound::FastFilter.svf(buf, 500, 1, nil, 0, [0.0, 0.0], 48000)
      expect(out).to equal(buf)

      buf = noise.dup
      out = MB::Sound::FastFilter.svf(buf, 500, 1, nil, 0, [0.0, 0.0], 48000)
      expect(out).not_to equal(buf)
      expect(buf).to eq(noise)
    end

    it 'raises for bad arguments' do
      [13, -1, 16 + 5, 16 + 6, 16 + 7, 16 + 11, 16 + 12, 32, 16 + 32].each do |id|
        expect { MB::Sound::FastFilter.svf(noise, 500, 1, nil, id, [0.0, 0.0], 48000) }.to raise_error(ArgumentError, /type/)
        expect { SVFF.process_ruby(noise, 500, 1, nil, id, [0.0, 0.0], 48000) }.to raise_error(ArgumentError, /type/)
      end
      expect { MB::Sound::FastFilter.svf(noise, 500, 1, nil, 0, [0.0], 48000) }.to raise_error(ArgumentError, /state/)
      expect { MB::Sound::FastFilter.svf(noise, 500, 1, nil, 0, [0.0, 0.0], 0) }.to raise_error(ArgumentError, /rate/)
      expect { MB::Sound::FastFilter.svf(noise, noise[0..5], 1, nil, 0, [0.0, 0.0], 48000) }.to raise_error(ArgumentError, /length/)
    end
  end

  describe 'static responses' do
    let(:omegas) { Numo::DFloat.linspace(0.0005, 3.1, 2000) }

    CBF::FILTER_TYPES.each do |type|
      [[100, 0.5], [1000, 0.7071], [5000, 4], [20000, 0.9]].each do |hz, q|
        it "#{type} at #{hz} Hz, Q #{q} has the cookbook response (analytic)" do
          svf = SVFF.new(type, 48000, hz, quality: q, db_gain: type_gain(type))
          cb = CBF.new(type, 48000, hz, quality: q, db_gain: type_gain(type))
          # The kernel's tan approximation (FourPole.tan) is exact to about
          # 1e-16 at low frequencies and 4e-7 relative near 0.49 fs
          expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < (hz > 10000 ? 1e-7 : 1e-10)
        end
      end

      it "#{type} filters with the cookbook response (measured from the impulse response)" do
        svf = SVFF.new(type, 48000, 2000, quality: 3, db_gain: type_gain(type))
        cb = CBF.new(type, 48000, 2000, quality: 3, db_gain: type_gain(type))
        imp = Numo::SFloat.zeros(16384)
        imp[0] = 1
        measured = Numo::Pocketfft.rfft(Numo::DFloat.cast(svf.process(imp)))
        expected = cb.response(Numo::DFloat.linspace(0, Math::PI, measured.length))
        # float32 output: errors around 1e-7 of full scale
        expect((measured - expected).abs.max).to be < 1e-4
      end

      it "#{type} nulls against the cookbook biquad on noise (float32 rounding only)" do
        noise = MB::Sound.with_seed(5) { Numo::SFloat.cast(MB::Sound.noise.sample(48000)) }
        svf = SVFF.new(type, 48000, 700, quality: 1.5, db_gain: type_gain(type))
        cb = CBF.new(type, 48000, 700, quality: 1.5, db_gain: type_gain(type))
        a = svf.process(noise.dup)
        b = cb.process(noise.dup)
        residual_db = 20 * Math.log10((a - b).abs.max / b.abs.max)
        expect(residual_db).to be < -100
      end
    end

    it 'converts a bandwidth to a quality like the cookbook' do
      svf = SVFF.new(:peak, 48000, 3000, bandwidth_oct: 0.5, db_gain: -10)
      cb = CBF.new(:peak, 48000, 3000, bandwidth_oct: 0.5, db_gain: -10)
      expect(svf.quality).to be_within(1e-12).of(cb.quality)
      expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < 1e-9
    end

    it 'converts a shelf slope to a quality like the cookbook' do
      svf = SVFF.new(:lowshelf, 48000, 300, shelf_slope: 1, db_gain: 8)
      cb = CBF.new(:lowshelf, 48000, 300, shelf_slope: 1, db_gain: 8)
      expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < 1e-9
    end

    it 'can be made from a Cookbook filter' do
      cb = CBF.new(:highpass, 44100, 440, quality: 3)
      svf = SVFF.from_cookbook(cb)
      expect(svf.filter_type).to eq(:highpass)
      expect(svf.sample_rate).to eq(44100)
      expect(svf.cutoff).to eq(440)
      expect(svf.quality).to eq(3)
      expect((svf.response(omegas) - cb.response(omegas)).abs.max).to be < 1e-9
    end

    it 'raises for missing gains and unknown types' do
      expect { SVFF.new(:peak, 48000, 1000, quality: 1) }.to raise_error(ArgumentError, /gain/)
      expect { SVFF.new(:lowshelf, 48000, 1000, quality: 1) }.to raise_error(ArgumentError, /gain/)
      expect { SVFF.new(:bogus, 48000, 1000, quality: 1) }.to raise_error(ArgumentError, /type/)
      expect { SVFF.new(:lowpass, 48000, 1000) }.to raise_error(ArgumentError, /quality/)
      expect { SVFF.new(:highshelf1p, 48000, 1000) }.to raise_error(ArgumentError, /gain/)
      expect { SVFF.new(:lowpass1p, 48000, 1000, bandwidth_oct: 1) }.to raise_error(ArgumentError, /First-order/)
      expect { SVFF.new(:peak, 48000, 1000, quality: 1, db_gain: 3, decramp: true) }.to raise_error(ArgumentError, /decramp/)
      expect { SVFF.new(:lowshelf1p, 48000, 1000, db_gain: 3, decramp: true) }.to raise_error(ArgumentError, /decramp/)
    end
  end

  # filters-acd-1 (2026-11-07): one-pole types through the SVF at k = 2
  describe 'first-order types' do
    let(:omegas) { Numo::DFloat.linspace(0.0005, 3.1, 2000) }

    # The bilinear transform of an analog prototype +h+ (a Proc of s,
    # normalized to the cutoff), prewarped at +hz+
    def bilinear(omegas, hz, rate = 48000, &h)
      k = Math.tan(Math::PI * hz / rate)
      omegas.to_a.map { |w|
        z1 = CMath.exp(Complex(0, -w))
        h.call((1 - z1) / ((1 + z1) * k))
      }
    end

    def max_error(svf, expected, omegas)
      svf.response(omegas).to_a.zip(expected).map { |a, b| (a - b).abs }.max
    end

    [100, 1919, 12000, 23000].each do |hz|
      it "lowpass1p and highpass1p at #{hz} Hz are the bilinear one-poles (Filter::FirstOrder's :lowpass and :highpass)" do
        lp = SVFF.new(:lowpass1p, 48000, hz)
        hp = SVFF.new(:highpass1p, 48000, hz)
        expect(max_error(lp, bilinear(omegas, hz) { |s| 1 / (s + 1) }, omegas)).to be < 1e-7
        expect(max_error(hp, bilinear(omegas, hz) { |s| s / (s + 1) }, omegas)).to be < 1e-7
        fo_lp = MB::Sound::Filter::FirstOrder.new(:lowpass, 48000, hz)
        expect((lp.response(omegas) - fo_lp.response(omegas)).abs.max).to be < 1e-7
        # -3 dB at the cutoff, 0 dB in the passband
        w = 2 * Math::PI * hz / 48000
        expect(lp.response(w).abs).to be_within(1e-7).of(0.5**0.5)
        expect(hp.response(w).abs).to be_within(1e-7).of(0.5**0.5)
        expect(lp.response(0).abs).to be_within(1e-12).of(1)
        expect(hp.response(Math::PI).abs).to be_within(1e-7).of(1)
      end

      [15, 6, -6, -15].each do |db|
        it "#{db > 0 ? 'boosting' : 'cutting'} #{db.abs} dB shelves at #{hz} Hz have the first-order shelving responses" do
          gain = 10.0**(db / 20.0)
          low = SVFF.new(:lowshelf1p, 48000, hz, db_gain: db)
          high = SVFF.new(:highshelf1p, 48000, hz, db_gain: db)
          # Zolzer (DAFX): a boost puts the pole at the cutoff, a cut its
          # zero (the boost's mirror image)
          if gain >= 1
            expect(max_error(low, bilinear(omegas, hz) { |s| (s + gain) / (s + 1) }, omegas)).to be < 1e-6
            expect(max_error(high, bilinear(omegas, hz) { |s| (gain * s + 1) / (s + 1) }, omegas)).to be < 1e-6
          else
            expect(max_error(low, bilinear(omegas, hz) { |s| (s + 1) / (s + 1 / gain) }, omegas)).to be < 1e-6
            expect(max_error(high, bilinear(omegas, hz) { |s| (s + 1) / (s / gain + 1) }, omegas)).to be < 1e-6
          end
          expect(low.response(0).abs).to be_within(1e-9).of(gain)
          expect(high.response(0).abs).to be_within(1e-9).of(1)
          expect(high.response(Math::PI).abs).to be_within(1e-6).of(gain)
          # A cut is the mirror image of the boost
          mirror = SVFF.new(:highshelf1p, 48000, hz, db_gain: -db)
          expect((high.response(omegas) * mirror.response(omegas) - 1).abs.max).to be < 1e-6
        end
      end
    end

    it 'boosts 3 dB short of the shelf gain at the cutoff, and matches x + highpass1p(x) * (G - 1)' do
      noise = MB::Sound.with_seed(5) { Numo::SFloat.cast(MB::Sound.noise.sample(48000)) }
      gain = 15.db.to_f
      shelf = SVFF.new(:highshelf1p, 48000, 1919, gain: gain)
      expect(shelf.response(2 * Math::PI * 1919 / 48000).abs).to be_within(1e-6).of(((gain**2 + 1) / 2)**0.5)
      a = shelf.process(noise.dup)
      b = noise + SVFF.new(:highpass1p, 48000, 1919).process(noise.dup) * (gain - 1)
      expect(20 * Math.log10((a - b).abs.max / b.abs.max)).to be < -100
    end

    SVFF::FIRST_ORDER_TYPES.each do |type|
      it "#{type} filters with its response (measured from the impulse response) and ignores the quality" do
        svf = SVFF.new(type, 48000, 2000, db_gain: type_gain(type))
        imp = Numo::SFloat.zeros(16384)
        imp[0] = 1
        measured = Numo::Pocketfft.rfft(Numo::DFloat.cast(svf.process(imp.dup)))
        expected = svf.response(Numo::DFloat.linspace(0, Math::PI, measured.length))
        expect((measured - expected).abs.max).to be < 1e-4
        other = SVFF.new(type, 48000, 2000, quality: 7, db_gain: type_gain(type))
        expect(other.process(imp.dup)).to eq(SVFF.new(type, 48000, 2000, db_gain: type_gain(type)).process(imp.dup))
        expect(svf.to_s).not_to include('quality')
      end

      it "#{type} stays bounded with its cutoff moving every sample" do
        n = 48000
        noise = MB::Sound.with_seed(6) { Numo::SFloat.cast(MB::Sound.noise.sample(n)) }
        cut = Numo::SFloat.new(n).seq.map { |i| 12000 * Math.sin(i * 2 * Math::PI * 2000 / 48000)**2 + 20 }
        svf = SVFF.new(type, 48000, 1000, db_gain: type_gain(type))
        out = svf.dynamic_process(noise.dup, cutoff: cut, quality: 0.5)
        expect(out.isfinite.all?).to eq(true)
        expect(out.abs.max).to be < 4 * noise.abs.max
      end
    end
  end

  # filters-acd-1 (2026-11-07): designs matched to the analog magnitude
  describe 'decramp: true' do
    def analog(type, hz, q, gain, f)
      k = 1.0 / q
      s = Complex(0, f / hz.to_f)
      d = s * s + k * s + 1
      case type
      when :lowpass then 1 / d
      when :highpass then s * s / d
      when :bandpass then k * gain * s / d
      when :bandpass_skirt then gain * s / d
      when :notch then (s * s + 1) / d
      when :allpass then (s * s - k * s + 1) / d
      when :lowpass1p then 1 / (s + 1)
      when :highpass1p then s / (s + 1)
      end
    end

    def db(x)
      20 * Math.log10([x, 1e-30].max)
    end

    # The largest dB error of +svf+ against the analog response over 20 Hz to
    # 20 kHz where the analog response is within 12 dB of its largest value
    def max_db_error(svf, type, hz, q, gain)
      freqs = Array.new(301) { |i| 20.0 * 1000.0**(i / 300.0) }
      ha = freqs.map { |f| analog(type, hz, q, gain, f).abs }
      top = ha.map { |h| db(h) }.max
      freqs.each_with_index.map { |f, i|
        next 0 if db(ha[i]) < top - 12
        (db(svf.response(2 * Math::PI * f / 48000).abs) - db(ha[i])).abs
      }.max
    end

    # Measured 2026-11-07 (design/notes/filters.md): worst errors over these
    # grids were 0.78 dB (lowpass), 1.84 (highpass at 20 kHz, Q 5.44), 1.02
    # (bandpasses), 2.73 (notch at 15 kHz, Q 0.5), 0.80 (one-poles); the
    # bilinear designs reach 6-16 dB
    LIMITS = {
      lowpass: 1.0, highpass: 2.0, bandpass: 1.2, bandpass_skirt: 1.2, notch: 3.0, allpass: 0.001,
      lowpass1p: 1.0, highpass1p: 1.0,
    }.freeze

    SVFF::DECRAMP_TYPES.each do |type|
      it "#{type} stays within #{LIMITS.fetch(type)} dB of the analog response up to 20 kHz at 48 kHz" do
        qs = SVFF::FIRST_ORDER_TYPES.include?(type) ? [0.5] : [0.5, 0.707, 2, 12.77, 24.9]
        worst = 0
        worst_bilinear = 0
        qs.each do |q|
          [100, 1000, 5000, 10000, 15000, 20000].each do |hz|
            gain = type == :bandpass || type == :bandpass_skirt ? 2.0 : 1.0
            worst = [worst, max_db_error(SVFF.new(type, 48000, hz, quality: q, gain: gain, decramp: true), type, hz, q, gain)].max
            worst_bilinear = [worst_bilinear, max_db_error(SVFF.new(type, 48000, hz, quality: q, gain: gain), type, hz, q, gain)].max
          end
        end
        expect(worst).to be < LIMITS.fetch(type)
        expect(worst_bilinear).to be > 5 unless type == :allpass
      end

      it "#{type} decramped filters with its response (measured from the impulse response)" do
        svf = SVFF.new(type, 48000, 12000, quality: 3, gain: 1.5, decramp: true)
        expect(svf.type_id).to eq(SVFF::FILTER_TYPE_IDS[type] + 16)
        imp = Numo::SFloat.zeros(16384)
        imp[0] = 1
        measured = Numo::Pocketfft.rfft(Numo::DFloat.cast(svf.process(imp)))
        expected = svf.response(Numo::DFloat.linspace(0, Math::PI, measured.length))
        expect((measured - expected).abs.max).to be < 1e-4
      end
    end

    it 'keeps the analog gain at the cutoff and the lowpass at DC, and its phase near the analog in the passband' do
      [[:lowpass, 0.63], [:lowpass, 24.9], [:highpass, 5]].each do |type, q|
        svf = SVFF.new(type, 48000, 20000, quality: q, decramp: true)
        expect(svf.response(2 * Math::PI * 20000 / 48000).abs).to be_within(1e-9).of(q)
      end
      lp = SVFF.new(:lowpass, 48000, 15000, quality: 0.707, decramp: true)
      expect(lp.response(0).real).to be_within(1e-12).of(1)
      # (magnitudes are matched, not phases: 4 degrees here)
      expect((lp.response(2 * Math::PI * 1000 / 48000) / analog(:lowpass, 15000, 0.707, 1, 1000)).arg.abs).to be < 0.1
      bp = SVFF.new(:bandpass, 48000, 15000, quality: 4, gain: 1, decramp: true)
      expect(bp.response(2 * Math::PI * 15000 / 48000).abs).to be_within(1e-9).of(1)
      expect(SVFF.new(:notch, 48000, 15000, quality: 4, decramp: true).response(2 * Math::PI * 15000 / 48000).abs).to be < 1e-9
    end

    it 'matches the bilinear design at low cutoffs (within 0.03 dB below 1 kHz for a 100 Hz lowpass)' do
      a = SVFF.new(:lowpass, 48000, 100, quality: 2, decramp: true)
      b = SVFF.new(:lowpass, 48000, 100, quality: 2)
      omegas = Numo::DFloat.linspace(0.0005, 2 * Math::PI * 1000 / 48000, 200)
      expect((Numo::NMath.log10(a.response(omegas).abs) - Numo::NMath.log10(b.response(omegas).abs)).abs.max * 20).to be < 0.03
    end

    it 'designs the lowest cutoffs without cancellation (within 0.5% of the bilinear response at 1-5 Hz, any quality)' do
      # (the zeros come from small differences there: the poles' magnitude
      # at the cutoff once lost 5 digits at 1 Hz, Q 29, giving a bandpass 121
      # times too loud)
      SVFF::DECRAMP_TYPES.each do |type|
        [1, 2, 5].product([0.05, 0.707, 30, 1000]).each do |hz, q|
          a = SVFF.new(type, 48000, hz, quality: q, gain: 1, decramp: true)
          b = SVFF.new(type, 48000, hz, quality: q, gain: 1)
          omegas = Numo::DFloat.linspace(0.05, 10, 200) * (2 * Math::PI * hz / 48000)
          expect((a.response(omegas) - b.response(omegas)).abs.max / b.response(omegas).abs.max).to be < 5e-3
        end
      end
    end

    it 'stays bounded when every parameter moves every sample (near the bilinear design\'s peak)' do
      n = 48000
      noise = MB::Sound.with_seed(7) { Numo::SFloat.cast(MB::Sound.noise.sample(n)) }
      cut = Numo::SFloat.new(n).seq.map { |i| 23500 * Math.sin(i * 0.002)**2 + 1 }
      q = Numo::SFloat.new(n).seq.map { |i| 30 * Math.sin(i * 0.0007)**2 + 0.05 }
      SVFF::DECRAMP_TYPES.each do |type|
        svf = SVFF.new(type, 48000, 1000, quality: 1, gain: 1, decramp: true)
        out = svf.dynamic_process(noise.dup, cutoff: cut, quality: q)
        bilinear = SVFF.new(type, 48000, 1000, quality: 1, gain: 1).dynamic_process(noise.dup, cutoff: cut, quality: q)
        expect(out.isfinite.all?).to eq(true)
        # (resonances near Nyquist pass more noise than the bilinear's,
        # which squeezes their bandwidth: up to 2.3 times the peak here)
        expect(out.abs.max).to be < 3 * bilinear.abs.max
      end
    end

    it 'prints as decramped' do
      expect(SVFF.new(:lowpass, 48000, 1000, quality: 2, decramp: true).to_s).to include('decramped')
    end
  end

  describe '#reset' do
    it 'sets the steady state for a constant input' do
      [:lowpass, :highpass, :lowshelf, :highshelf, :notch, *SVFF::FIRST_ORDER_TYPES].each do |type|
        f = SVFF.new(type, 48000, 500, quality: 2, db_gain: type_gain(type))
        steady = f.reset(0.5)
        out = f.process(Numo::SFloat.new(100).fill(0.5))
        expect(out.to_a).to all_be_within(1e-6).of_array([steady] * 100)
        expect(steady).to be_within(1e-9).of(0.5 * f.response(0).real)
      end
    end
  end

  describe 'parameter changes' do
    let(:sine) { Numo::SFloat.new(48000).seq.map { |i| Math.sin(i * 2 * Math::PI * 220 / 48000) } }

    it 'stays bounded with no DC bump when the cutoff dives toward 0 Hz and back' do
      # 3400 Hz down to 0 (and below) and back up within 50 ms
      cut = Numo::SFloat.new(48000).seq.map { |i|
        t = i / 48000.0
        t < 0.2 ? 3400 : (t < 0.25 ? 3400 * Math.cos((t - 0.2) * 20 * Math::PI) : 3400)
      }
      out = SVFF.new(:lowpass, 48000, 3400, quality: 0.7071).dynamic_process(sine.dup, cutoff: cut, quality: 0.7071)
      expect(out.abs.max).to be < 1.1
    end

    it 'stays stable at the lowest and highest cutoffs and very high quality' do
      [0, 1, 23999, 1e9].each do |fc|
        f = SVFF.new(:bandpass_skirt, 48000, fc, quality: 1000)
        out = f.process(sine.dup)
        expect(out.isfinite.all?).to eq(true)
        expect(f.state.all?(&:finite?)).to eq(true)
      end
    end

    it 'keeps the last parameter values for #process' do
      f = SVFF.new(:peak, 48000, 1000, quality: 1, db_gain: 3)
      f.dynamic_process(sine[0...100].dup, cutoff: Numo::SFloat.linspace(1000, 2000, 100), quality: 3, gain: Numo::SFloat[*[2.0] * 100])
      expect(f.cutoff).to eq(2000)
      expect(f.quality).to eq(3)
      expect(f.gain).to eq(2)
    end

    it 'gives the same samples through the Ruby mirror method' do
      a = SVFF.new(:lowshelf, 48000, 200, quality: 0.7, db_gain: 6)
      b = SVFF.new(:lowshelf, 48000, 200, quality: 0.7, db_gain: 6)
      cut = Numo::SFloat.linspace(200, 2000, 1000)
      expect(a.dynamic_process(sine[0...1000].dup, cutoff: cut, quality: 0.7)).to eq(MB::Sound::Kernels.with(:ruby) { b.dynamic_process(sine[0...1000].dup, cutoff: cut, quality: 0.7) })
      expect(a.state).to eq(b.state)
    end
  end

  it 'changes its sample rate' do
    f = SVFF.new(:lowpass, 48000, 20000, quality: 1)
    f.sample_rate = 22050
    expect(f.sample_rate).to eq(22050)
    expect(f.cutoff).to eq(22050 * 0.49)
  end
end
