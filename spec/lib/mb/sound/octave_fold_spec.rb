# The one core of every within(range) (note-within-1): notes and
# frequencies moved into a range by whole octaves, keeping pitch classes.
RSpec.describe(MB::Sound::OctaveFold, :aggregate_failures) do
  let(:s) { MB::Sound }

  def fold(range) = described_class[range]

  describe 'notes' do
    it 'keeps every pitch class and lands in the range, from any octave' do
      f = fold(s::E1..s::E2)
      (0..127).each do |n|
        to = f.note(n)
        expect(to % 12).to eq(n % 12), "note #{n} moved to #{to}"
        expect(to).to be_between(28, 40)
        expect(to).to be_a(Integer)
      end
    end

    it 'leaves notes in the range alone and moves others by the fewest octaves' do
      f = fold(s::C3..s::C5) # two octaves
      expect(f.note(50)).to eq(50)
      expect(f.note(70)).to eq(70)
      expect(f.note(30)).to eq(54) # up to the lowest octave that fits
      expect(f.note(90)).to eq(66) # down to the highest
      expect(f.note(84)).to eq(72) # C6 to C5, the top edge
      expect(f.note(36)).to eq(48) # C2 to C3, the bottom edge
    end

    it 'keeps both edges of an inclusive range and leaves out the top of an exclusive one' do
      expect(fold(s::E1..s::E2).note(40)).to eq(40)
      expect(fold(s::E1..s::E2).note(28)).to eq(28)
      expect(fold(s::E1..s::E2).note(52)).to eq(40)
      expect(fold(s::E1..s::E2).note(16)).to eq(28)
      expect(fold(s::E1...s::E2).note(40)).to eq(28)
      expect(fold(s::E1...s::E2).note(52)).to eq(28)
      expect(fold(28...40).note(39)).to eq(39)
    end

    it 'takes the octave nearest the middle of a range narrower than an octave, then clamps' do
      f = fold(s::E1..s::A1) # 28..33, middle 30.5
      expect(f.note(31)).to eq(31)
      expect(f.note(43)).to eq(31)
      expect(f.note(36)).to eq(33) # C2 (5.5 from the middle) beats C1 (6.5): clamped to A1
      expect(f.note(25)).to eq(28) # Cs1 (5.5 below) beats Cs2 (6.5 above): clamped to E1
      expect(fold(28...33).note(36)).to eq(32) # the last note of an exclusive range
      expect(fold(30..30).note(66)).to eq(30)
      # a tie goes to the lower octave: 24..30, middle 27; 21 and 33 are both 6 away
      expect(fold(24..30).note(33)).to eq(24)
    end

    it 'moves fractional and Rational notes exactly' do
      expect(fold(48..60).note(70.5)).to eq(58.5)
      expect(fold(48..60).note(Rational(141, 2))).to eq(Rational(117, 2))
    end

    it 'converts frequency ends through the tuning' do
      f = fold(60.hz..120.hz) # notes 34.5..46.5
      expect(f.note_bounds.map { |x| x.round(4) }).to eq([34.5064, 46.5064])
      expect(f.note(60)).to eq(36)
      expect(f.note(47)).to eq(35)
      expect(fold(s::E1..120.hz).note(64)).to eq(40)
    end
  end

  describe 'frequencies' do
    it 'moves frequencies by powers of two into the range, exactly' do
      f = fold(2.hz..8.hz)
      expect(f.hz(110)).to eq(110 / 16.0)
      expect(f.hz(0.5)).to eq(2.0)
      expect(f.hz(8.0)).to eq(8.0)
      expect(f.hz(8.000001)).to eq(4.0000005)
      expect(f.hz(1.99)).to eq(3.98)
      [1e-30, 1e-300, 3.3, 1e30, 1e300].each do |x|
        y = f.hz(x)
        expect(y).to be_between(2.0, 8.0)
        expect(Math.log2(y / x) % 1).to eq(0), "#{x} moved to #{y}"
      end
    end

    it 'keeps zero, signs, NaN, and infinities' do
      f = fold(2.hz..8.hz)
      expect(f.hz(0.0)).to eq(0.0)
      expect(f.hz(-110.0)).to eq(-110 / 16.0)
      expect(f.hz(Float::NAN)).to be_nan
      expect(f.hz(Float::INFINITY)).to eq(Float::INFINITY)
    end

    it 'folds narrow and exclusive frequency ranges like notes' do
      expect(fold(300.hz..400.hz).hz(500.0)).to eq(300.0) # 250 is nearer the middle than 500: clamped up
      expect(fold(300.hz..400.hz).hz(780.0)).to eq(390.0)
      expect(fold(2.hz...8.hz).hz(8.0)).to eq(4.0)
      expect(fold(2.hz...8.hz).hz(16.0)).to eq(4.0)
    end

    it 'gives the frequencies of the note fold for note ranges' do
      t = s.tuning
      f = fold(s::E1..s::E2)
      (20..100).each do |n|
        expect(t.number_of(f.hz(t.frequency_of(n))).round(9)).to eq(f.note(n))
      end
    end
  end

  describe '#value' do
    it 'keeps Notes as Notes and fixed frequencies as Pitches' do
      f = fold(s::E1..s::E2)
      expect(f.value(s::A4)).to be_a(s::Note)
      expect(f.value(s::A4).number).to eq(33)
      e2 = s::E2
      expect(f.value(e2)).to equal(e2)
      expect(f.value(440.hz).frequency).to eq(55.0)
      expect(f.value(nil)).to be_nil
      expect(f.value(64)).to eq(40)
    end

    it 'raises for drum names and changing pitches' do
      expect { fold(s::E1..s::E2).value(:kick) }.to raise_error(ArgumentError, /no pitch/)
    end
  end

  describe 'ranges' do
    it 'raises for things that are not ranges of notes or frequencies, naming the form' do
      expect { fold(s::E1) }.to raise_error(ArgumentError, /within\(E1\.\.E2\)/)
      expect { fold(s::E2..s::E1) }.to raise_error(ArgumentError, /low to high/)
      expect { fold(s::E1...s::E1) }.to raise_error(ArgumentError, /low to high/)
      expect { fold(s::E1..) }.to raise_error(ArgumentError, /both ends/)
      expect { fold(:a..:b) }.to raise_error(ArgumentError, /notes .* or frequencies/)
      expect { fold(0.hz..8.hz) }.to raise_error(ArgumentError, /above 0 Hz/)
    end

    it 'prints its range as Ruby' do
      expect(fold(s::E1..s::E2).to_s).to eq('E1..E2')
      expect(fold(2.hz...8.hz).to_s).to eq('2.hz...8.hz')
      expect(fold(28..40).to_s).to eq('28..40')
    end
  end

  describe 'Pitch#within' do
    it 'moves Notes, fixed pitches, and voice pitches' do
      expect(s::A4.within(s::E1..s::E2).to_s).to eq('A1')
      expect(s::Fs4.within(s::E1..s::E2).to_s).to eq('Fs1')
      expect(440.hz.within(2.hz..8.hz).frequency).to eq(6.875)
      expect(s::C4.within(60.hz..120.hz).to_s).to eq('C2')
      v = s.seq(s::A4).n4.loop.notes.hz.within(s::E1..s::E2)
      expect(v).to be_a(s::Pitch)
      expect(v.freq.sample(800)[-1]).to be_within(1e-3).of(55.0)
    end
  end
end
