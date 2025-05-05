# This is the C extension from ext/mb/sound/fast_resample/
RSpec.describe(MB::Sound::FastResample, :aggregate_failures) do
  let(:r_half) { MB::Sound::FastResample.new(0.5) }
  let(:r_double) { MB::Sound::FastResample.new(2) }

  describe '#initialize' do
    it 'raises an error if the rate ratio is too small' do
      expect { MB::Sound::FastResample.new(257) }.to raise_error(ArgumentError, /ratio.*<= 256/)
      expect { MB::Sound::FastResample.new(Float::INFINITY) }.to raise_error(ArgumentError, /ratio.*<= 256/)
    end

    it 'raises an error if the rate ratio is too large' do
      expect { MB::Sound::FastResample.new(0.999 / 256.0) }.to raise_error(ArgumentError, /ratio.*>= 1.256/)
      expect { MB::Sound::FastResample.new(-1) }.to raise_error(ArgumentError, /ratio.*>= 1.256/)
    end

    it 'raises an error if the rate ratio is not a number' do
      expect { MB::Sound::FastResample.new(Float::NAN) }.to raise_error(ArgumentError, /ratio.*NaN/)
    end

    it 'succeeds when given a reasonable ratio' do
      expect { MB::Sound::FastResample.new(Math::PI) }.not_to raise_error
      expect { MB::Sound::FastResample.new(0.1) }.not_to raise_error
    end
  end

  describe '#read' do
    it 'raises an error if not given a block' do
      expect { r_half.read(Numo::SFloat.zeros(100).inplace, 100) }.to raise_error(/block/)
    end

    it 'can read zeros' do
      result = r_half.read(Numo::SFloat.zeros(100).inplace, 100) { |s| Numo::SFloat.zeros(s) }
      expect(result.length).to eq(100)
      expect(result.abs.max).to eq(0)
    end

    it 'can read ones' do
      result = r_half.read(Numo::SFloat.zeros(100).inplace, 100) { |s| Numo::SFloat.ones(s) }
      expect(result.length).to eq(100)
      expect((result - 1).abs.max).to be_between(1e-30, 0.5)
      expect(result.sum / result.length - 1).to be_between(-1e-2, 1e-2)
    end

    pending 'at end of stream'
  end
end
