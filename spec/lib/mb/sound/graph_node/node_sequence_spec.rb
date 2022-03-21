RSpec.describe(MB::Sound::GraphNode::NodeSequence) do
  it 'can be constructed by DSL' do
    # Tones read full buffers always
    seq = 0.hz.square.at(5).for(7.0 / 48000).and_then(0.hz.square.at(4).for(4.0 / 48000), Numo::SFloat[-6, -5, -4])
    expect(seq.sample(5)).to eq(Numo::SFloat[5, 5, 5, 5, 5])
    expect(seq.sample(5)).to eq(Numo::SFloat[5, 5, 5, 5, 5])
    expect(seq.sample(5)).to eq(Numo::SFloat[4, 4, 4, 4, 4])
    expect(seq.sample(5)).to eq(Numo::SFloat[-6, -5, -4, 0, 0])
    expect(seq.sample(5)).to eq(nil)
  end

  describe '#sample' do
    it 'returns nil after a single source has finished' do
      seq = MB::Sound::GraphNode::NodeSequence.new([MB::Sound::ArrayInput.new(data: [Numo::SFloat[1,2,3,4]])])
      expect(seq.sample(7)).to eq(Numo::SFloat[1,2,3,4,0,0,0])
      expect(seq.sample(7)).to eq(nil)
    end

    it 'returns data from each source in sequence' do
      seq = MB::Sound::GraphNode::NodeSequence.new([
        MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 2, 3, 4, 5, 6]]),
        MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, -2, -3]]),
        MB::Sound::ArrayInput.new(data: [Numo::SFloat[5, 10, 15, 20]])
      ])

      expect(seq.sample(4)).to eq(Numo::SFloat[1, 2, 3, 4])
      expect(seq.sample(4)).to eq(Numo::SFloat[5, 6, 0, 0])
      expect(seq.sample(4)).to eq(Numo::SFloat[-1, -2, -3, 0])
      expect(seq.sample(4)).to eq(Numo::SFloat[5, 10, 15, 20])
      expect(seq.sample(4)).to eq(nil)
    end
  end
end
