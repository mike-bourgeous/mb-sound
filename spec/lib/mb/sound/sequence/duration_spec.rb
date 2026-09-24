RSpec.describe(MB::Sound::Sequence::Duration) do
  describe '.whole_notes' do
    it 'treats Integers as note divisions' do
      expect(described_class.whole_notes(4)).to eq(1/4r)
      expect(described_class.whole_notes(6)).to eq(1/6r)
    end

    it 'treats Rationals as fractions of a whole note' do
      expect(described_class.whole_notes(3/8r)).to eq(3/8r)
    end

    it 'converts Floats to exact Rationals' do
      expect(described_class.whole_notes(0.375)).to eq(3/8r)
    end

    it 'rejects zero, negative, and non-numeric durations' do
      [0, -4, 0r, -0.5, Float::INFINITY, '4', nil].each do |d|
        expect { described_class.whole_notes(d) }.to raise_error(ArgumentError), "expected #{d.inspect} to be rejected"
      end
    end
  end

  describe '.format' do
    it 'formats unit fractions as note divisions' do
      expect(described_class.format(1/16r)).to eq('n16')
      expect(described_class.format(3/8r)).to eq('3/8')
    end
  end
end
