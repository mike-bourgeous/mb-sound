RSpec.describe(MB::Sound::Interval) do
  describe 'Numeric methods' do
    it 'makes octaves, semitones, and cents with their aliases' do
      expect(2.octaves.to_semitones).to eq(24)
      expect(1.octave).to eq(12.st)
      expect(1.oct).to eq(1.octaves)
      expect(7.semitones).to eq(7.st)
      expect(7.semi).to eq(7.st)
      expect(1.semitone).to eq(1.st)
      expect(50.cents.to_semitones).to eq(Rational(1, 2))
      expect(1.cent.to_cents).to eq(1)
    end

    it 'keeps whole cents exact' do
      expect(1200.cents).to eq(1.oct)
      expect(1.oct + 50.cents).to eq(Rational(25, 2).st)
    end

    it 'accepts fractional values' do
      expect(0.5.oct.to_semitones).to eq(6.0)
      expect(12.5.cents.to_semitones).to be_within(1e-12).of(0.125)
    end
  end

  describe 'conversions' do
    it 'converts between units' do
      expect(7.st.to_octaves).to eq(Rational(7, 12))
      expect(3.oct.to_cents).to eq(3600)
      expect(0.25.st.to_octaves).to be_within(1e-12).of(0.25 / 12)
    end

    it 'gives the equal-tempered frequency ratio' do
      expect(1.oct.ratio).to eq(2.0)
      expect(-1.oct.ratio).to eq(0.5)
      expect(7.st.ratio).to be_within(1e-12).of(2 ** (7 / 12.0))
    end

    it 'converts plain numbers in the given unit with .semitones and .octaves' do
      expect(MB::Sound::Interval.semitones(5)).to eq(5)
      expect(MB::Sound::Interval.semitones(1.oct)).to eq(12)
      expect(MB::Sound::Interval.octaves(2)).to eq(2)
      expect(MB::Sound::Interval.octaves(6.st)).to eq(Rational(1, 2))
    end

    it 'rejects other values' do
      expect { MB::Sound::Interval.semitones('7') }.to raise_error(ArgumentError, /interval/)
      expect { MB::Sound::Interval.octaves(nil) }.to raise_error(ArgumentError, /octaves/)
      expect { MB::Sound::Interval.new(:x) }.to raise_error(ArgumentError, /number/)
    end
  end

  describe 'arithmetic' do
    it 'adds, subtracts, negates, and scales' do
      expect(1.oct + 7.st).to eq(19.st)
      expect(1.oct - 1.st).to eq(11.st)
      expect(-7.st).to eq(-7.semitones)
      expect(7.st * 2).to eq(14.st)
      expect(2 * 7.st).to eq(14.st)
      expect(1.oct / 4).to eq(3.st)
      expect(1.oct / 3.st).to eq(4)
      expect((-5.st).abs).to eq(5.st)
    end

    it 'refuses to mix intervals with plain numbers in sums' do
      expect { 1.oct + 2 }.to raise_error(ArgumentError, /interval/)
      expect { 1.oct * 2.st }.to raise_error(ArgumentError, /numbers/)
    end

    it 'compares and hashes by size' do
      expect(1.oct).to be > 11.st
      expect([7.st, 1.oct, 50.cents].sort).to eq([50.cents, 7.st, 1.oct])
      expect({ 1.oct => :a }[12.st]).to eq(:a)
      expect(0.st).to be_zero
      expect(1.oct <=> 12).to be_nil
    end
  end

  describe '#to_s' do
    it 'shows the unit the interval was made with' do
      expect(7.st.to_s).to eq('7 st')
      expect(2.oct.to_s).to eq('2 oct')
      expect(50.cents.to_s).to eq('50 cents')
      expect(0.5.oct.to_s).to eq('0.5 oct')
      expect((1.oct + 6.st).to_s).to eq('1.5 oct')
      expect(7.st.inspect).to include('7 st')
    end
  end

  describe 'transposing' do
    it 'transposes Notes and Pitches by intervals or semitones' do
      expect(MB::Sound::Note.new(60).transpose(7.st).number).to eq(67)
      expect(MB::Sound::Note.new(60).transpose(-1.oct).number).to eq(48)
      expect(MB::Sound::Note.new(60).transpose(5).number).to eq(65)
      expect(440.hz.transpose(1.oct).frequency).to be_within(1e-9).of(880)
      expect(440.hz.transpose(-12).frequency).to be_within(1e-9).of(220)
    end

    it 'transposes clips and seqs by intervals' do
      clip = MB::Sound.seq(MB::Sound::Note.new(60), MB::Sound::Note.new(64)).n8
      expect(clip.transpose(1.oct).events.map(&:value)).to eq([72, 76])
      expect(clip.transpose(12).events.map(&:value)).to eq([72, 76])
    end
  end
end
