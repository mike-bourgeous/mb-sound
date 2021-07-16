RSpec.describe(MB::Sound::ComplexPan) do
  let(:f45) { MB::Sound::ComplexPan.new }

  describe '#process' do
    it 'can process a single input' do
      expect(f45.process(1)).to eq([0.5 ** 0.75, 0.5 ** 0.75])
    end

    it 'can process Numo::SFloat' do
      data = Numo::SFloat[-1, 0, 1]
      expected = [Numo::SFloat[-0.5 ** 0.75, 0, 0.5 ** 0.75]] * 2
      expect(f45.process(data)).to eq(expected)
    end

    it 'can process a Numo::NArray' do
      data = Numo::SComplex[0.1+0.3i, 0, -1]
      expected = [
        Numo::SComplex[(0.3-0.1i) * 0.5 ** 0.75, 0, 1i * 0.5 ** 0.75],
        Numo::SComplex[(-0.3+0.1i) * 0.5 ** 0.75, 0, -1i * 0.5 ** 0.75]
      ]

      f45.phase = 180.degrees
      f45.reset

      expect(MB::M.round(f45.process(data), 6)).to eq(MB::M.round(expected, 6))
    end

    it 'smooths pan and phase' do
      data = Numo::SComplex.ones(4800)

      f45.reset(pan: -1, phase: 0)

      left, right = f45.process(data)
      diff = left.diff.abs + right.diff.abs
      expect(diff.max).to eq(0)

      f45.pan = 1
      f45.phase = Math::PI

      left, right = f45.process(data)
      diff = left.diff.abs + right.diff.abs
      expect(diff[0..1000].min).to be > 0
    end
  end

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
