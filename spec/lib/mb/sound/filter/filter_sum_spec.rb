RSpec.describe(MB::Sound::Filter::FilterSum) do
  pending '#process'
  pending '#response'

  describe '#rate' do
    it 'returns the first valid rate in the filter list' do
      c = MB::Sound::Filter::FilterSum.new(
        MB::Sound::Filter::Biquad.new(1, 0, 0, 0, 0),
        100.hz.at_rate(800).lowpass,
        100.hz.at_rate(1200).lowpass
      )

      expect(c.rate).to eq(800)
    end

    it 'raises an error if none of the filters return a sample rate' do
      c = MB::Sound::Filter::FilterSum.new(
        MB::Sound::Filter::Biquad.new(1, 0, 0, 0, 0),
        MB::Sound::Filter::Gain.new(1)
      )

      expect { c.rate }.to raise_error(NotImplementedError)
    end
  end
end
