RSpec.describe(MB::Sound::MIDI::Transform) do
  let(:ev) { MB::Sound::MIDI::Event }

  # Events spaced 10 ms apart in the order given.
  def timeline(*events)
    events.each_with_index.map { |e, idx| e.at(Rational(idx, 100)) }
  end

  def stream(*events)
    MB::Sound::MIDI::Stream.new(MIDIListSource.new(timeline(*events)))
  end

  # All events of +stream+ as [type, note, time in hundredths].
  def summary(stream, seconds: 10)
    stream.reader.next(seconds).map { |e| [e.type, e.note, (e.time * 100).to_i] }
  end

  describe '#channel' do
    let(:s) { stream(ev.note_on(60, channel: 0), ev.note_on(61, channel: 1), ev.note_on(62, channel: 9), ev.parse([0xf8])) }

    it 'keeps events on one channel plus system events' do
      expect(s.channel(9).reader.next(1).map { |e| e.note || e.type }).to eq([62, :system])
    end

    it 'accepts Arrays and Ranges of channels' do
      a = s.channel([0, 9]).reader
      b = s.channel(0..1).reader
      expect(a.next(1).filter_map(&:note)).to eq([60, 62])
      expect(b.next(1).filter_map(&:note)).to eq([60, 61])
    end

    it 'rejects channels outside 0..15' do
      expect { s.channel(16) }.to raise_error(ArgumentError, /0 to 15/)
      expect { s.channel([]) }.to raise_error(ArgumentError)
    end

    it 'leaves the original stream unchanged' do
      a = s.reader
      s.channel(1).reader.next(1)
      expect(a.next(1).length).to eq(4)
    end

    it 'starts views made later at the slowest reader of the parent' do
      a = s.reader
      a.next(2/100r)
      expect(s.channel(9).reader.next(1).map { |e| e.note || e.type }).to eq([62, :system])
    end
  end

  describe '#transpose' do
    let(:s) { stream(ev.note_on(60), ev.poly_pressure(60, 0.5), ev.note_off(60), ev.cc(1, 1)) }

    it 'shifts notes and poly pressure by an Interval, rebuilding the bytes' do
      original = s.reader
      out = s.transpose(1.oct).reader.next(1)
      expect(out.map(&:note)).to eq([72, 72, 72, 1])
      expect(out[0].note).to be_a(Integer)
      expect(out[0].bytes).to eq([0x90, 72, 127].pack('C*'))
      expect(out[3]).to eq(original.next(1)[3])
    end

    it 'accepts plain semitones and chains' do
      expect(s.transpose(-5).transpose(7.st).reader.next(1).first.note).to eq(62)
    end

    it 'keeps notes between semitones without bytes' do
      e = s.transpose(50.cents).reader.next(1).first
      expect(e.note).to eq(60.5)
      expect(e.bytes).to eq(nil)
    end

    it 'transposes clip Pitches' do
      e = MB::Sound::MIDI::Stream.for(MB::Sound.seq(440.hz).n4).transpose(12).reader.next(1).first
      expect(e.note.frequency).to eq(880)
    end
  end

end
