RSpec.describe('MB::Sound::FastLoudness') do
  # (true_peak is checked against its mirror in spec/lib/mb/sound/loudness_spec.rb)

  describe '.peak_sumsq' do
    it 'gives the peak and sum of squares of a gain times an SFloat (views too), matching its Ruby mirror exactly' do
      x = Numo::SFloat.new(1001).rand(-1, 1)
      [1.0, 0.5, -0.3, 1e-3].each do |g|
        expect(MB::Sound::FastLoudness.peak_sumsq(x, g)).to eq(MB::Sound::UI::BusMeter.peak_sumsq_ruby(x, g))
        expect(MB::Sound::FastLoudness.peak_sumsq(x[3..500], g)).to eq(MB::Sound::UI::BusMeter.peak_sumsq_ruby(x[3..500], g))
        expect(MB::Sound::FastLoudness.peak_sumsq(x[(0..) % 3], g)).to eq(MB::Sound::UI::BusMeter.peak_sumsq_ruby(x[(0..) % 3], g))
      end
      expect(MB::Sound::FastLoudness.peak_sumsq(Numo::SFloat[], 1.0)).to eq([0.0, 0.0])
      expect { MB::Sound::FastLoudness.peak_sumsq(Numo::DFloat[1], 1.0) }.to raise_error(ArgumentError, /SFloat/)
    end
  end
end
