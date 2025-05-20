RSpec.describe(MB::Sound::GraphNode::NodeSequence) do
  it 'can be constructed by DSL' do
    # Tones read full buffers always
    # TODO: prevent Tone from padding lengths when it's used in a sequence like this?
    seq = 0.hz.square.at(5).for(7.0 / 48000).and_then(0.hz.square.at(4).for(4.0 / 48000), Numo::SFloat[-6, -5, -4])
    expect(seq.sample(5)).to eq(Numo::SFloat[5, 5, 5, 5, 5])
    expect(seq.sample(5)).to eq(Numo::SFloat[5, 5, 5, 5, 5])
    expect(seq.sample(5)).to eq(Numo::SFloat[4, 4, 4, 4, 4])
    expect(seq.sample(5)).to eq(Numo::SFloat[-6, -5, -4])
    expect(seq.sample(5)).to eq(nil)
  end

  describe '#sample' do
    it 'returns nil after a solitary source has finished' do
      seq = MB::Sound::GraphNode::NodeSequence.new([MB::Sound::ArrayInput.new(data: [Numo::SFloat[1,2,3,4]])])
      expect(seq.sample(7)).to eq(Numo::SFloat[1,2,3,4])
      expect(seq.sample(7)).to eq(nil)
    end

    it 'returns data from each source in sequence' do
      seq = MB::Sound::GraphNode::NodeSequence.new([
        MB::Sound::ArrayInput.new(data: [Numo::SFloat[1, 2, 3, 4, 5, 6]]),
        MB::Sound::ArrayInput.new(data: [Numo::SFloat[-1, -2, -3]]),
        MB::Sound::ArrayInput.new(data: [Numo::SFloat[5, 10, 15, 20]])
      ])

      expect(seq.sample(4)).to eq(Numo::SFloat[1, 2, 3, 4])
      expect(seq.sample(4)).to eq(Numo::SFloat[5, 6, -1, -2])
      expect(seq.sample(4)).to eq(Numo::SFloat[-3, 5, 10, 15])
      expect(seq.sample(4)).to eq(Numo::SFloat[20])
      expect(seq.sample(4)).to eq(nil)
    end

    it 'does not zero pad sources that return short reads' do
      seq = 5.constant.for(3.0 / 48000).and_then(2.constant.for(7.0 / 48000), 1.constant.for(4.0 / 48000.0))
      expect(seq.sample(4)).to eq(Numo::SFloat[5, 5, 5, 2])
      expect(seq.sample(4)).to eq(Numo::SFloat[2, 2, 2, 2])
      expect(seq.sample(4)).to eq(Numo::SFloat[2, 2, 1, 1])
      expect(seq.sample(4)).to eq(Numo::SFloat[1, 1])
      expect(seq.sample(4)).to eq(nil)
    end

    it 'can return complex data' do
      seq = -0.5.constant.for(3.0 / 48000)
        .and_then((-1 + 1.5i).constant.for(4.0 / 48000))

      expect(seq.sample(2)).to be_a(Numo::SFloat).and eq(Numo::SFloat[-0.5, -0.5])
      expect(seq.sample(2)).to be_a(Numo::SComplex).and eq(Numo::SComplex[-0.5, -1+1.5i])
      expect(seq.sample(2)).to be_a(Numo::SComplex).and eq(Numo::SComplex[-1+1.5i, -1+1.5i])
      expect(seq.sample(2)).to be_a(Numo::SComplex).and eq(Numo::SComplex[-1+1.5i])
      expect(seq.sample(2)).to eq(nil)
    end
  end

  describe '#and_then' do
    it 'just adds another source to the sequence' do
      seq = MB::Sound::GraphNode::NodeSequence.new(3.constant.for(3.0 / 48000))
      expect(seq.sources.length).to eq(1)

      seq2 = seq.and_then(5.constant.for(2.0 / 48000))
      expect(seq2).to equal(seq)
      expect(seq.sources.length).to eq(2)

      expect(seq.sample(5)).to eq(Numo::SFloat[3, 3, 3, 5, 5])
    end

    it 'resumes sample output even if sources were previously exhausted' do
      seq = MB::Sound::GraphNode::NodeSequence.new(1.constant.for(2.0 / 48000))

      expect(seq.sample(3)).to eq(Numo::SFloat[1, 1])
      expect(seq.sample(3)).to eq(nil)

      seq.and_then(2.constant.for(1.0 / 48000))
      expect(seq.sample(3)).to eq(Numo::SFloat[2])
      expect(seq.sample(3)).to eq(nil)
    end
  end
end
