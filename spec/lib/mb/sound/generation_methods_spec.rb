RSpec.describe(MB::Sound::GenerationMethods) do
  describe '#noise' do
    it 'creates a noise generator node' do
      n = MB::Sound.noise.sample(48000)
      expect(n.mean.round(3)).to eq(0)
      expect(n.min.round(3)).to eq(-0.1)
      expect(n.max.round(3)).to eq(0.1)

      histogram = {}
      n.each do |v|
        next if v.abs.round(2) == 0.1 # the 0.1 bin only has contribution from below, not above, so ignore it

        histogram[v.round(2)] ||= 0
        histogram[v.round(2)] += 1
      end

      expect(histogram.values.max.to_f / histogram.values.min).to be_between(0.75, 1.33)

      diff = 2000.hz.ramp.generate(48000).diff
      expect(diff.mean.round(3)).to eq(0)

      diff_hist = {}
      diff.each do |v|
        next if v.abs.round(2) == 0.2

        diff_hist[v.round(2)] ||= 0
        diff_hist[v.round(2)] += 1
      end

      # A normal ramp wave will produce only two diff values, while noise will produce many
      expect(diff.length).to be > 10
    end
  end

  describe '#impulse' do
    it 'generates an impulse response node' do
      expect(MB::Sound.impulse.for(0.1).sample(8000)).to eq(Numo::SFloat.zeros(4800).tap { |d| d[0] = 1 })
    end
  end
end
