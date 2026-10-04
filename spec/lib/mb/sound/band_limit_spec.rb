RSpec.describe(MB::Sound::BandLimit) do
  # Non-harmonic power relative to harmonic power (dB) of +wave+ at FFT bin
  # +k+ (coherent sampling: every harmonic lands on a multiple of k).
  def nonharmonic_db(tone, k, n: 16384)
    tone.sample(4800)
    data = Numo::DFloat.cast(tone.sample(n))
    pow = MB::Sound.real_fft(data).abs**2
    harm = Numo::Bit.zeros(pow.length)
    (k...pow.length).step(k).each { |b| harm[b] = 1 }
    nonharm = ~harm
    nonharm[0] = 0
    10 * Math.log10(pow[nonharm].sum / pow[harm].sum)
  end

  def oscillator(wave, rate: 48000, **opts)
    MB::Sound::Oscillator.new(wave, advance: 2 * Math::PI / rate, band_limit: true, **opts)
  end

  describe 'C and Ruby versions' do
    [48000, 44100].each do |rate|
      MB::Sound::BandLimit::WAVES.each do |wave|
        context "#{wave} at #{rate} Hz" do
          it 'give identical samples at a constant frequency, for odd buffer sizes' do
            c = oscillator(wave, rate: rate, frequency: 3001.7)
            r = oscillator(wave, rate: rate, frequency: 3001.7)
            [1, 7, 333, 800, 2].each do |count|
              expect(c.sample_c(count)).to eq(r.sample_ruby(count))
            end
          end

          it 'give identical samples with frequency and phase modulation, including moving backward' do
            make = -> {
              fm = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(4800).seq * 3 + 50]).with_buffer(480)
              # 30 radians of phase modulation at ~200 Hz moves the phase
              # backward through edges
              pm = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| 30 * Math.sin(i / 37.0) })]).with_buffer(480)
              oscillator(wave, rate: rate, frequency: fm, phase_mod: pm)
            }
            c = make.call
            r = make.call
            10.times do
              expect(c.sample_c(480)).to eq(r.sample_ruby(480))
            end
          end

          it 'give identical samples while fading band-limiting in' do
            fm = -> { MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(4800).seq * 0.01 + 10]).with_buffer(800) }
            c = oscillator(wave, rate: rate, frequency: fm.call, band_limit: 15..30)
            r = oscillator(wave, rate: rate, frequency: fm.call, band_limit: 15..30)
            6.times do
              expect(c.sample_c(800)).to eq(r.sample_ruby(800))
            end
          end
        end
      end
    end
  end

  describe 'aliasing' do
    [48000, 44100].each do |rate|
      { ramp: 12, square: 12, triangle: 12 }.each do |wave, min_improvement|
        it "is reduced by at least #{min_improvement} dB for a #{wave} near 3 kHz at #{rate} Hz" do
          n = 16384
          k = (3000.0 * n / rate).round | 1 # odd bin
          f = k * rate.to_f / n
          naive = nonharmonic_db(f.hz.at_rate(rate).send(:"a#{wave}"), k, n: n)
          clean = nonharmonic_db(f.hz.at_rate(rate).send(wave), k, n: n)
          expect(clean).to be < naive - min_improvement
        end
      end
    end
  end

  it 'changes only the samples on either side of a jump' do
    clean = 1001.3.hz.ramp.sample(4800)
    naive = 1001.3.hz.aramp.sample(4800)
    changed = (clean - naive).abs.gt(1e-7).where.to_a
    jumps = (naive[1..] - naive[0...-1]).lt(-1).where.to_a.map { |i| i + 1 } # first sample after each jump

    expect(changed).not_to be_empty
    expect(changed).to all(satisfy { |i| jumps.include?(i) || jumps.include?(i + 1) })
  end

  it 'gives the midpoint for a jump exactly on a sample' do
    # 1 kHz at 48 kHz: the ramp's jump at phase 0.5 lands on sample 24
    clean = 1000.hz.ramp.sample(48)
    expect(clean[24]).to be_within(1e-6).of(0)
    expect(clean[23]).to be_within(1e-6).of(1000.hz.aramp.sample(48)[23])
  end

  it 'does not correct across a phase reset' do
    osc = oscillator(:ramp, frequency: 100)
    osc.sample(240) # half a cycle: the next sample is right after the jump
    osc.reset
    expect(osc.sample(1)[0]).to eq(0)
  end

  it 'is not used for noise' do
    expect(1.hz.ramp.noise.oscillator.band_limited?).to eq(false)
  end

  describe 'Tone#lfo' do
    it 'keeps exact edges below 15 Hz' do
      # (the same shape computed in cycles instead of radians)
      expect(5.3.hz.ramp.lfo.sample(48000)).to all_be_within(1e-6).of_array(5.3.hz.aramp.lfo.sample(48000))
    end

    it 'is fully band-limited above 30 Hz' do
      expect(50.hz.square.lfo.sample(4800)).to eq(50.hz.square.sample(4800))
    end

    it 'fades in between' do
      lfo = 22.hz.ramp.lfo.sample(48000)
      clean = 22.hz.ramp.sample(48000)
      naive = 22.hz.aramp.sample(48000)
      i = (clean - naive).abs.max_index
      expect(lfo[i]).to be_between([clean[i], naive[i]].min + 0.01, [clean[i], naive[i]].max - 0.01)
    end
  end

  describe 'DSL' do
    it 'band-limits Tone ramp, square, and triangle by default' do
      [:ramp, :saw, :sawtooth, :square, :triangle].each do |wave|
        expect(100.hz.send(wave).oscillator.band_limited?).to eq(true), wave.to_s
      end
    end

    it 'has naive versions named a*' do
      { aramp: :ramp, asaw: :ramp, asawtooth: :ramp, asquare: :square, atriangle: :triangle }.each do |name, wave|
        tone = 100.hz.send(name)
        expect(tone.wave_type).to eq(wave)
        expect(tone.oscillator.band_limited?).to eq(false), name.to_s
        expect(tone.to_s).to include(name.to_s.sub(/saw(tooth)?\z/, 'ramp'))
      end
    end

    it 'can switch after the oscillator was made' do
      tone = 100.hz.ramp
      expect(tone.oscillator.band_limited?).to eq(true)
      tone.aramp
      expect(tone.oscillator.band_limited?).to eq(false)
      tone.square
      expect(tone.oscillator.band_limited?).to eq(true)
      expect(tone.oscillator.wave_type).to eq(:square)
    end

    it 'leaves the low-level Oscillator naive unless asked' do
      expect(MB::Sound::Oscillator.new(:ramp).band_limited?).to eq(false)
      expect(MB::Sound::Oscillator.new(:ramp, band_limit: true).band_limited?).to eq(true)
    end
  end

  describe 'phase warp (pwm)' do
    [48000, 44100].each do |rate|
      MB::Sound::BandLimit::WARP_WAVES.each do |wave|
        [true, false].each do |bl|
          it "gives identical C and Ruby samples for a #{bl ? 'band-limited' : 'naive'} #{wave} at #{rate} Hz, fixed and modulated" do
            c = oscillator(wave, rate: rate, frequency: 1234.5, width: 0.3, band_limit: bl)
            r = oscillator(wave, rate: rate, frequency: 1234.5, width: 0.3, band_limit: bl)
            3.times { expect(c.sample_c(333)).to eq(r.sample_ruby(333)) }

            make = -> {
              w = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| 0.5 + 0.49 * Math.sin(i / 97.0) })]).with_buffer(480)
              oscillator(wave, rate: rate, frequency: 777, width: w, band_limit: bl)
            }
            c = make.call
            r = make.call
            5.times { expect(c.sample_c(480)).to eq(r.sample_ruby(480)) }
          end
        end
      end
    end

    it 'leaves band-limited shapes unchanged at width 0.5' do
      [:ramp, :square, :triangle].each do |wave|
        expect(321.hz.send(wave).pwm(0.5).sample(4800)).to eq(321.hz.send(wave).sample(4800)), wave.to_s
      end
    end

    it 'leaves a sine unchanged (within rounding) at width 0.5' do
      expect(321.hz.sine.pwm(0.5).sample(4800)).to all_be_within(1e-6).of_array(321.hz.sine.sample(4800))
    end

    it 'makes a pulse high for the given fraction of each cycle, with DC removed' do
      data = 100.hz.pulse(0.25).sample(48000)
      expect(data.mean).to be_within(0.001).of(0)

      # With DC removed the levels are 1.5 and -0.5; count samples above the
      # middle (band-limited edges land in between)
      high = data.gt(0.5).count_true / 48000.0
      expect(high).to be_within(1.0 / 480).of(0.25) # one sample per cycle
    end

    it 'keeps the DC offset with dc: true' do
      expect(100.hz.pulse(0.25, dc: true).sample(48000).mean).to be_within(0.001).of(-0.5)
    end

    it 'removes the DC offset of every warped shape' do
      MB::Sound::BandLimit::WARP_WAVES.each do |wave|
        expect(100.hz.send(wave).pwm(0.2).sample(48000).mean).to be_within(0.003).of(0), wave.to_s
      end
    end

    it 'reduces aliasing of warped shapes' do
      # (at 4 kHz a warped sine improves less: BLAMP corrects its corners, but
      # its curvature also changes at the knee)
      n = 16384
      k = 341 # ~1 kHz
      f = k * 48000.0 / n
      {
        ->(t) { t.square.pwm(0.25) } => ->(t) { t.asquare.pwm(0.25) },
        ->(t) { t.triangle.skew(0.1) } => ->(t) { t.atriangle.skew(0.1) },
        ->(t) { t.sine.pwm(0.15) } => ->(t) { t.sine.pwm(0.15).tap { |x| x.oscillator.band_limit = false } },
      }.each do |clean, naive|
        expect(nonharmonic_db(clean.call(f.hz.tone), k, n: n)).to be < nonharmonic_db(naive.call(f.hz.tone), k, n: n) - 10
      end
    end

    it 'accepts a graph node for the width' do
      tone = 220.hz.pwm(0.5.hz.lfo.at(0.1..0.9)).square
      expect(tone.sources[:width]).to respond_to(:sample)
      expect(tone.sample(800).abs.max).to be <= 2
    end

    it 'has DSL shortcuts' do
      expect(100.hz.pulse(0.3).width).to eq(0.3)
      expect(100.hz.pulse(0.3).wave_type).to eq(:square)
      expect(100.hz.apulse(0.3).band_limited?).to eq(false)
      expect(100.hz.triangle.skew(0.2).width).to eq(0.2)
      expect(100.hz.skew(0.2).width).to eq(0.2)
      expect(100.hz.pwm(0.2).square.width).to eq(0.2)
      expect(100.hz.pulse(0.3).to_s).to include('pwm=0.3')
    end

    it 'handles extreme widths' do
      # Widths are clamped to MIN_WIDTH..(1 - MIN_WIDTH); a pulse narrower
      # than a sample is almost silent once band-limited (as it should be)
      [0, 1, -3, 7, Float::NAN].each do |w|
        data = 100.hz.pulse(w).sample(4800)
        expect(data.isfinite.all?).to eq(true), w.to_s
        expect(data.abs.max).to be < 2, w.to_s
      end

      # 1% of a 100 Hz cycle is 4.8 samples: clearly there
      data = 100.hz.pulse(0.01).sample(4800)
      expect(data.max - data.min).to be > 1.5
    end
  end
end
