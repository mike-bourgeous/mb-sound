RSpec.describe(MB::Sound::GraphNode::MatrixMixer) do
  let(:identity3) {
    # 3x3 identity matrix
    Matrix[
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1],
    ]
  }
  let(:matrix3) {
    # 3x3 mixing matrix
    Matrix[
      [1, 0.5, -0.5],
      [-0.5, 1, 0.5],
      [0.5, -0.5, 1],
    ]
  }
  let(:matrix21) {
    # 1x2 downmix matrix
    Matrix[
      [0.5, 0.5],
    ]
  }
  let(:matrix14) {
    # 4x1 upmix matrix
    Matrix[
      [1],
      [0.5],
      [-0.5],
      [-1]
    ]
  }

  describe '#initialize' do
    it 'can create a mixer' do
      expect(MB::Sound::GraphNode::MatrixMixer.new(matrix: matrix3, inputs: [1.constant, 2.constant, -5.constant], sample_rate: 48000)).to be_a(MB::Sound::GraphNode::MatrixMixer)
    end

    it 'raises an error if the input list length does not match the number of columns' do
      expect {
        MB::Sound::GraphNode::MatrixMixer.new(matrix: matrix21, inputs: [1.constant], sample_rate: 48000)
      }.to raise_error(/number.*columns.*inputs/)
    end
  end

  describe MB::Sound::GraphNode::MatrixMixer::MatrixOutput do
    describe '#sample' do
      it 'returns inputs unmodified with an identity matrix' do
        mat = MB::Sound::GraphNode::MatrixMixer.new(matrix: identity3, inputs: [1.constant, -2.constant, 3.constant], sample_rate: 48000)
        expect(mat.outputs.map { |c| c.sample(1) }).to eq([
          Numo::SFloat[1],
          Numo::SFloat[-2],
          Numo::SFloat[3]
        ])
      end

      it 'returns the correct number of outputs for a downmix matrix' do
        mat = MB::Sound::GraphNode::MatrixMixer.new(matrix: matrix21, inputs: [1.constant, -2.constant], sample_rate: 48000)
        expect(mat.outputs.map { |c| c.sample(1) }).to eq([
          Numo::SFloat[-0.5],
        ])
      end

      it 'returns the correct number of outputs for an upmix matrix' do
        mat = MB::Sound::GraphNode::MatrixMixer.new(matrix: matrix14, inputs: [-2.constant], sample_rate: 48000)
        expect(mat.outputs.map { |c| c.sample(1) }).to eq([
          Numo::SFloat[-2],
          Numo::SFloat[-1],
          Numo::SFloat[1],
          Numo::SFloat[2],
        ])
      end
    end
  end
end
