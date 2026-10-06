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

      diff = 2000.hz.ramp.sample(48000).diff
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

    it 'takes an explicit seed' do
      expect(MB::Sound.noise(seed: 3).sample(100)).to eq(MB::Sound.noise(seed: 3).sample(100))
      expect(MB::Sound.noise(seed: 3).noise_seed).to eq(3)
    end

    it 'restarts from its seed with the state, and keeps going across buffers' do
      n = MB::Sound.noise(seed: 9)
      whole = n.sample(600).dup
      m = MB::Sound.noise(seed: 9)
      parts = [m.sample(100).dup, m.sample(1).dup, m.sample(499).dup].reduce(:concatenate)
      expect(parts).to eq(whole)
      expect(m.state.to_h[:noise]).to eq(n.state.to_h[:noise])
    end

    [
      ['uniform noise', -> { 2000.hz.ramp.noise(seed: 1) }],
      ['gauss noise', -> { 1.hz.gauss.noise(seed: 2) }],
      ['blended noise', -> { 200.hz.sine.noise(0.00001, seed: 3) }],
      ['frequency-modulated noise', -> { 300.hz.ramp.fm(90.hz.at(200)).noise(0.5, seed: 4) }],
      ['a noise phasor', -> { 400.hz.phasor.noise(0.01, seed: 5) }],
    ].each do |name, make|
      it "gives identical C and Ruby samples for #{name}" do
        c = make.call
        r = make.call
        [800, 37, 1, 256].each { |n| expect(c.sample_c(n)).to eq(r.sample_ruby(n)) }
      end
    end
  end

  describe '#impulse' do
    it 'generates an impulse response node' do
      expect(MB::Sound.impulse.until(0.1).sample(8000)).to eq(Numo::SFloat.zeros(4800).tap { |d| d[0] = 1 })
    end
  end
end
