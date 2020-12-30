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

  pending '#process'
  pending '#weighted_process'
end
