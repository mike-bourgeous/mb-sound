RSpec.describe(MB::Sound::GraphNode::IfftSynth) do
  it 'can be constructed' do
    expect { MB::Sound::GraphNode::IfftSynth.new(data: Numo::SFloat[0, 1, 0, 0]) }.not_to raise_error
  end

  describe '#sample' do
    it 'can synthesize a sine wave at fundamental' do
      d = Numo::SComplex.zeros(401)
      d[1] = -1i

      n = MB::Sound::GraphNode::IfftSynth.new(data: d)

      expect(n.sample(800)).to all_be_within(1e-6).of_array(60.hz.sine.at(1).sample(800))
    end

    it 'can synthesize a sine wave in a different bin' do
      d = Numo::SComplex.zeros(401)
      d[2] = -1i

      n = MB::Sound::GraphNode::IfftSynth.new(data: d)

      expect(n.sample(800)).to all_be_within(1e-6).of_array(120.hz.sine.at(1).sample(800))
    end
  end
end
