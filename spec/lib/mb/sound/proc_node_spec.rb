RSpec.describe(MB::Sound::ProcNode) do
  describe '#initialize' do
    it 'can include extra source nodes' do
      a = 1.constant.named('A')
      b = 2.constant.named('B')
      pn = MB::Sound::ProcNode.new(a, [b]) do |v|
        v
      end

      expect(pn.find_by_name('A')).to equal(a)
      expect(pn.find_by_name('B')).to equal(b)
    end
  end

  describe '#sample' do
    it 'calls the block given to the constructor' do
      p = ->(d) { d * 4 }
      pn = MB::Sound::ProcNode.new(1.constant, &p)

      expect(pn.sample(1)[0]).to eq(4)
    end
  end
end
