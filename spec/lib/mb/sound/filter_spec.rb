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

  context 'implementations' do
    ObjectSpace.each_object.select { |o| o.is_a?(Class) && o.ancestors.include?(MB::Sound::Filter) }.each do |f_cl|
      next if f_cl == MB::Sound::Filter

      example "#{f_cl.name} implements #sample_rate" do
        expect(f_cl.public_instance_methods).to include(:sample_rate)
      end
    end
  end
end
