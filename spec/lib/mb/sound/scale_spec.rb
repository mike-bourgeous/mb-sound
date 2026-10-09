RSpec.describe(MB::Sound::Scale) do
  let(:am) { MB::Sound::Scale.new(:minor, root: MB::Sound::A3) }

  describe '.new' do
    it 'takes names, aliases, offsets, Intervals, and steps' do
      expect(MB::Sound::Scale.new(:major).offsets).to eq([0, 2, 4, 5, 7, 9, 11])
      expect(MB::Sound::Scale.new(:aeolian).offsets).to eq(MB::Sound::Scale.new(:minor).offsets)
      expect(MB::Sound::Scale.new([0, 7, 3, 15]).offsets).to eq([0, 3, 7])
      expect(MB::Sound::Scale.new([0, 204.cents, 7.st]).offsets).to eq([0, 51/25r, 7])
      expect(MB::Sound::Scale.steps([2, 2, 1, 2, 2, 2, 1]).offsets).to eq(MB::Sound::Scale::OFFSETS[:major])
    end

    it 'takes roots as Notes, pitch classes, note numbers, and names' do
      expect(am.root).to eq(57)
      expect(MB::Sound::Scale.new(:minor, root: :a).root).to eq(69)
      expect(MB::Sound::Scale.new(:minor, root: 9).root).to eq(69)
      expect(MB::Sound::Scale.new(:minor, root: 45).root).to eq(45)
      expect(MB::Sound::Scale.new(:minor, root: 'F#2').root).to eq(MB::Sound::Fs2.number)
      expect(MB::Sound::Scale.new(:minor, root: :Bb).root).to eq(70)
      expect(MB::Sound::Scale.new(:minor, root: :a).root_class).to eq(9)
    end

    it 'raises for unknown names and offsets without the root' do
      expect { MB::Sound::Scale.new(:nope) }.to raise_error(ArgumentError, /Unknown scale/)
      expect { MB::Sound::Scale.new([2, 4]) }.to raise_error(ArgumentError, /include 0/)
      expect { MB::Sound::Scale.new(:major, root: :h) }.to raise_error(ArgumentError, /root/)
    end
  end

  describe '.[]' do
    it 'returns the chromatic scale for nil and keeps Scales' do
      expect(MB::Sound::Scale[nil]).to equal(MB::Sound::Scale::CHROMATIC)
      expect(MB::Sound::Scale[am]).to equal(am)
      expect(MB::Sound::Scale[am, :c].root).to eq(60)
      expect(MB::Sound::Scale[:dorian, :d]).to eq(MB::Sound::Scale.new(:dorian, root: :d))
    end
  end

  describe '#note and #[]' do
    it 'counts degrees from the root note, across octaves' do
      expect((-2..8).map { |d| am.note(d) }).to eq([53, 55, 57, 59, 60, 62, 64, 65, 67, 69, 71])
      expect(am[2]).to be_a(MB::Sound::Note)
      expect(am[2].number).to eq(MB::Sound::C4.number)
      expect(am[0..2].map(&:name)).to eq(['A3', 'B3', 'C4'])
    end

    it 'works with the session tuning' do
      expect(am.hz(7)).to be_within(1e-9).of(440)
      MB::Sound.tuning(a4: 432)
      expect(am.hz(7)).to be_within(1e-9).of(432)
      expect(am[7].frequency).to be_within(1e-9).of(432)
    ensure
      MB::Sound.tuning.reset
    end
  end

  describe '#degree' do
    it 'returns the degree at or below a note and the distance from it' do
      expect(am.degree(57)).to eq([0, 0])
      expect(am.degree(60)).to eq([2, 0])
      expect(am.degree(61)).to eq([2, 1])
      expect(am.degree(55)).to eq([-1, 0])
      expect(am.degree(56)).to eq([-1, 1])
      expect(am.degree(69.5)).to eq([7, 0.5])
    end
  end

  describe '#transpose' do
    it 'moves notes by scale degrees' do
      expect(am.transpose(57, 2)).to eq(60)
      expect(am.transpose(60, 2)).to eq(64)
      expect(am.transpose(60, -3)).to eq(55)
      expect(am.transpose(MB::Sound::C4, 7)).to eq(72)
    end

    it 'keeps the distance of notes between scale notes' do
      expect(am.transpose(61, 1)).to eq(63)
      expect(am.transpose(60.25, 2)).to eq(64.25)
    end

    it 'adds semitones exactly for the chromatic scale' do
      c = MB::Sound::Scale::CHROMATIC
      expect(c.transpose(60, 7)).to eq(67)
      expect(c.transpose(60.5, -13)).to eq(47.5)
      expect(c.transpose(60r / 1, 1)).to be_a(Integer)
    end

    it 'raises for fractional degrees' do
      expect { am.transpose(60, 1.5) }.to raise_error(ArgumentError, /whole/)
    end
  end

  describe '#snap and #include?' do
    it 'snaps to the nearest scale note (ties down), or down or up' do
      expect(am.snap(61)).to eq(60)
      expect(am.snap(61, :up)).to eq(62)
      expect(am.snap(63)).to eq(62)
      expect(am.snap(63, :down)).to eq(62)
      expect(am.snap(63.6)).to eq(64)
      expect(am.snap(64)).to eq(64)
      expect(am.include?(64)).to eq(true)
      expect(am.include?(63)).to eq(false)
    end
  end

  describe '#chord, #notes, #mode' do
    it 'builds diatonic chords' do
      expect(am.chord(0)).to eq([57, 60, 64])
      expect(MB::Sound::Scale.new(:major, root: :c).chord(1, 4)).to eq([62, 65, 69, 72])
    end

    it 'lists the notes in a range' do
      expect(am.notes(MB::Sound::C4..MB::Sound::G4).map(&:name)).to eq(['C4', 'D4', 'E4', 'F4', 'G4'])
      expect(am.notes(61...67).map(&:number)).to eq([62, 64, 65])
    end

    it 'makes modes' do
      d = MB::Sound::Scale.new(:major, root: :c).mode(1)
      expect(d.offsets).to eq(MB::Sound::Scale::OFFSETS[:dorian])
      expect(d.root).to eq(62)
    end
  end

  describe 'other periods' do
    it 'repeats every period' do
      bp = MB::Sound::Scale.new([0, 3, 6], period: 1902.cents, root: 60)
      expect(bp.note(3)).to eq(60 + 951/50r)
      expect(bp.transpose(bp.note(1), 3)).to eq(bp.note(4))
    end
  end

  it 'is available as MB::Sound.scale' do
    expect(MB::Sound.scale(:minor, :a)[2].name).to eq('C5')
    expect(MB::Sound.scale).to equal(MB::Sound::Scale::CHROMATIC)
  end

  it 'has a readable to_s' do
    expect(am.to_s).to eq('A3 minor')
  end
end
