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

  describe '#response_hz' do
    it 'calls #respone with angular frequency' do
      f = MB::Sound::Filter.new
      expect(f).to receive(:response).with(be_within(0.0001).of(Math::PI / 2)).and_return(1+1i)
      expect(f).to receive(:rate).and_return(48000)
      allow(f).to receive(:response_hz).and_call_original
      expect(f.response_hz(12000)).to eq(1+1i)
    end
  end

  pending '#frequency_response'
end
