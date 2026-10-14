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

    it 'repeats its order for the same seed, drawn from MB::Sound.seed by default' do
      make = ->(**kw) { MB::Sound::GraphNode::DataShuffler.new(input.map { |v| Numo::SFloat[v] }, **kw).sample(input.length * 3).to_a }
      expect(make.(seed: 5)).to eq(make.(seed: 5))
      expect(make.(seed: 5)).not_to eq(make.(seed: 6))

      MB::Sound.seed(3)
      a = make.()
      MB::Sound.seed(3)
      expect(make.()).to eq(a)
    end
  end
end
