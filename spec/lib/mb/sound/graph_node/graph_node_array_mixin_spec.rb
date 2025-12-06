RSpec.describe(MB::Sound::GraphNode::GraphNodeArrayMixin) do
  # More tests in the GraphNodeInput spec
  it 'adds the as_input method to Arrays' do
    expect([]).to respond_to(:as_input)
  end

  describe '#as_input' do
    it 'raises an error if the array is empty' do
      expect { [].as_input }.to raise_error(/GraphNodes/)
    end

    it 'raises an error if any elements are not graph nodes' do
      expect { [1.constant, 2].as_input }.to raise_error(/GraphNodes/)
    end

    it 'produces a readable input given an array of nodes' do
      expect([1.constant].as_input.read(3)).to eq([Numo::SFloat.ones(3)])
      expect([-1.constant, -2.constant].as_input.read(3)).to eq([Numo::SFloat[-1,-1,-1], Numo::SFloat[-2,-2,-2]])
    end
  end
end
