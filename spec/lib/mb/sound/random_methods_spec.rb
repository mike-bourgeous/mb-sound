RSpec.describe(MB::Sound::RandomMethods) do
  describe '#seed' do
    it 'restarts the root generator so sub-seeds repeat' do
      MB::Sound.seed(42)
      a = Array.new(3) { MB::Sound.next_seed }
      MB::Sound.seed(42)
      b = Array.new(3) { MB::Sound.next_seed }

      expect(a).to eq(b)
      expect(a.uniq.length).to eq(3)
    end

    it 'gives different sub-seeds for different root seeds' do
      MB::Sound.seed(1)
      a = MB::Sound.next_seed
      MB::Sound.seed(2)
      expect(MB::Sound.next_seed).not_to eq(a)
    end

    it 'returns the seed, or the current seed without an argument' do
      expect(MB::Sound.seed(17)).to eq(17)
      expect(MB::Sound.seed).to eq(17)
      expect(MB::Sound.random_seed).to eq(17)
    end

    it 'rejects non-integers' do
      expect { MB::Sound.seed('x') }.to raise_error(ArgumentError)
    end
  end

  describe '#next_seed' do
    it 'returns non-negative Integers' do
      expect(Array.new(10) { MB::Sound.next_seed }).to all(be_a(Integer).and(be >= 0))
    end
  end

  describe '#root_rng' do
    it 'is a Random' do
      expect(MB::Sound.root_rng).to be_a(Random)
    end
  end
end
