# This is the C extension from ext/mb/sound/fast_resample/
RSpec.describe(MB::Sound::FastResample, :aggregate_failures) do
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
      expect { MB::Sound::FastResample.new(Float::NAN) }.to raise_error(ArgumentError, /ratio.*>= 1.256/)
    end
  end
end
