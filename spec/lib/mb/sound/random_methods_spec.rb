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

  describe '#with_seed' do
    it 'draws from the given seed inside the block' do
      a = MB::Sound.with_seed(5) { 3.times.map { MB::Sound.next_seed } }
      MB::Sound.next_seed
      b = MB::Sound.with_seed(5) { 3.times.map { MB::Sound.next_seed } }
      expect(a).to eq(b)
      expect(MB::Sound.with_seed(6) { MB::Sound.next_seed }).not_to eq(a[0])
    end

    it 'puts the previous root generator back with its state' do
      MB::Sound.seed(3)
      first = MB::Sound.next_seed
      MB::Sound.seed(3)
      MB::Sound.next_seed
      MB::Sound.with_seed(99) { MB::Sound.next_seed; expect(MB::Sound.random_seed).to eq(99) }
      expect(MB::Sound.random_seed).to eq(3)
      MB::Sound.seed(3)
      2.times { MB::Sound.next_seed }
      expected = MB::Sound.next_seed
      MB::Sound.seed(3)
      2.times { MB::Sound.next_seed }
      MB::Sound.with_seed(1) { 10.times { MB::Sound.next_seed } }
      expect(MB::Sound.next_seed).to eq(expected)
      expect(first).to be_a(Integer)
    end

    it 'restores after an exception and returns the block value' do
      MB::Sound.seed(4)
      expect { MB::Sound.with_seed(1) { raise 'x' } }.to raise_error('x')
      expect(MB::Sound.random_seed).to eq(4)
      expect(MB::Sound.with_seed(1) { :v }).to eq(:v)
    end

    it 'repeats Tone#rnd phases' do
      a = MB::Sound.with_seed(7) { 110.hz.saw.rnd }
      b = MB::Sound.with_seed(7) { 110.hz.saw.rnd }
      expect(a.seed).to eq(b.seed)
      expect(a.sample(100)).to eq(b.sample(100))
    end
  end
end
