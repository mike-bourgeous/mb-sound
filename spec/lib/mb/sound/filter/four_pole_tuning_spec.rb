require 'mb/sound/filter/four_pole/tuning_analysis'

RSpec.describe(MB::Sound::Filter::FourPole::Tuning) do
  fp = MB::Sound::Filter::FourPole

  # Gain in dB relative to the passband (DC, or 20 kHz for highpasses) from
  # the analytic response
  def rel_db(f, hz)
    ref = f.mode.to_s.start_with?('hp') ? f.response(Math::PI * 0.999).abs : f.response(1e-9).abs
    ref = 1.0 if f.mode.to_s.start_with?('bp')
    20 * Math.log10(f.response(2 * Math::PI * hz / f.sample_rate).abs / ref)
  end

  # The resonant peak's frequency within an octave of +near+ (golden search
  # in log frequency)
  def peak_hz(f, near)
    lo = Math.log(near / 2.0)
    hi = Math.log(near * 2.0)
    g = ->(l) { rel_db(f, Math.exp(l)) }
    grid = (0..160).map { |i| lo + (hi - lo) * i / 160.0 }
    best = grid.max_by { |l| g.(l) }
    a = best - (hi - lo) / 160.0
    b = best + (hi - lo) / 160.0
    60.times do
      m1 = a + (b - a) * 0.381966
      m2 = b - (b - a) * 0.381966
      g.(m1) > g.(m2) ? b = m2 : a = m1
    end
    Math.exp((a + b) / 2)
  end

  def cents(a, b) = 1200 * Math.log2(a / b)

  describe 'the default musical tuning' do
    it 'is the default for every mode' do
      expect(fp.new.tuning).to eq(:musical)
      expect(fp.new(mode: :diode).tuning).to eq(:musical)
      expect(110.hz.saw.lp4(800).kernel_filter.tuning).to eq(:musical)
      expect(110.hz.saw.lp4(800, tuning: :hardware).kernel_filter.tuning).to eq(:hardware)
      expect { fp.new(tuning: :peak) }.to raise_error(ArgumentError, /tuning/)
    end

    it 'puts the -6 dB point of lowpasses and highpasses at the cutoff without resonance, bandpasses peaking there' do
      [:lp4, :lp2, :hp2, :hp4, :diode].each do |mode|
        [100, 1000, 15000].each do |fc|
          f = fp.new(mode: mode, cutoff: fc, resonance: 0)
          expect(rel_db(f, fc)).to be_within(0.01).of(-6.0206), "#{mode} at #{fc} Hz"
        end
      end
      [:bp2, :bp4].each do |mode|
        f = fp.new(mode: mode, cutoff: 1000, resonance: 0)
        expect(cents(peak_hz(f, 1000), 1000).abs).to be < 1, mode.to_s
      end
    end

    it 'is brighter than the hardware tuning without resonance (lp4 -3 dB at 676 Hz for a 1 kHz cutoff, hardware 435)' do
      expect(rel_db(fp.new(cutoff: 1000), 676)).to be_within(0.05).of(-3.01)
      expect(rel_db(fp.new(cutoff: 1000, tuning: :hardware), 435.5)).to be_within(0.05).of(-3.01)
      expect(rel_db(fp.new(mode: :diode, cutoff: 1000), 587)).to be_within(0.05).of(-3.01)
    end

    it 'puts the resonant peak at the cutoff within a cent once it stands 6 dB over the passband' do
      {
        lp4: 0.3, lp2: 0.2, bp2: 0.0, bp4: 0.0, hp2: 0.8, hp4: 0.9, diode: 0.5,
      }.each do |mode, from|
        [from, (from + 1) / 2, 0.9, 1.0].uniq.each do |r|
          (mode == :lp4 ? [100, 1000, 12000] : [1000, 12000]).each do |fc|
            f = fp.new(mode: mode, cutoff: fc, resonance: r)
            expect(cents(peak_hz(f, fc), fc).abs).to be < 1, "#{mode} r #{r} at #{fc} Hz: #{cents(peak_hz(f, fc), fc)} cents"
          end
        end
      end
    end

    it 'keeps the peak at or below the cutoff and the -6 dB edge at or above it as the resonance rises (lowpasses)' do
      [:lp4, :lp2, :diode].each do |mode|
        (0..25).each do |i|
          r = i / 25.0
          f = fp.new(mode: mode, cutoff: 1000, resonance: r)
          if rel_db(f, 1000) < -6.04 # (1 cent of the table)
            raise "#{mode} r #{r}: the cutoff is below -6 dB (#{rel_db(f, 1000)})"
          end
          pk = peak_hz(f, 700)
          if rel_db(f, pk) > 0.01 && pk > 300
            expect(cents(pk, 1000)).to be < 1, "#{mode} r #{r}: peak at #{pk}"
          end
        end
      end
    end

    it 'moves the old peak (hardware tuning) up onto the cutoff' do
      # The maintainer's measurements of lp4(1000) (2026-10-17): peak 782 Hz
      # at r 0.3, 917 at 0.5, 970 at 0.7, 990 at 0.9
      { 0.3 => 782, 0.5 => 917, 0.7 => 970, 0.9 => 990 }.each do |r, hz|
        hw = fp.new(cutoff: 1000, resonance: r, tuning: :hardware)
        expect(peak_hz(hw, 1000)).to be_within(2).of(hz)
        expect(peak_hz(fp.new(cutoff: 1000, resonance: r), 1000)).to be_within(0.6).of(1000)
      end
    end

    it 'matches the analytic response in the kernel' do
      [[:lp4, 1000, 0.0], [:lp4, 300, 0.6], [:lp2, 2000, 0.4], [:hp4, 1000, 0.95], [:bp2, 800, 0.3], [:diode, 500, 0.7]].each do |mode, fc, r|
        f = fp.new(mode: mode, cutoff: fc, resonance: r)
        imp = Numo::SFloat.zeros(65536)
        imp[0] = 1
        mag = Numo::Pocketfft.rfft(Numo::DFloat.cast(f.process(imp))).abs
        [fc * 0.5, fc, fc * 2].each do |hz|
          bin = (hz * 65536 / 48000.0).round
          expected = 20 * Math.log10(f.response(2 * Math::PI * bin / 65536).abs)
          expect(20 * Math.log10(mag[bin])).to be_within(0.01).of(expected)
        end
      end
    end

    it 'self-oscillates at the cutoff like the hardware tuning' do
      [[:lp4, :input], [:lp4, :feedback], [:lp2, :input], [:diode, :input], [:diode, :feedback]].each do |mode, dm|
        outs = [:musical, :hardware].map do |t|
          f = fp.new(mode: mode, cutoff: 440, resonance: 1, self_oscillate: true, drive_mode: dm, tuning: t)
          f.process(Numo::SFloat.zeros(48000))
        end
        expect(outs[0]).to eq(outs[1])
        x = outs[0][24000..].to_a
        cross = (1...x.length).select { |i| x[i - 1] < 0 && x[i] >= 0 }.map { |i| i - 1 + -x[i - 1] / (x[i] - x[i - 1]) }
        hz = (cross.length - 1) * 48000.0 / (cross.last - cross.first)
        expect(cents(hz, 440).abs).to be < 3, "#{mode} #{dm}: #{hz} Hz"
      end
    end

    it 'gives the same samples at any buffer size with resonance and cutoff moving every sample' do
      noise = MB::Sound.with_seed(5) { Numo::SFloat.cast(MB::Sound.noise.sample(4000)) }
      res = Numo::SFloat.new(4000).seq.map { |i| 0.5 + 0.5 * Math.sin(i * 0.004) }
      cut = Numo::SFloat.new(4000).seq.map { |i| 900 + 600 * Math.sin(i * 0.0013) }
      [:lp4, :hp2, :diode].each do |mode|
        whole = fp.new(mode: mode, drive: 1.5).dynamic_process(noise.dup, cutoff: cut, resonance: res)
        [1, 7, 128, 800].each do |n|
          f = fp.new(mode: mode, drive: 1.5)
          parts = (0...4000).step(n).map { |s| r = s...[s + n, 4000].min; f.dynamic_process(noise[r].dup, cutoff: cut[r], resonance: res[r]) }
          expect(parts.reduce { |a, b| a.concatenate(b) }).to eq(whole)
        end
      end
    end
  end

  describe 'the tables' do
    it 'hold the analysis target at the table points (make_tuning.rb --check regenerates all of them)' do
      ta = MB::Sound::Filter::FourPole::TuningAnalysis
      expect(described_class::TABLES.keys).to eq(described_class::MODES)
      described_class::MODES.each do |mode|
        [0, 9, 30, 57, 101].each do |i|
          expect(described_class::TABLES.fetch(mode)[2 * i]).to eq(ta.scale(mode, i.to_f / described_class::SEGMENTS))
        end
      end
    end

    it 'interpolate the analysis target within a cent' do
      ta = MB::Sound::Filter::FourPole::TuningAnalysis
      described_class::MODES.each_with_index do |mode, i|
        [0.003, 0.05, 0.11, 0.27, 0.42, 0.61, 0.83, 0.97].each do |x|
          expect(cents(described_class.scale(i + 1, x), ta.scale(mode, x)).abs).to be < 1, "#{mode} x #{x}"
        end
      end
    end
  end

  describe 'quality:' do
    it 'gives the gain q at the cutoff, none at 0.5 or less' do
      [[:lp4, false], [:diode, true]].each do |mode, diode|
        expect(fp.quality_to_resonance(0.5, diode: diode)).to eq(0)
        expect(fp.quality_to_resonance(0.3, diode: diode)).to eq(0)
        [0.707, 1, 2, 4, 10, 40].each do |q|
          f = fp.new(mode: mode, cutoff: 1000, resonance: fp.quality_to_resonance(q, diode: diode))
          expect(10**(rel_db(f, 1000) / 20)).to be_within(0.002 * q).of(q)
        end
      end
      arr = fp.quality_to_resonance(Numo::SFloat[0.4, 2, 4, 1000])
      expect(arr.to_a.map { |v| v.round(5) }).to eq([0, fp.quality_to_resonance(2), fp.quality_to_resonance(4), 1].map { |v| v.round(5) })
      expect(fp.quality_to_resonance(4, curve: :linear)).to be_within(1e-12).of(fp.resonance_curve(fp.quality_to_resonance(4)))
    end

    it 'gives each filter its own resonance for the same gain in the DSL' do
      lp = 110.hz.saw.lp4(800, quality: 4)
      d = 110.hz.saw.diode(800, quality: 4)
      expect(lp.resonance).to be_within(1e-12).of(fp.quality_to_resonance(4))
      expect(d.resonance).to be_within(1e-12).of(fp.quality_to_resonance(4, diode: true))
      hw = 110.hz.saw.diode(800, quality: 4, tuning: :hardware)
      expect(hw.resonance).to be_within(1e-12).of(fp.quality_to_resonance(4, tuning: :hardware))
    end
  end
end
