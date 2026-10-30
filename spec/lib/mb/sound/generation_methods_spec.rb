RSpec.describe(MB::Sound::GenerationMethods) do
  describe '#noise' do
    it 'creates a noise generator node' do
      n = MB::Sound.noise.sample(48000)
      expect(n.mean).to be_within(0.01).of(0)
      expect(n.min.round(3)).to eq(-1)
      expect(n.max.round(3)).to eq(1)

      histogram = {}
      n.each do |v|
        next if v.abs.round(1) == 1 # the 1.0 bin only has contribution from below, not above, so ignore it

        histogram[v.round(1)] ||= 0
        histogram[v.round(1)] += 1
      end

      expect(histogram.values.max.to_f / histogram.values.min).to be_between(0.75, 1.33)

      diff = 2000.hz.saw.sample(48000).diff
      expect(diff.mean).to be_within(0.01).of(0)

      diff_hist = {}
      diff.each do |v|
        next if v.abs.round(1) == 2

        diff_hist[v.round(1)] ||= 0
        diff_hist[v.round(1)] += 1
      end

      # A normal ramp wave will produce only two diff values, while noise will produce many
      expect(diff.length).to be > 10
    end

    it 'repeats after the same MB::Sound.seed, whatever ran before' do
      MB::Sound.seed(5)
      a = MB::Sound.noise.sample(1000).dup

      # Other noise sampled in between used to move the shared drand48 stream
      MB::Sound.noise.sample(777)
      2.hz.gauss.noise.sample(333)

      MB::Sound.seed(5)
      b = MB::Sound.noise.sample(1000).dup
      expect(b).to eq(a)

      MB::Sound.seed(6)
      expect(MB::Sound.noise.sample(1000)).not_to eq(a)
    end

    it 'gives each noise node its own stream, independent of read order' do
      MB::Sound.seed(5)
      a1 = MB::Sound.noise
      a2 = MB::Sound.noise
      x1 = a1.sample(500).dup
      x2 = a2.sample(500).dup
      expect(x1).not_to eq(x2)

      MB::Sound.seed(5)
      b1 = MB::Sound.noise
      b2 = MB::Sound.noise
      expect(b2.sample(500)).to eq(x2)
      expect(b1.sample(500)).to eq(x1)
    end

    context 'with a color' do
      # Octave band powers (dB, relative to 500-1000 Hz) of 10 s of noise
      def octave_powers(node)
        x = Numo::DFloat.cast(Numo::SFloat.zeros(0).concatenate(*Array.new(600) { node.sample(800).dup }))
        pw = MB::Sound.real_fft(x).abs**2
        powers = [31.25, 125, 500, 2000, 8000].map { |f| i = (f * 10).round; 10 * Math.log10(pw[i...(2 * i)].sum) }
        [powers.map { |p| p - powers[2] }, Math.sqrt((x**2).mean)]
      end

      it 'makes pink noise with equal power per octave at RMS 0.2' do
        powers, rms = octave_powers(MB::Sound.noise(:pink, seed: 1))
        powers.each { |p| expect(p).to be_within(0.6).of(0) }
        expect(rms).to be_within(0.01).of(0.2)
      end

      it 'makes brown noise falling 6 dB per octave (3 dB more per octave band than pink)' do
        powers, rms = octave_powers(MB::Sound.noise(:brown, seed: 1))
        powers.each_with_index { |p, i| expect(p).to be_within(1.0).of(-6.02 * (i - 2)) }
        expect(rms).to be_within(0.01).of(0.2)
        expect(MB::Sound.noise(:red, seed: 1).sample(100)).to eq(MB::Sound.noise(:brown, seed: 1).sample(100))
      end

      it 'is white for :white and nil' do
        expect(MB::Sound.noise(:white, seed: 2).sample(100)).to eq(MB::Sound.noise(seed: 2).sample(100))
        expect(MB::Sound.noise(nil, seed: 2).sample(100)).to eq(MB::Sound.noise(seed: 2).sample(100))
      end

      it 'is the same at any buffer size' do
        a = MB::Sound.noise(:pink, seed: 4)
        b = MB::Sound.noise(:pink, seed: 4)
        whole = a.sample(2000).dup
        parts = SpecBuffers.join([b.sample(7).dup, b.sample(1).dup, b.sample(1992).dup])
        expect(parts).to eq(whole)
      end

      it 'raises for unknown colors' do
        expect { MB::Sound.noise(:plaid) }.to raise_error(ArgumentError, /plaid/)
      end

      it 'prints itself back as Ruby' do
        expect(MB::Sound.noise(:pink, seed: 3).to_ruby).to eq('noise(:pink, seed: 3)')
      end

      it 'stays within 0.25 dB of a -3 dB/octave slope from 20 Hz to 20 kHz' do
        f = MB::Sound::Filter::NoiseColor.new(:pink, sample_rate: 48000)
        errs = (0..60).map { |i| hz = 20 * 1000.0**(i / 60.0); 20 * Math.log10(f.response(2 * Math::PI * hz / 48000).abs * Math.sqrt(hz)) }
        expect(errs.max - errs.min).to be < 0.5
      end
    end

    it 'takes an explicit seed' do
      expect(MB::Sound.noise(seed: 3).sample(100)).to eq(MB::Sound.noise(seed: 3).sample(100))
      expect(MB::Sound.noise(seed: 3).noise_seed).to eq(3)
    end

    it 'restarts from its seed with the state, and keeps going across buffers' do
      n = MB::Sound.noise(seed: 9)
      whole = n.sample(600).dup
      m = MB::Sound.noise(seed: 9)
      parts = SpecBuffers.join([m.sample(100).dup, m.sample(1).dup, m.sample(499).dup])
      expect(parts).to eq(whole)
      expect(m.state.to_h[:noise]).to eq(n.state.to_h[:noise])
    end

    # Until 2026-10-10, ~1% of samples differed by an ulp between block
    # sizes (the per-block sum of increments of up to +-freq/2 cycles
    # rounded differently); the phase now wraps every sample.
    {
      'MB::Sound.noise' => -> { MB::Sound.noise(seed: 4) },
      'a noise blend' => -> { 440.hz.saw.noise(0.3, seed: 4) },
      'FM noise' => -> { (100.hz.sine.at(50) + 300).tone.noise(seed: 4) },
      'wavetable noise' => -> { 220.hz.wavetable(:basic, scan: 0.4).noise(0.01, seed: 4) },
    }.each do |name, make|
      # One-sample blocks run for the first 4800 samples (about 48 of
      # which differed before the fix; a second of them took ~3 s).
      it "gives the same samples in any block sizes (#{name})" do
        runs = [[[48000], 48000], [[1], 4800], [[128], 48000], [[7, 300, 64, 801], 48000]].map { |sizes, total|
          n = make.call
          out = []
          got = 0
          sizes.cycle do |c|
            break if got >= total
            c = [c, total - got].min
            out << n.sample(c).dup
            got += c
          end
          SpecBuffers.join(out)
        }
        runs[1..].each { |r| expect(r.to_a).to eq(runs[0][0...r.length].to_a) }
      end
    end

    [
      ['uniform noise', -> { 2000.hz.saw.noise(seed: 1) }],
      ['gauss noise', -> { 1.hz.gauss.noise(seed: 2) }],
      ['blended noise', -> { 200.hz.sine.noise(0.00001, seed: 3) }],
      ['frequency-modulated noise', -> { 300.hz.saw.fm(90.hz.at(200)).noise(0.5, seed: 4) }],
      ['a noise phasor', -> { 400.hz.phasor.noise(0.01, seed: 5) }],
    ].each do |name, make|
      it "gives identical C and Ruby samples for #{name}" do
        c = make.call
        r = make.call
        [800, 37, 1, 256].each { |n| expect(c.sample(n)).to eq(sample_with(:ruby, r, n)) }
      end
    end
  end

  describe '#impulse' do
    it 'generates an impulse response node' do
      expect(MB::Sound.impulse.until(0.1).sample(8000)).to eq(Numo::SFloat.zeros(4800).tap { |d| d[0] = 1 })
    end
  end
end
