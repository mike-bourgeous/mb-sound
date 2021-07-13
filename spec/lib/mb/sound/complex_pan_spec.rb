RSpec.describe(MB::Sound::ComplexPan) do
  describe '.gains' do
    it 'returns linear gains for linear -6dB pan law' do
      expect(MB::Sound::ComplexPan.gains(-1, 0, 1)).to eq([1, 0])
      expect(MB::Sound::ComplexPan.gains(-0.5, 0, 1)).to eq([0.75, 0.25])
      expect(MB::Sound::ComplexPan.gains(0, 0, 1)).to eq([0.5, 0.5])
      expect(MB::Sound::ComplexPan.gains(0.5, 0, 1)).to eq([0.25, 0.75])
      expect(MB::Sound::ComplexPan.gains(1.0, 0, 1)).to eq([0, 1])
    end

    it 'takes center gain power into account' do
      expect(MB::Sound::ComplexPan.gains(-1, 0, 1).map(&:abs)).to eq([1, 0])
      expect(MB::Sound::ComplexPan.gains(1, 0, 1).map(&:abs)).to eq([0, 1])
      expect(MB::Sound::ComplexPan.gains(0, 0, 1).map(&:abs)).to eq([0.5, 0.5])
      expect(MB::Sound::ComplexPan.gains(0, 1, 1).map(&:abs)).to eq([0.5, 0.5])

      expect(MB::Sound::ComplexPan.gains(-1, 0, 0.5).map(&:abs)).to eq([1, 0])
      expect(MB::Sound::ComplexPan.gains(1, 0, 0.5).map(&:abs)).to eq([0, 1])
      expect(MB::Sound::ComplexPan.gains(0, 0, 0.5).map(&:abs)).to eq([0.5 ** 0.5, 0.5 ** 0.5])
      expect(MB::Sound::ComplexPan.gains(0, 1, 0.6).map(&:abs)).to eq([0.5 ** 0.6, 0.5 ** 0.6])
    end

    it 'returns expected phase differences' do
      l, r = MB::Sound::ComplexPan.gains(0, 0.01, 1)
      expect((l.arg - r.arg).abs).to eq(0.01)

      l, r = MB::Sound::ComplexPan.gains(0, 1, 1)
      expect((l.arg - r.arg).abs).to eq(1)

      l, r = MB::Sound::ComplexPan.gains(0, 2, 1)
      expect((l.arg - r.arg).abs).to eq(2)

      l, r = MB::Sound::ComplexPan.gains(0.5, 0.01, 1)
      expect((l.arg - r.arg).abs).to eq(0.01)

      l, r = MB::Sound::ComplexPan.gains(0.5, 1, 1)
      expect((l.arg - r.arg).abs).to eq(1)

      l, r = MB::Sound::ComplexPan.gains(0.5, 2, 1)
      expect((l.arg - r.arg).abs).to eq(2)
    end
  end
end
