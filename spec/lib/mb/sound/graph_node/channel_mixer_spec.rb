RSpec.describe(MB::Sound::GraphNode::ChannelMixer, :aggregate_failures) do
  describe MB::Sound::GraphNode::ChannelMixer::Matrix do
    let(:identity3) { Matrix[[1, 0, 0], [0, 1, 0], [0, 0, 1]] }
    let(:matrix21) { Matrix[[0.5, 0.5]] }
    let(:matrix14) { Matrix[[1], [0.5], [-0.5], [-1]] }

    it 'returns inputs unmodified with an identity matrix' do
      mat = described_class.new([1.constant, -2.constant, 3.constant], matrix: identity3)
      expect(mat.outputs.map { |c| c.sample(1) }).to eq([Numo::SFloat[1], Numo::SFloat[-2], Numo::SFloat[3]])
    end

    it 'downmixes and upmixes' do
      expect(described_class.new([1.constant, -2.constant], matrix: matrix21).outputs.map { |c| c.sample(1) }).to eq([Numo::SFloat[-0.5]])
      expect(described_class.new(-2.constant, matrix: matrix14).outputs.map { |c| c.sample(1) }).to eq(
        [Numo::SFloat[-2], Numo::SFloat[-1], Numo::SFloat[1], Numo::SFloat[2]]
      )
    end

    it 'accepts Arrays, 2D NArrays, and bundles of inputs' do
      ins = MB::Sound.stereo(1.constant, 2.constant)
      [[[1, 1]], Numo::DFloat[[1, 1]], MB::Sound::ProcessingMatrix.new(Matrix[[1, 1]])].each do |m|
        expect(described_class.new(ins, matrix: m).outputs[0].sample(2).to_a).to eq([3, 3])
      end
    end

    it 'raises an error if the matrix does not have one column per input' do
      expect { described_class.new([1.constant], matrix: matrix21) }.to raise_error(ArgumentError, /column per input/)
    end

    it 'reads node gains every sample' do
      gain = MB::Sound::ArrayInput.new(data: [Numo::SFloat[0, 1, 2, 3]])
      mat = described_class.new([1.constant, 10.constant], matrix: [[gain, 1]])
      expect(mat.params.keys).to eq([:m1_1])
      expect(mat.outputs[0].sample(4).to_a).to eq([10, 11, 12, 13])
      expect(mat.gains[0][0].to_a).to eq([0, 1, 2, 3])
    end

    it 'ends when an input or gain node ends' do
      short = MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 2, 3]])
      mat = described_class.new([short, 1.constant], matrix: [[1, 1]])
      expect(mat.outputs[0].sample(5).to_a).to eq([2, 3, 4])
      expect(mat.outputs[0].sample(5)).to eq(nil)
    end

    it 'mixes every output from the same input samples' do
      lfo = 3.hz.lfo
      mat = described_class.new([lfo], matrix: [[1], [-1]])
      a, b = mat.outputs.map { |o| o.sample(800) }
      expect(a).to eq(-b)
    end

    it 'describes itself' do
      expect(described_class.new([1.constant, 2.constant], matrix: [[1, 0.5], [0.5, 1], [1, 1]]).to_s).to eq('Matrix 3x2')
    end

    context 'with complex gains' do
      let(:tone) { 1000.hz.sine }

      it 'turns real inputs into analytic signals and outputs real parts' do
        mat = described_class.new([tone], matrix: [[1i]])
        out = mat.outputs[0].multi_sample(800, 6)
        expect(out).to be_a(Numo::SFloat)

        # A 90 degree phase shift of the analytic signal: same level as the
        # input after the Hilbert filter settles
        expect(out[2400..].abs.max).to be_within(0.02).of(1)
      end

      it 'keeps complex inputs complex' do
        mat = described_class.new([1000.hz.complex_sine], matrix: [[1i]])
        out = mat.outputs[0].sample(800)
        expect(out).to be_a(Numo::SComplex)
        expect(out).to all_be_within(1e-5).of_array(1000.hz.complex_sine.sample(800) * 1i)
      end
    end

    it 'changes the sample rate of its inputs and gain nodes' do
      gain = 2.hz.lfo
      inp = 100.hz.sine
      mat = described_class.new([inp], matrix: [[gain]])
      mat.outputs[0].sample_rate = 96000
      expect(mat.sample_rate).to eq(96000)
      expect(inp.sample_rate).to eq(96000)
      expect(gain.sample_rate).to eq(96000)
    end
  end
end
