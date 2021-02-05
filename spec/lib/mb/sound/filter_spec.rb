RSpec.describe(MB::Sound::Filter) do
  describe '#double_process' do
    pending
  end

  describe '#chain' do
    it 'returns a filter chain that contains the two starting filters' do
      f1 = 123.hz.highpass
      f2 = 1000.hz.lowpass
      chain = f1.chain(f2)
      expect(chain).to be_a(MB::Sound::Filter::FilterChain)
      expect(chain.has_filter?(f1)).to eq(true)
      expect(chain.has_filter?(f2)).to eq(true)
    end
  end

  pending '#impulse_response'

  pending '#frequency_response'
end
