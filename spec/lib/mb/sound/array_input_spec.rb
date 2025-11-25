RSpec.describe(MB::Sound::ArrayInput, :aggregate_failures) do
  describe '#initialize' do
    let(:input) {
      MB::Sound::ArrayInput.new(data: data, sample_rate: 1)
    }

    it 'wraps a bare NArray as a single-channel array' do
      arr = MB::Sound::ArrayInput.new(data: Numo::SFloat[1, 2, 3, 4, 5])
      expect(arr.read(2)).to eq([Numo::SFloat[1, 2]])
      expect(arr.channels).to eq(1)
    end

    it 'raises an error if given no data' do
      expect { MB::Sound::ArrayInput.new(data: nil) }.to raise_error(/No data/)
      expect { MB::Sound::ArrayInput.new(data: []) }.to raise_error(/No data/)
    end

    shared_examples_for :type_promotion do
      it "returns the correct promoted type for the inputs" do
        result = input.read(data[0].length)
        expect(result).to all(be_a(expected_type))
        expect(result).to eq(data)
      end
    end

    context 'with a complex input' do
      let(:data) {
        [Numo::SComplex[1, 1i, -1i, -1]]
      }
      let(:expected_type) { Numo::SComplex }
    end

    context 'with a mix of float and complex' do
      context 'when complex is double precision' do
        let(:data) {
          [
            Numo::SFloat[1,2,3],
            Numo::SFloat[-3,2,-1],
            Numo::SComplex[5,-4i,3],
            Numo::DComplex[3,2,1i],
          ]
        }
        let(:expected_type) { Numo::DComplex }

        it_behaves_like :type_promotion
      end

      context 'when float is double precision' do
        let(:data) {
          [
            Numo::SFloat[-3,2,-1],
            Numo::DFloat[1,2,3],
            Numo::SComplex[5,-4i,3],
            Numo::SComplex[3,2,1i],
          ]
        }
        let(:expected_type) { Numo::DComplex }

        it_behaves_like :type_promotion
      end

      context 'when all are double precision' do
        let(:data) {
          [
            Numo::DFloat[1,2,3],
            Numo::DFloat[-3,2,-1],
            Numo::DComplex[5,-4i,3],
            Numo::DComplex[3,2,1i],
          ]
        }
        let(:expected_type) { Numo::DComplex }

        it_behaves_like :type_promotion
      end

      context 'when all are single precision' do
        let(:data) {
          [
            Numo::SFloat[1,2,3],
            Numo::SFloat[-3,2,-1],
            Numo::SComplex[5,-4i,3],
            Numo::SComplex[3,2,1i],
          ]
        }
        let(:expected_type) { Numo::SComplex }

        it_behaves_like :type_promotion
      end
    end

    context 'with a mix of precisions' do
      context 'with single and double precision real' do
        let(:data) {
          [Numo::SFloat[1,2,3], Numo::DFloat[3,-1,2]]
        }
        let(:expected_type) { Numo::DFloat }

        it_behaves_like :type_promotion
      end

      context 'with single and double precision complex' do
        let(:data) {
          [Numo::SComplex[3,2,1], Numo::DComplex[1,2,3]]
        }
        let(:expected_type) { Numo::DComplex }

        it_behaves_like :type_promotion
      end

      context 'with single precision and 32-bit ints' do
        let(:data) { [Numo::Int32[1,2,3], Numo::SFloat[3,2,1]] }
        let(:expected_type) { Numo::DFloat }

        it_behaves_like :type_promotion
      end
    end

    context 'with matching precisions' do
      context 'with single precision real' do
        let(:data) { [Numo::SFloat[1,2,3], Numo::SFloat[3,1,2]] }
        let(:expected_type) { Numo::SFloat }

        it_behaves_like :type_promotion
      end

      context 'with double precision real' do
        let(:data) { [Numo::DFloat[1,2,3], Numo::DFloat[3,1,2]] }
        let(:expected_type) { Numo::DFloat }

        it_behaves_like :type_promotion
      end

      context 'with 16-bit integers' do
        let(:data) { [Numo::Int16[1,2,3], Numo::Int16[3,1,2]] }
        let(:expected_type) { Numo::SFloat }

        it_behaves_like :type_promotion
      end

      context 'with 32-bit integers' do
        let(:data) { [Numo::Int32[1,2,3], Numo::Int32[3,1,2]] }
        let(:expected_type) { Numo::DFloat }

        it_behaves_like :type_promotion
      end

      context 'with 64-bit integers' do
        let(:data) { [Numo::Int64[1,2,3], Numo::Int64[3,1,2]] }
        let(:expected_type) { Numo::DFloat }

        it_behaves_like :type_promotion
      end

      context 'wtih single precision complex' do
        let(:data) { [Numo::SComplex[1,1i], Numo::SComplex[-1i,-1] ] }
        let(:expected_type) { Numo::SComplex }

        it_behaves_like :type_promotion
      end

      context 'wtih double precision complex' do
        let(:data) { [Numo::DComplex[1,1i], Numo::DComplex[-1i,-1] ] }
        let(:expected_type) { Numo::DComplex }

        it_behaves_like :type_promotion
      end
    end
  end

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
        input = MB::Sound::ArrayInput.new(data: t[:data], sample_rate: 48000)

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
      input = MB::Sound::ArrayInput.new(data: data, sample_rate: 1)

      expect(input.read(6)).to eq([[1, 2, 3, 4, 5, 6], [0, -1, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]])
      expect(input.read(4)).to eq([[7, 8, 9, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
    end

    it 'prevents reading beyond the end' do
      data = [
        Numo::SFloat[1, 2, 3, 4]
      ]
      input = MB::Sound::ArrayInput.new(data: data, sample_rate: 1)

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
      input = MB::Sound::ArrayInput.new(data: data, sample_rate: 1)

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
      input = MB::Sound::ArrayInput.new(data: data, sample_rate: 1)

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
      { data: [[]], sample_rate: 1, frames: 0 },
      { data: [[], []], sample_rate: 2, frames: 0 },
      { data: [[1], [2, 3], [4, 5, 6]], sample_rate: 3, frames: 3 },
    ].each do |t|
      context "with #{t}" do
        it 'will return the correct frame counts, sample rate, and number of channels' do
          input = MB::Sound::ArrayInput.new(data: t[:data], sample_rate: t[:sample_rate])
          expect(input.channels).to eq(t[:data].length)
          expect(input.sample_rate).to eq(t[:sample_rate])
          expect(input.frames).to eq(t[:frames])
        end
      end
    end
  end

  describe '#sample' do
    it 'returns the first channel data, without zero padding' do
      input = MB::Sound::ArrayInput.new(data: [[1, 2, 3, 4+4i], [4, 3, 2, 1]], sample_rate: 1)
      expect(input.sample(2)).to eq(Numo::DComplex[1, 2])
      expect(input.sample(3)).to eq(Numo::DComplex[3, 4+4i])
    end
  end

  describe '#progress' do
    it 'returns the percentage of playback progress' do
      input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(10)])
      expect(input.progress).to eq(0)

      input.read(5)
      expect(input.progress).to eq(50)
    end
  end

  describe '#elapsed' do
    it 'returns the time played in seconds' do
      input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(64000)], sample_rate: 32000)
      expect(input.elapsed).to eq(0)
      input.read(16000)
      expect(input.elapsed).to eq(0.5)
    end

    it 'supports different sample rates' do
      input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(96000)], sample_rate: 48000)
      expect(input.elapsed).to eq(0)
      input.read(24000)
      expect(input.elapsed).to eq(0.5)
    end
  end

  describe '#duration' do
    it 'returns the total length of data in seconds' do
      input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(64000)], sample_rate: 32000)
      expect(input.duration).to eq(2)
    end

    it 'supports different sample rates' do
      input = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(48000)], sample_rate: 48000)
      expect(input.duration).to eq(1)
    end
  end
end
