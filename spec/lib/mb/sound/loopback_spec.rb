RSpec.describe(MB::Sound::Loopback) do
  let(:lo) { MB::Sound::Loopback.new(channels: 3, buffer_size: 123) }

  it 'returns all zeros if nothing has been written' do
    5.times do
      expect(lo.read).to eq([Numo::SFloat.zeros(123)] * 3)
    end
  end

  it 'returns data in the order it was written' do
    5.times do |t|
      lo.write(
        [
          Numo::SFloat.zeros(123).fill(t + 1),
          Numo::SFloat.zeros(123).fill(t + 2),
          Numo::SFloat.zeros(123).fill(t + 3)
        ]
      )
    end

    5.times do |t|
      expected = [
        Numo::SFloat.zeros(123).fill(t + 1),
        Numo::SFloat.zeros(123).fill(t + 2),
        Numo::SFloat.zeros(123).fill(t + 3)
      ]

      expect(lo.read(123)).to eq(expected)
    end

    expect(lo.read).to eq([Numo::SFloat.zeros(123)] * 3)
  end

  describe '#read' do
    it 'raises an error if given the wrong number of frames to read' do
      expect { lo.read(321) }.to raise_error(/buffer size/)
    end
  end

  describe '#write' do
    it 'raises an error if given the wrong number of channels' do
      expect { lo.write([Numo::SFloat.zeros(123)]) }.to raise_error(/Channel count/)
    end

    it 'raises an error if given the wrong buffer size' do
      expect {
        lo.write(
          [
            Numo::SFloat.zeros(123),
            Numo::SFloat.zeros(123),
            Numo::SFloat.zeros(124),
          ]
        )
      }.to raise_error(/Buffer size/)
    end
  end
end
