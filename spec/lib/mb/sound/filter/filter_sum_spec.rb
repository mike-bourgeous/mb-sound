RSpec.describe(MB::Sound::Filter::FilterSum) do
  describe '#initialize' do
    it 'raises an error if filters have different sample rates' do
      a = 15.hz.at_rate(32170).lowpass
      b = 25.hz.at_rate(45678).lowpass
      expect { MB::Sound::Filter::FilterSum.new(a, b) }.to raise_error(/rate.*45678.*32170/)
    end
  end

  pending
end
