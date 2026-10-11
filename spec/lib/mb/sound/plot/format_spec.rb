RSpec.describe(MB::Sound::Plot::Format) do
  describe '.nice_step' do
    it 'picks 1, 2, or 5 times a power of ten' do
      expect(described_class.nice_step(1, 5)).to eq(0.2)
      expect(described_class.nice_step(100, 5)).to eq(20)
      expect(described_class.nice_step(7, 2)).to eq(5)
      expect(described_class.nice_step(0.003, 3)).to be_within(1e-15).of(0.001)
      expect(described_class.nice_step(0, 5)).to eq(1)
    end
  end

  describe '.steps' do
    it 'lists multiples of the step inside the range, rounded' do
      expect(described_class.steps(-0.95, 0.95, 0.5)).to eq([-0.5, 0.0, 0.5])
      expect(described_class.steps(0, 0.3, 0.1)).to eq([0.0, 0.1, 0.2, 0.3])
    end
  end

  describe '.labels' do
    it 'shares decimals across labels and never prints negative zero' do
      expect(described_class.labels([-0.5, 0.0, 0.5], 0.5)).to eq(['-0.5', '0.0', '0.5'])
      expect(described_class.labels([-1e-17, 1.0], 1)).to eq(['0', '1'])
      expect(described_class.labels([0, 2.5, 5], 2.5)).to eq(['0.0', '2.5', '5.0'])
    end

    it 'adds SI prefixes' do
      expect(described_class.labels([0, 5000, 10000], 5000, si: true)).to eq(['0', '5k', '10k'])
      expect(described_class.labels([0.001, 0.002], 0.001, si: true)).to eq(['1m', '2m'])
      expect(described_class.labels([0.001, 0.002], 0.001, si: :up)).to eq(['0.001', '0.002'])
    end
  end

  it 'formats single values' do
    expect(described_class.value(0.000123456)).to eq('0.000123')
    expect(described_class.value(1234567)).to eq('1.23e6')
    expect(described_class.value(-3, unit: 'dB')).to eq('-3 dB')
  end
end
