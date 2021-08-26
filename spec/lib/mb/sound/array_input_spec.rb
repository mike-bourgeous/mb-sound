RSpec.describe(MB::Sound::ArrayInput) do
  describe '#read' do
    d1 = [
      {
        description: 'arrays',
        data: [
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 0],
          [0, -1, -2, -3, -4, -5, -6, -7, -8, -9],
        ],
      },
      {
        description: 'narrays',
        data: [
          Numo::SFloat[1, 2, 3, 4, 5, 6, 7, 8, 9, 0],
          Numo::SFloat[0, -1, -2, -3, -4, -5, -6, -7, -8, -9],
        ],
      },
    ]

    d1.each do |t|
      it "returns data from #{t[:description]}" do
        input = MB::Sound::ArrayInput.new(data: t[:data], rate: 48000)

        expect(input.read(2)).to eq([[1, 2], [0, -1]])
        expect(input.remaining).to eq(8)

        expect(input.read(3)).to eq([[3, 4, 5], [-2, -3, -4]])
        expect(input.remaining).to eq(5)

        expect(input.read(input.remaining)).to eq([[6, 7, 8, 9, 0], [-5, -6, -7, -8, -9]])
        expect(input.remaining).to eq(0)

        expect(input.read(5).map(&:length)).to eq([0, 0])
        expect(input.remaining).to eq(0)
      end
    end

    it 'pads shorter arrays' do
      data = [
        Numo::SFloat[1, 2, 3, 4, 5, 6, 7, 8, 9, 0],
        Numo::SFloat[0, -1],
        Numo::SFloat[],
      ]
      input = MB::Sound::ArrayInput.new(data: data, rate: 1)

      expect(input.read(6)).to eq([[1, 2, 3, 4, 5, 6], [0, -1, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
      expect(input.read(4)).to eq([[7, 8, 9, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
    end

    it 'prevents reading beyond the end' do
      data = [
        Numo::SFloat[1, 2, 3, 4]
      ]
      input = MB::Sound::ArrayInput.new(data: data, rate: 1)

      expect(input.read(1)).to eq([[1]])
      expect(input.read(12)).to eq([[2, 3, 4]])
      expect(input.read(5).map(&:length)).to eq([0])
    end
  end

  describe '#seek_set' do
    it 'can seek to an absolute position' do
      data = [
        Numo::SFloat[1, 2, 3, 4, 5, 6],
        Numo::SFloat[1, 2, 3, 4, 5, 6],
        Numo::SFloat[1, 2, 3, 4, 5, 6],
      ]
      input = MB::Sound::ArrayInput.new(data: data, rate: 1)

      expect(input.read(2)).to eq([[1, 2]] * 3)
      input.seek_set(1)
      expect(input.read(2)).to eq([[2, 3]] * 3)
      input.seek_set(5)
      expect(input.read(2)).to eq([[6]] * 3)
      input.seek_set(0)
      expect(input.read(2)).to eq([[1, 2]] * 3)
    end
  end

  describe '#seek_rel' do
    it 'can seek to a relative position' do
      data = [
        Numo::SFloat[1, 2, 3, 4, 5, 6],
        Numo::SFloat[1, 2, 3, 4, 5, 6],
        Numo::SFloat[1, 2, 3, 4, 5, 6],
      ]
      input = MB::Sound::ArrayInput.new(data: data, rate: 1)

      expect(input.read(2)).to eq([[1, 2]] * 3)
      input.seek_rel(1)
      expect(input.read(2)).to eq([[4, 5]] * 3)
      input.seek_rel(-2)
      expect(input.read(2)).to eq([[4, 5]] * 3)
      input.seek_rel(-1)
      input.seek_rel(1)
      input.seek_rel(-3)
      expect(input.read(2)).to eq([[3, 4]] * 3)
      input.seek_rel(-100)
      expect(input.read(2)).to eq([[1, 2]] * 3)
      input.seek_rel(100)
      expect(input.read(2).map(&:length)).to eq([0] * 3)
    end
  end

  describe 'accessors' do
    [
      { data: [[]], rate: 1, frames: 0 },
      { data: [[], []], rate: 2, frames: 0 },
      { data: [[1], [2, 3], [4, 5, 6]], rate: 3, frames: 3 },
    ].each do |t|
      context "with #{t}" do
        it 'will return the correct frame counts, sample rate, and number of channels' do
          input = MB::Sound::ArrayInput.new(data: t[:data], rate: t[:rate])
          expect(input.channels).to eq(t[:data].length)
          expect(input.rate).to eq(t[:rate])
          expect(input.frames).to eq(t[:frames])
        end
      end
    end
  end
end
