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

  # A Tone for kernel tests (the former low-level Oscillator): +band_limit+
  # true (default), false (naive a* shapes), or BandLimit::LFO_FADE (#lfo).
  def oscillator(wave, rate: 48000, frequency: 440, band_limit: true, phase_mod: nil, width: nil, sync: nil, soft_sync: false)
    t = MB::Sound::Tone.new(wave_type: wave, frequency: frequency, sample_rate: rate)
    t.send(:set_wave, wave, !!band_limit)
    if band_limit.is_a?(Range)
      raise 'Only BandLimit::LFO_FADE (Tone#lfo)' unless band_limit == MB::Sound::BandLimit::LFO_FADE
      t.lfo
    end
    t.pm(phase_mod) if phase_mod
    t.pwm(width) if width
    soft_sync ? t.softsync(sync) : t.sync(sync) if sync
    t
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
              fm = MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(4800).seq * 3 + 50], sample_rate: rate).with_buffer(480)
              # 30 radians of phase modulation at ~200 Hz moves the phase
              # backward through edges
              pm = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| 30 * Math.sin(i / 37.0) })], sample_rate: rate).with_buffer(480)
              oscillator(wave, rate: rate, frequency: fm, phase_mod: pm)
            }
            c = make.call
            r = make.call
            10.times do
              expect(c.sample_c(480)).to eq(r.sample_ruby(480))
            end
          end

          it 'give identical samples while fading band-limiting in' do
            fm = -> { MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(4800).seq * 0.01 + 10], sample_rate: rate).with_buffer(800) }
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

  describe 'edges landing exactly on samples while the phase moves backward' do
    # Runs the C kernel and its Ruby mirror; returns both outputs.
    def both(wave, freq, phi, count, phase_mod = 0)
      c = Numo::SFloat.zeros(count)
      MB::Sound::FastSynth.oscillate_bl(c.inplace, wave, freq, phase_mod, 1 / 48000.0, 1.0, 0.0, [phi], [0.0, 0.0, 0.0, 0], 0.0, 0.0, nil, false)
      r = MB::Sound::BandLimit.oscillate_ruby(count, wave, freq, phase_mod, 1 / 48000.0, 1.0, 0.0, [phi], [0.0, 0.0, 0.0, 0], 0.0, 0.0)
      [c.not_inplace!, r]
    end

    [:ramp, :square].each do |wave|
      it "gives the midpoint for a #{wave} edge on a sample at a negative frequency" do
        c, r = both(wave, -1000.0, 0.0, 4800)
        expect(c).to eq(r)
        off, _ = both(wave, -1000.0 * (1 + 1e-7), 0.0, 4800)
        expect((c - off).abs.max).to be < 1e-3
        # The edge at phase 0.5 lands on sample 24 (and every 48 after)
        expect(c[24]).to be_within(1e-6).of(0)
        expect(c.abs.max).to be <= 1.0
      end

      it "matches a nearby off-sample phase for a #{wave} reversing through-zero FM on an edge" do
        # +-2400 Hz in 4-sample runs: the phase goes 0.4, 0.45, 0.5 (the
        # edge), 0.55, 0.6, then back down through 0.5, again and again
        fm = Numo::SFloat.cast(Array.new(4800) { |i| (i / 4).even? ? 2400 : -2400 })
        c, r = both(wave, fm, 0.4, 4800)
        expect(c).to eq(r)
        off, _ = both(wave, fm, 0.4 + 1e-6, 4800)
        expect((c - off).abs.max).to be < 1e-3
        expect(c.abs.max).to be <= 1.0
      end

      it "matches a nearby off-sample phase for a #{wave} with phase modulation reversing on an edge" do
        # 0.1 cycles of phase per sample, forward 3 samples then back 3
        pm = Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| j = i % 6; 2 * Math::PI * 0.1 * (j <= 3 ? j : 6 - j) })
        c, r = both(wave, 0.0, 0.3, 4800, pm)
        expect(c).to eq(r)
        off, _ = both(wave, 0.0, 0.3 + 1e-6, 4800, pm)
        expect((c - off).abs.max).to be < 1e-3
      end
    end
  end

  it 'is not used for noise' do
    expect(1.hz.ramp.noise.band_limited?).to eq(false)
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
        expect(100.hz.send(wave).band_limited?).to eq(true), wave.to_s
      end
    end

    it 'has naive versions named a*' do
      { aramp: :ramp, asaw: :ramp, asawtooth: :ramp, asquare: :square, atriangle: :triangle }.each do |name, wave|
        tone = 100.hz.send(name)
        expect(tone.wave_type).to eq(wave)
        expect(tone.band_limited?).to eq(false), name.to_s
        expect(tone.to_s).to include(name.to_s.sub(/saw(tooth)?\z/, 'ramp'))
      end
    end

    it 'can switch after the oscillator was made' do
      tone = 100.hz.ramp
      expect(tone.band_limited?).to eq(true)
      tone.aramp
      expect(tone.band_limited?).to eq(false)
      tone.square
      expect(tone.band_limited?).to eq(true)
      expect(tone.wave_type).to eq(:square)
    end

    it 'is set by the shape name' do
      expect(MB::Sound::Tone.new(wave_type: :ramp).band_limited?).to eq(true)
      expect(MB::Sound::Tone.new(wave_type: :ramp).aramp.band_limited?).to eq(false)
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
              w = MB::Sound::ArrayInput.new(data: [Numo::SFloat.cast(Numo::DFloat.new(4800).seq.map { |i| 0.5 + 0.49 * Math.sin(i / 97.0) })], sample_rate: rate).with_buffer(480)
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
        ->(t) { t.sine.pwm(0.15) } => ->(t) { t.sine.pwm(0.15).tap { |x| x.send(:set_wave, :sine, false) } },
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

  describe 'complex BLIT' do
    def blit_osc(wave, rate: 48000, **opts)
      oscillator(wave, rate: rate, **opts)
    end

    [48000, 44100].each do |rate|
      MB::Sound::BandLimit::COMPLEX_WAVES.each do |wave|
        it "gives identical C and Ruby samples for #{wave} at #{rate} Hz, fixed and modulated" do
          c = blit_osc(wave, rate: rate, frequency: 1234.5)
          r = blit_osc(wave, rate: rate, frequency: 1234.5)
          [333, 1, 800].each { |n| expect(c.sample_c(n)).to eq(r.sample_ruby(n)) }

          make = -> { blit_osc(wave, rate: rate, frequency: MB::Sound::ArrayInput.new(data: [Numo::SFloat.new(4800).seq * 3 + 50], sample_rate: rate).with_buffer(480)) }
          c = make.call
          r = make.call
          5.times { expect(c.sample_c(480)).to eq(r.sample_ruby(480)) }
        end
      end
    end

    MB::Sound::BandLimit::COMPLEX_WAVES.each do |wave|
      it "has no aliases or negative frequencies above the float noise floor for #{wave}" do
        n = 16384
        k = 1025 # ~3 kHz
        tone = (k * 48000.0 / n).hz.send(wave)
        expect(tone.blit?).to eq(true)
        tone.sample(4800)
        spec = Numo::Pocketfft.fft(Numo::DComplex.cast(tone.sample(n))).abs**2
        harm = Numo::Bit.zeros(n)
        (k...(n / 2)).step(k) { |b| harm[b] = 1 }
        other_bins = ~harm
        other_bins[0] = 0
        other = spec[other_bins.where].sum
        expect(10 * Math.log10(other / spec[harm.where].sum)).to be < -120
      end

      it "has a real part close to the band-limited real #{wave.to_s.sub('complex_', '')}" do
        real = 1000.hz.send(wave).sample(4800).real
        clean = 1000.hz.send(wave.to_s.sub('complex_', '')).sample(4800)
        corr = (real * clean).sum / Math.sqrt((real**2).sum * (clean**2).sum)
        expect(corr).to be > 0.99
      end
    end

    describe 'complex shapes with phase modulation, warps, sync, and resets (complex wavetables)' do
      # Two-sided coherent aliasing of a complex +node+ (harmonics are the
      # multiples of k on both sides; see bin/aliasing.rb -c), dB
      def complex_nhr(k = 1365)
        n = 65536
        node = yield((k * 48000.0 / n).hz)
        node.sample(4800)
        data = Numo::DComplex.cast(Numo::NArray.concatenate(Array.new(n / 800 + 1) { node.sample(800).dup })[0...n])
        pow = Numo::Pocketfft.fft(data).abs**2
        harm = Numo::Bit.zeros(n)
        (k...(n / 2)).step(k) { |b| harm[b] = 1; harm[n - b] = 1 }
        limit = (20000.0 / 48000 * n).floor
        audible = Numo::Bit.zeros(n)
        audible[1..limit] = 1
        audible[(n - limit)..] = 1
        other = ~harm & audible
        other[0] = 0
        10 * Math.log10(pow[other].sum / pow[harm].sum)
      end

      it 'plays them from complex tables instead of the naive shapes' do
        expect(100.hz.complex_ramp.pm(3.hz.at(1)).blit?).to eq(false)
        expect(100.hz.complex_ramp.pm(3.hz.at(1)).send(:kernel)).to eq(:wavetable)
        expect(100.hz.complex_square.pwm(0.3).send(:exact_warp?)).to eq(true)
        expect(100.hz.complex_triangle.sync(ratio: 2).send(:kernel)).to eq(:wavetable)
        expect(100.hz.complex_ramp.send(:kernel)).to eq(:blit)
        expect(100.hz.complex_sine.pm(3.hz.at(1)).send(:kernel)).to eq(:naive) # an exponential stays exact
        expect(100.hz.acomplex_ramp.pm(3.hz.at(1)).send(:kernel)).to eq(:naive)
      end

      it 'band-limits phase modulation, warps, and sync' do
        pm = complex_nhr { |p| p.complex_ramp.pm(p.sine.at(0.5)) }
        naive = complex_nhr { |p| p.acomplex_ramp.pm(p.sine.at(0.5)) }
        expect(pm).to be < -44
        expect(pm).to be < naive - 20
        expect(complex_nhr { |p| p.complex_ramp.pwm(0.3) }).to be < -110
        expect(complex_nhr { |p| p.complex_square.sync(ratio: 2.37) }).to be < -100
      end

      it 'resets like sync to a pulse of 1 on the reset sample' do
        trig = -> { MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(900).tap { |t| t[[10, 300, 777]] = 1 }]) }
        a = 440.hz.complex_triangle.reset(trig.call)
        b = 440.hz.complex_triangle.sync(trig.call)
        expect(a.sample(900)).to eq(b.sample(900))
      end

      it 'gives the same samples in C and Ruby' do
        trig = -> { MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(900).tap { |t| t[[0, 300, 777]] = 1 }]) }
        [
          -> { 330.hz.complex_ramp.pm(330.hz.sine.at(0.5)) },
          -> { 330.hz.complex_square.pwm(2.hz.lfo.at(0.2..0.8)).reset(trig.call, to: 1.0) },
          -> { 330.hz.complex_ramp.pm(330.hz.sine.at(0.5)).reset(trig.call) },
          -> { 330.hz.complex_sine.pwm(0.2).sync(ratio: 1.7) },
        ].each do |make|
          c = make.call
          r = make.call
          3.times { expect(c.sample_c(300)).to eq(r.sample_ruby(300)) }
        end
      end
    end

    it 'has naive versions named acomplex_*' do
      [:acomplex_ramp, :acomplex_square, :acomplex_triangle].each do |name|
        tone = 100.hz.send(name)
        expect(tone.blit?).to eq(false)
        expect(tone.to_s).to include(name.to_s)
      end
    end

    it 'starts again without a transient after a phase jump between buffers' do
      osc = blit_osc(:complex_triangle, frequency: 440)
      osc.sample(1000)
      osc.send(:phase_jump) { osc.state.phi = 0 }
      fresh = blit_osc(:complex_triangle, frequency: 440)
      expect(osc.sample(800)).to eq(fresh.sample(800))
    end
  end

  describe 'sync pulses (wraps) at frequencies whose wraps land on samples' do
    # Expected [sample, value] of each wrap of a phase advancing k/n cycles
    # per sample from 0, for +total+ samples (exact Rational arithmetic): a
    # wrap at time t gives a pulse of 1 - d on sample ceil(t), d = ceil(t) - t,
    # so a wrap exactly on a sample gives 1 on that sample.
    def expected_wraps(k, n, total, sign = 1)
      (1...total).filter_map { |i|
        next if (i * k) / n == ((i - 1) * k) / n
        t = Rational(((i * k) / n) * n, k)
        [i, sign * (1 - (i - t)).to_f]
      }
    end

    # Pulses of +freq+.hz.phasor.wraps read in +sizes+, as [sample, value].
    def wraps(freq, total, sizes)
      tone = freq.hz.phasor
      w = tone.wraps
      bufs = []
      done = 0
      sizes.cycle do |s|
        s = [s, total - done].min
        tone.sample(s)
        bufs << w.sample(s).dup
        done += s
        break if done >= total
      end
      data = bufs.reduce(:concatenate)
      data.ne(0).where.to_a.map { |i| [i, data[i]] }
    end

    # Integer frequencies whose period is a whole number of samples or a
    # whole number of samples per few cycles (e.g. 4800 Hz, 20000 Hz)
    exact = [2000, 1000, 4000, 4800, 9600, 16000, 1500, 3000, 6000, 12000, 20000, 18000, 750, 100, 50]

    exact.each do |f|
      it "gives one pulse per wrap, on the sample, at #{f} Hz" do
        k, n = (f.to_r / 48000).then { |r| [r.numerator, r.denominator] }
        got = wraps(f, 4800, [800, 37, 128, 1, 300])
        want = expected_wraps(k, n, 4800)
        expect(got.map(&:first)).to eq(want.map(&:first))
        got.zip(want).each { |(_, g), (_, e)| expect(g).to be_within(1e-6).of(e) }
      end

      it "gives one negative pulse per backward wrap at -#{f} Hz" do
        k, n = (f.to_r / 48000).then { |r| [r.numerator, r.denominator] }
        # Backward from phase 0: the wrap at sample 0 (unprimed) isn't a
        # pulse; the later ones fall at the same times as forward wraps
        got = wraps(-f, 4800, [800, 37, 128, 1, 300])
        want = expected_wraps(k, n, 4800, -1)
        expect(got.map(&:first)).to eq(want.map(&:first))
        got.zip(want).each { |(_, g), (_, e)| expect(g).to be_within(1e-6).of(e) }
      end
    end

    it 'still gives fractional pulses at 2001 Hz' do
      got = wraps(2001, 4800, [800])
      want = expected_wraps(2001, 48000, 4800)
      expect(got.map(&:first)).to eq(want.map(&:first))
      got.zip(want).each { |(_, g), (_, e)| expect(g).to be_within(1e-4).of(e) }
    end
  end

  describe 'sync' do
    def coherent_db(tone, k, n: 65536)
      buffers = Array.new((4800 + n) / 800 + 1) { tone.sample(800).dup }
      data = Numo::DFloat.cast(Numo::SFloat.zeros(0).concatenate(*buffers)[4800...(4800 + n)])
      pow = MB::Sound.real_fft(data).abs**2
      harm = Numo::Bit.zeros(pow.length)
      (k...pow.length).step(k) { |b| harm[b] = 1 }
      # Below 20 kHz: minBLEP leaves some inaudible energy from 20 to 24 kHz
      other = ~harm
      other[0] = 0
      other[(20000.0 / 48000 * n).ceil..] = 0
      10 * Math.log10(pow[other.where].sum / pow[harm.where].sum)
    end

    [48000, 44100].each do |rate|
      MB::Sound::BandLimit::WARP_WAVES.each do |wave|
        [false, true].each do |soft|
          it "gives identical C and Ruby samples for a #{soft ? 'soft' : 'hard'}-synced, warped #{wave} at #{rate} Hz" do
            make = -> {
              master = MB::Sound::Pitch.new(110.0, sample_rate: rate).phasor
              oscillator(wave, rate: rate, frequency: 271.3, width: 0.4, sync: master.wraps, soft_sync: soft)
            }
            c = make.call
            r = make.call
            [800, 333, 1].each { |n| expect(c.sample_c(n)).to eq(r.sample_ruby(n)) }
          end
        end
      end
    end

    it 'gives clean hard sync for ramp, square, and pulse' do
      k = 301
      f = k * 48000.0 / 65536
      expect(coherent_db(f.hz.ramp.sync(ratio: 2.37), k)).to be < -95
      expect(coherent_db(f.hz.square.sync(ratio: 2.37), k)).to be < -95
      expect(coherent_db(f.hz.pulse(0.3).sync(ratio: 1.7), k)).to be < -95
    end

    # The mean of the ideal (unlimited) synced waveform over one master
    # cycle (hard sync) or two (soft sync).
    def ideal_mean(wave, ratio, soft)
      m = 1 << 14
      periods = soft ? 2 : 1
      p = 0.0
      dir = 1.0
      sum = 0.0
      (m * periods).times do |i|
        if i > 0 && i % m == 0
          soft ? dir = -dir : p = 0.0
        end
        sum += MB::Sound::BandLimit.shape(wave, p + 0.5 * ratio * dir / m)
        p = MB::Sound::BandLimit.wrap(p + ratio * dir / m)
      end
      sum / (m * periods)
    end

    [:ramp, :triangle, :parabola, :square, :sine].each do |wave|
      [false, true].each do |soft|
        it "keeps the ideal DC level for a #{soft ? 'soft' : 'hard'}-synced #{wave} at high pitch" do
          # The minBLEP delays steps by about 2.78 samples; without delaying
          # the segments to match, each step left that much area behind
          # (DC of +0.82 for a ramp hard-synced at 2.37x of 3 kHz)
          k = soft ? 4094 : 4097
          f = k * 48000.0 / 65536
          tone = f.hz.public_send(wave)
          tone = soft ? tone.softsync(ratio: 2.37) : tone.sync(ratio: 2.37)
          tone.sample(4800)
          data = Numo::DFloat.cast(Numo::SFloat.zeros(0).concatenate(*Array.new(82) { tone.sample(800).dup }))[0...65536]
          expect(data.mean).to be_within(2e-4).of(ideal_mean(wave, 2.37, soft))
        end
      end
    end

    it 'gives clean soft sync for squares, which reverse on their edge at phase 0' do
      # Soft sync brings the phase back to its start (0, the square's edge)
      # every two master cycles; it once crossed the edge backward without
      # changing the naive value, spiking to 3 (-20 to -30 dB aliasing)
      k = 682
      f = k * 48000.0 / 65536
      tone = f.hz.square.softsync(ratio: 2.37)
      expect(coherent_db(tone, k / 2)).to be < -95
      expect(f.hz.square.softsync(ratio: 2.37).sample(4800).abs.max).to be < 1.6
    end

    it 'gives clean hard sync for triangles, sines, and warped sines' do
      # Slope corners and sine segments were inexact before 2026-10-07
      # (-59 and -65 dB at 1 kHz)
      [301, 4097].each do |k|
        f = k * 48000.0 / 65536
        expect(coherent_db(f.hz.triangle.sync(ratio: 3.31), k)).to be < -90
        expect(coherent_db(f.hz.sine.sync(ratio: 2.37), k)).to be < -100
        expect(coherent_db(f.hz.sine.pwm(0.3).sync(ratio: 2.37), k)).to be < -95
      end
    end

    it 'restarts the naive waveform at each master cycle' do
      # 1 kHz master at 48 kHz: resets on samples 0 and 48 (the next lands
      # within rounding of 96, either side)
      data = 1000.hz.aramp.sync(ratio: 2.5).sample(96)
      inc = 2500.0 / 48000
      expected = Numo::SFloat.cast((0...96).map { |i| p = ((i % 48) * inc) % 1.0; p < 0.5 ? 2 * p : 2 * p - 2 })
      expect(data).to all_be_within(1e-5).of_array(expected)
    end

    it 'reverses the phase with softsync' do
      # 400 Hz slave, 1 kHz master: up to phase 0.4, then back down
      data = 1000.hz.aramp.softsync(ratio: 0.4).sample(96)
      rising = data[1..46] - data[0..45]
      falling = data[50..94] - data[49..93]
      expect(rising.min).to be > 0
      expect(falling.max).to be < 0
    end

    it 'accepts a Pitch, Tone, phasor, or trigger node as master' do
      expect(MB::Sound::C3.saw.sync(MB::Sound::C2).sample(800).abs.max).to be_between(0.5, 1.5)
      master = 110.hz.square
      slave = 333.hz.ramp.sync(master)
      2.times do
        expect(master.sample(800).length).to eq(800)
        expect(slave.sample(800).length).to eq(800)
      end
      expect(220.hz.ramp.sync(100.hz.phasor).sample(800).length).to eq(800)

      trigger = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(800).tap { |t| t[100] = 1; t[500] = 1 }])
      data = 1000.hz.aramp.sync(trigger).sample(800)
      expect(data[100]).to eq(0)
      expect(data[500]).to eq(0)
    end

    it 'accepts a graph node ratio' do
      tone = 110.hz.ramp.sync(ratio: 0.5.hz.lfo.at(1..4))
      expect(tone.sample(4800).abs.max).to be_between(0.5, 1.5)
    end

    it 'checks its arguments' do
      expect { 100.hz.ramp.sync(MB::Sound::C2, ratio: 2) }.to raise_error(ArgumentError, /not both/)
      expect { 100.hz.ramp.sync }.to raise_error(ArgumentError, /ratio/)
      expect { 100.hz.ramp.pm(3.hz).sync(ratio: 2).sample(800) }.to raise_error(ArgumentError, /phase modulation/)
      expect { 100.hz.gauss.sync(ratio: 2).sample(800) }.to raise_error(ArgumentError, /can't be synced/)
    end

    it 'shows sync in to_s' do
      expect(100.hz.ramp.sync(ratio: 2).to_s).to include('sync')
      expect(100.hz.ramp.softsync(ratio: 2).to_s).to include('softsync')
    end
  end

  describe 'phase jumps (note retriggers, timeline locks)' do
    # Triggers at +indices+ (repeating every +length+ samples if +repeat+).
    def trig(length, *indices, repeat: false)
      MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(length).tap { |t| indices.each { |i| t[i] = 1 } }], repeat: repeat)
    end

    def bl_osc(**opts)
      oscillator(:ramp, frequency: 1001.3, **opts)
    end

    it 'runs resets through the synced kernel as hard sync events on their samples' do
      # A reset to the start phase is exactly sync to a pulse of 1 on the
      # same sample (2026-10-08: resets as clean as sync)
      o = bl_osc.reset(trig(200, 30, 77, 150))
      s = bl_osc.sync(trig(200, 30, 77, 150))
      expect(o.send(:kernel)).to eq(:reset_sync)
      expect(o.sample(200)).to eq(s.sample(200))

      # Unchanged before the reset; after the step settles, the same as a
      # tone (with a reset input) started at that phase
      quiet = -> { bl_osc.reset(trig(100)) }
      continuing = quiet.call.sample(100).dup
      after = bl_osc.reset(trig(100, 30)).sample(100).dup
      expect(after[0...30]).to eq(continuing[0...30])
      fresh = quiet.call.sample(70).dup
      expect(after[(30 + 32)..]).to all_be_within(1e-6).of_array(fresh[32..])
    end

    it 'gives phase jump residuals the area of an ideal step or kink on the sample' do
      [[1.0, 0.0], [-2.0, 0.0], [0.0, 0.05], [0.7, -0.03]].each do |dv, ds|
        r = MB::Sound::Tone.jump_residual(dv, ds)
        expect(r.sum).to be_within(1e-12).of(-0.5 * dv + ds / 12.0)
        expect(r.length).to eq(MB::Sound::BandLimit::SYNC_TAPS)
      end
      expect(MB::Sound::Tone.jump_tables[2].sum).to be_within(1e-15).of(1)
    end

    # Coherent DC (mean over whole reset periods) of +node+.
    def mean_of(node, period, periods = 200)
      node.sample(period * 10)
      Numo::DFloat.cast(node.sample(period * periods)).mean
    end

    [[:ramp, 700, 200, 1 / 14.0], [:square, 700, 200, 1 / 7.0], [:ramp, 1000, 400, 0.1], [:triangle, 1000, 400, 0.1], [:ramp, 1700, 750, nil]].each do |wave, f, r, ideal|
      it "has the ideal mean with audio-rate resets (#{f} Hz #{wave} reset at #{r} Hz)" do
        period = 48000 / r
        ideal ||= mean_of(f.hz.send(wave).sync(r.hz.lfo.wraps), period)
        expect(mean_of(f.hz.send(wave).reset(r.hz.lfo.wraps), period)).to be_within(1e-3).of(ideal)
      end
    end

    it 'leaves naive and slow LFO oscillators jumping' do
      o = oscillator(:ramp, frequency: 1001.3, band_limit: false).reset(trig(31, 30))
      expect(o.sample(31)[30]).to eq(0)

      lfo = oscillator(:ramp, frequency: 5.3, band_limit: MB::Sound::BandLimit::LFO_FADE).reset(trig(3001, 3000))
      expect(lfo.sample(3001)[3000]).to be_within(1e-6).of(0)
    end

    it 'reduces the high-frequency energy of repeated retriggers' do
      energy = ->(o) {
        data = Numo::DFloat.cast(Numo::SFloat.zeros(0).concatenate(*Array.new(64) { o.sample(256).dup }))
        pow = MB::Sound.real_fft(data).abs**2
        pow[(22500.0 / 48000 * data.length).ceil..].sum
      }
      # Near Nyquist, above the minBLEP's passband (mostly aliasing there;
      # -11.5 dB with the PolyBLEP tone and minBLEP steps before 2026-10-08,
      # -21.8 through the synced kernel)
      clean = energy.(bl_osc.reset(trig(256, 0, repeat: true)))
      naive = energy.(oscillator(:ramp, frequency: 1001.3, band_limit: false).reset(trig(256, 0, repeat: true)))
      expect(10 * Math.log10(clean / naive)).to be < -18
    end

    it 'gives the same step in C and Ruby' do
      c = bl_osc.reset(trig(80, 30))
      r = bl_osc.reset(trig(80, 30))
      expect(c.sample_c(80)).to eq(r.sample_ruby(80))
    end

    it 'smooths timeline jumps (tempo-synced phase locks)' do
      # 1.n128 at 1920 BPM is 1024 Hz
      tempo = MB::Sound::Sequence::TempoNode.new(1.n128, mode: :hz, transport: MB::Sound::Sequence::Transport.new(bpm: 1920))
      t = MB::Sound::Pitch.new(tempo).ramp
      tempo.start_at(0)
      t.sample(30)
      tempo.start_at(0)
      expect(t.sample(1)[0].abs).to be > 0.1 # not the jump to 0
    end
  end
end
