RSpec.describe(MB::Sound::GraphNode::DataShuffler) do
  describe '#sample' do
    # 1 in length! (factorial) chance of random failure.  Length of 10 is ~1 in 3.6M
    let(:length) { 15 }
    let(:input) { (1..length).to_a }
    let(:ds) { MB::Sound::GraphNode::DataShuffler.new(input.to_a.map { |v| Numo::SFloat[v] }) }

    it 'randomizes data order' do
      r1 = ds.sample(input.length)
      expect(r1).to match_array(input)
      expect(r1).not_to eq(input)
      expect(r1.sort).to eq(input)
    end

    it 'repeats the array entirely before shuffling again' do
      r2 = ds.sample(input.length * 3)
      expect(r2).not_to eq(input * 3)
      expect(r2).to match_array(input * 3)
    end
  end
end
