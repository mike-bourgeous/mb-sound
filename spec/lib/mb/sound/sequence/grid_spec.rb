RSpec.describe(MB::Sound::Sequence::Grid) do
  describe '.parse' do
    it 'turns characters into steps' do
      s = described_class.parse(16, 'x.X?5', value: 40)
      expect(s.length).to eq(5/16r)
      expect(s.events.map { |e| [e.start, e.value, e.velocity.round(3), e.probability] }).to eq([
        [0, 40, 0.75, nil],
        [1/8r, 40, 1.0, nil],
        [3/16r, 40, 0.75, 0.5],
        [1/4r, 40, (5 / 9.0).round(3), nil],
      ])
    end

    it 'ignores bar lines and spaces' do
      expect(described_class.parse(16, 'x... | x...').length).to eq(1/2r)
    end

    it 'raises an error for unknown characters' do
      expect { described_class.parse(16, 'x-x') }.to raise_error(ArgumentError, /Unknown grid character "-"/)
    end
  end

  describe '.register' do
    after { described_class::SYMBOLS.delete('o') }

    it 'adds a new character' do
      described_class.register('o', velocity: 0.25)
      expect(described_class.parse(8, 'o').events[0].velocity).to eq(0.25)
    end
  end

  describe 'MB::Sound#grid' do
    it 'returns a Seq for a single pattern' do
      expect(MB::Sound.grid(8, 'x.x.')).to be_a(MB::Sound::Sequence::Seq)
    end

    it 'returns a Kit of rows with GM drum numbers' do
      kit = MB::Sound.grid(16, kick: 'x...', snare: '..x.', 50 => 'x', MB::Sound::C3 => 'x', custom: 'x', map: { custom: 70 })
      expect(kit[:kick].events[0].value).to eq(36)
      expect(kit[:snare].events[0].value).to eq(38)
      expect(kit[50].events[0].value).to eq(50)
      expect(kit.rows.values.map { |r| r.events[0].value }).to eq([36, 38, 50, 48, 70])
    end

    it 'loops rows independently' do
      kit = MB::Sound.grid(16, kick: 'x...', hat: 'x.x').loop
      expect(kit[:kick]).to be_looping
      expect(kit[:hat].length).to eq(3/16r)
    end

    it 'raises an error for unknown row names' do
      expect { MB::Sound.grid(16, bongo_drum: 'x') }.to raise_error(ArgumentError, /Unknown grid row/)
      expect { MB::Sound.grid(16, kick: 'x')[:snare] }.to raise_error(KeyError, /No row/)
    end
  end
end
