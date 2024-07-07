RSpec.describe(MB::Sound::Filter::FilterBank) do
  describe '.butterworth' do
    let(:freq_range) { 1000..2000 }
    let(:freq_ends) { [freq_range.first, freq_range.last] }
    let(:bank) { MB::Sound::Filter::FilterBank.butterworth(11, :lowpass, 5, 48000, freq_range) }

    it 'creates all Butterworth filters' do
      expect(bank.size).to eq(11)
      expect(bank.filters.all? { |f| f.is_a?(MB::Sound::Filter::Butterworth) }).to eq(true)
    end

    it 'creates a spread of frequencies' do
      expect(bank.first.center_frequency).to eq(freq_ends.first)
      expect(bank.last.center_frequency).to eq(freq_ends.last)
      expect(freq_ends.include?(bank[5].center_frequency)).to eq(false)
      expect(freq_range.cover?(bank[5].center_frequency)).to eq(true)
    end
  end

  describe '.cookbook' do
    let(:freq_range) { 1000..2000 }
    let(:freq_ends) { [freq_range.first, freq_range.last] }
    let(:bank) { MB::Sound::Filter::FilterBank.cookbook(10, :notch, 48000, freq_range, quality: 2.0) }

    it 'creates the expected count of Cookbook filters' do
      expect(bank.size).to eq(10)
      expect(bank.filters.all? { |f| f.is_a?(MB::Sound::Filter::Cookbook) }).to eq(true)
    end

    it 'creates a spread of frequencies' do
      expect(bank.first.center_frequency).to eq(freq_ends.first)
      expect(bank.last.center_frequency).to eq(freq_ends.last)
      expect(freq_ends.include?(bank[5].center_frequency)).to eq(false)
      expect(freq_range.cover?(bank[5].center_frequency)).to eq(true)
    end
  end

  describe '#reset' do
    pending 'can reset to a nonzero value'
  end

  describe '#rate' do
    it 'returns the first valid sample rate in the bank' do
      c = MB::Sound::Filter::FilterBank.new(3) do |idx|
        if idx == 0
          MB::Sound::Filter::Biquad.new(1, 0, 0, 0, 0)
        else
          (idx * 100).hz.at_rate(678 + idx - 1).lowpass
        end
      end

      expect(c.rate).to eq(678)
    end

    it 'raises an error if no filter in the bank has a valid sample rate' do
      c = MB::Sound::Filter::FilterBank.new(2) do
        MB::Sound::Filter::Biquad.new(1, 0, 0, 0, 0)
      end

      expect { c.rate }.to raise_error(NotImplementedError)
    end
  end

  pending '#process'
  pending '#weighted_process'
end
