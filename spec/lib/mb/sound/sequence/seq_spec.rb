RSpec.describe(MB::Sound::Sequence::Seq) do
  def times(clip)
    clip.events.map { |e| [e.value, e.start, e.length] }
  end

  describe 'note length methods' do
    it 'sets the length of a single note' do
      expect(times(MB::Sound::C4.n8)).to eq([[60, 0, 1/8r]])
      expect(times(MB::Sound::C4.n6)).to eq([[60, 0, 1/6r]])
      expect(times(MB::Sound::C4.n(5))).to eq([[60, 0, 1/5r]])
      expect(times(MB::Sound::C4.len(3/16r))).to eq([[60, 0, 3/16r]])
      expect(times(MB::Sound::C4.beats(1.5))).to eq([[60, 0, 3/8r]])
    end

    it 'defines n1 through n8 and larger common divisions' do
      [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32, 64, 128].each do |k|
        expect(MB::Sound::C4.public_send("n#{k}").length).to eq(Rational(1, k))
      end
    end

    it 'has long names' do
      expect(MB::Sound::C4.whole.length).to eq(1)
      expect(MB::Sound::C4.half.length).to eq(1/2r)
      expect(MB::Sound::C4.quarter.length).to eq(1/4r)
      expect(MB::Sound::C4.eighth.length).to eq(1/8r)
      expect(MB::Sound::C4.sixteenth.length).to eq(1/16r)
      expect(MB::Sound::C4.thirty_second.length).to eq(1/32r)
    end

    it 'supports dotted, double-dotted, and triplet modifiers' do
      expect(MB::Sound::C4.n4.d.length).to eq(3/8r)
      expect(MB::Sound::C4.n4.dotted.length).to eq(3/8r)
      expect(MB::Sound::C4.n4.dd.length).to eq(7/16r)
      expect(MB::Sound::C4.n4.t.length).to eq(MB::Sound::C4.n6.length)
      expect(MB::Sound::C4.quarter.triplet.length).to eq(1/6r)
    end

    it 'defaults a Note without a length to a quarter note' do
      expect(MB::Sound.seq(MB::Sound::C4).length).to eq(1/4r)
    end
  end

  describe 'default lengths' do
    it 'sets only the steps without a length' do
      s = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4, MB::Sound::G4.n4).n8
      expect(times(s)).to eq([[60, 0, 1/8r], [64, 1/8r, 1/8r], [67, 1/4r, 1/4r]])
      expect(s.length).to eq(1/2r)
    end

    it 'applies to rests' do
      s = MB::Sound.seq(MB::Sound::C4, nil, MB::Sound.rest, MB::Sound::E4).n16
      expect(times(s)).to eq([[60, 0, 1/16r], [64, 3/16r, 1/16r]])
    end

    it 'keeps unset lengths through transpose and vel' do
      s = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).transpose(12).vel(0.5).n8
      expect(times(s)).to eq([[72, 0, 1/8r], [76, 1/8r, 1/8r]])
      expect(s.events.map(&:velocity)).to eq([0.5, 0.5])
    end

    it 'resolves unset steps to quarter notes when stretched' do
      expect(MB::Sound.seq(MB::Sound::C4, MB::Sound::E4.n8).d.length).to eq(9/16r)
    end
  end

  it 'plays nested clips in place' do
    s = MB::Sound.seq(MB::Sound::C4.n8, MB::Sound.seq(MB::Sound::E4, MB::Sound::G4).n16, MB::Sound::C5.n8)
    expect(times(s)).to eq([[60, 0, 1/8r], [64, 1/8r, 1/16r], [67, 3/16r, 1/16r], [72, 1/4r, 1/8r]])
  end

  it 'accepts numbers as values' do
    expect(MB::Sound.seq(400, 800).n8.events.map(&:value)).to eq([400, 800])
  end

  it 'rejects unsupported items' do
    expect { MB::Sound.seq('C4') }.to raise_error(ArgumentError, /Cannot sequence/)
  end

  it 'can be displayed' do
    expect(MB::Sound.seq(MB::Sound::C4, nil).n8.inspect).to eq('#<Seq(n4: 60@0+n8)>')
  end
end
