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

  describe '#sustain' do
    it 'holds note-offs until the pedal lifts' do
      s = stream(ev.cc(64, 1), ev.note_on(60), ev.note_off(60), ev.note_on(64), ev.cc(64, 0), ev.note_off(64))
      expect(summary(s.sustain)).to eq([
        [:cc, 64, 0], [:note_on, 60, 1], [:note_on, 64, 3],
        [:cc, 64, 4], [:note_off, 60, 4], [:note_off, 64, 5],
      ])
    end

    it 'treats CC 64 values from 64 up as down' do
      s = stream(ev.cc_raw(64, 63), ev.note_on(60), ev.note_off(60), ev.cc_raw(64, 64), ev.note_on(62), ev.note_off(62), ev.cc_raw(64, 63))
      expect(summary(s.sustain).select { |t, _, _| t == :note_off }).to eq([[:note_off, 60, 2], [:note_off, 62, 6]])
    end

    it 'sends a held note-off before a repeated note' do
      s = stream(ev.cc(64, 1), ev.note_on(60, 0.5), ev.note_off(60), ev.note_on(60, 1.0), ev.cc(64, 0), ev.note_off(60))
      expect(summary(s.sustain)).to eq([
        [:cc, 64, 0], [:note_on, 60, 1], [:note_off, 60, 3], [:note_on, 60, 3], [:cc, 64, 4], [:note_off, 60, 5],
      ])
    end

    it 'keeps pedals per channel' do
      s = stream(ev.cc(64, 1, channel: 1), ev.note_on(60), ev.note_off(60), ev.note_on(60, channel: 1), ev.note_off(60, channel: 1), ev.cc(64, 0, channel: 1))
      offs = s.sustain.reader.next(1).select(&:note_off?).map { |e| [e.channel, (e.time * 100).to_i] }
      expect(offs).to eq([[0, 2], [1, 5]])
    end

    it 'holds only the notes sounding when sostenuto went down' do
      s = stream(
        ev.note_on(60), ev.cc(66, 1), ev.note_on(64), ev.note_off(60), ev.note_off(64), ev.cc(66, 0)
      )
      expect(summary(s.sustain)).to eq([
        [:note_on, 60, 0], [:cc, 66, 1], [:note_on, 64, 2], [:note_off, 64, 4], [:cc, 66, 5], [:note_off, 60, 5],
      ])
    end

    it 'keeps sostenuto notes held when the sustain pedal lifts, and sustain notes when sostenuto lifts' do
      s = stream(
        ev.note_on(60), ev.cc(66, 1), ev.note_off(60), # 60 held by sostenuto
        ev.cc(64, 1), ev.note_on(64), ev.note_off(64), # 64 held by sustain
        ev.cc(64, 0), # releases 64 only
        ev.cc(64, 1), ev.note_on(67), ev.note_off(67), # 67 held by sustain
        ev.cc(66, 0), # 60 stays held by the sustain pedal, like a piano's raised dampers
        ev.cc(64, 0), # releases 60 and 67
      )
      offs = summary(s.sustain).select { |t, _, _| t == :note_off }
      expect(offs).to eq([[:note_off, 64, 6], [:note_off, 60, 11], [:note_off, 67, 11]])
    end

    it 'catches notes held by the sustain pedal with sostenuto' do
      s = stream(ev.cc(64, 1), ev.note_on(60), ev.note_off(60), ev.cc(66, 1), ev.cc(64, 0), ev.cc(66, 0))
      expect(summary(s.sustain).select { |t, _, _| t == :note_off }).to eq([[:note_off, 60, 5]])
    end

    it 'scales note-on velocities while the soft pedal is down' do
      s = stream(ev.note_on(60, 1.0), ev.cc(67, 1), ev.note_on(62, 1.0), ev.note_on(64, 0.5), ev.cc(67, 0), ev.note_on(65, 1.0))
      a = s.sustain.reader
      b = s.sustain(soft: 0.5).reader
      expect(a.next(1).select(&:note_on?).map(&:velocity)).to eq([1.0, 0.7, 0.35, 1.0])
      expect(b.next(1).select(&:note_on?).map(&:velocity)).to eq([1.0, 0.5, 0.25, 1.0])
    end

    it 'releases held notes on all sound off and reset controllers' do
      s = stream(ev.cc(64, 1), ev.note_on(60), ev.note_off(60), ev.cc(120, 0), ev.note_on(62), ev.note_off(62), ev.cc(121, 0), ev.note_on(64), ev.note_off(64))
      offs = summary(s.sustain).select { |t, _, _| t == :note_off }
      # Reset controllers lifts the pedal, so 64 isn't held
      expect(offs).to eq([[:note_off, 60, 3], [:note_off, 62, 6], [:note_off, 64, 8]])
    end

    it 'lets go of held notes when the input ends' do
      s = stream(ev.cc(64, 1), ev.note_on(60), ev.note_off(60))
      view = s.sustain
      r = view.reader
      expect(r.next(1/100r).map(&:type)).to eq([:cc])
      out = r.next(1)
      expect(out.map(&:type)).to eq([:note_on, :note_off])
      expect(out.last.time).to eq(2/100r)
      expect(view.ended?).to eq(true)
    end

    it 'lets go of held notes and pedals when the content jumps' do
      s = stream(ev.cc(64, 1), ev.note_on(60), ev.note_off(60), ev.note_on(62), ev.note_off(62))
      r = s.sustain.reader
      expect(r.events(0, 3/100r).map(&:type)).to eq([:cc, :note_on])
      s.seek(3/100r) # into the middle of the file, after the pedal went down
      out = r.events(3/100r, 1)
      expect(out.map { |e| [e.type, e.note, e.time] }).to eq([
        [:note_off, 60, 3/100r], [:note_on, 62, 3/100r], [:note_off, 62, 4/100r],
      ])
    end

    it 'gives the note ends of MIDIFile#notes with a sustain pedal' do
      m = MB::Sound::MIDI::MIDIFile.new('spec/test_data/c2_sustain.mid')
      events = MB::Sound::MIDI::Stream.for('spec/test_data/c2_sustain.mid').sustain.reader.next(10)
      ends = events.select(&:note_off?).map { |e| [e.note, e.time.to_f.round(9)] }
      expected = m.notes.map { |n| [n[:number], n[:sustain_time].round(9)] }
      expect(ends).to eq(expected)
      expect(m.notes.map { |n| n[:sustain_time] }).not_to eq(m.notes.map { |n| n[:off_time] })
    end
  end

  describe '#velocity_curve' do
    let(:s) { stream(ev.note_on(60, 0.5), ev.note_off(60, 0.5), ev.note_on(62, 1.0)) }

    it 'is linear by default' do
      expect(s.velocity_curve.reader.next(1).map(&:velocity)).to eq([0.5, 0.5, 1.0])
    end

    it 'raises note-on velocities to an exponent' do
      out = s.velocity_curve(2).reader.next(1)
      expect(out.map(&:velocity)).to eq([0.25, 0.5, 1.0])
      expect(out[0].raw).to eq(32)
    end

    it 'accepts a block or Proc and clamps the result' do
      a = s.velocity_curve { |v| v * 3 - 1 }.reader
      b = s.velocity_curve(->(v) { v - 0.75 }).reader
      expect(a.next(1).select(&:note_on?).map(&:velocity)).to eq([0.5, 1.0])
      expect(b.next(1).select(&:note_on?).map(&:velocity)).to eq([0.0, 0.25])
    end

    it 'keeps notes on even at velocity 0' do
      e = s.velocity_curve { 0 }.reader.next(1).first
      expect(e).to have_attributes(type: :note_on, velocity: 0.0, raw: 1)
    end

    it 'rejects bad curves' do
      expect { s.velocity_curve(0) }.to raise_error(ArgumentError)
      expect { s.velocity_curve('x') }.to raise_error(ArgumentError)
    end
  end

  describe '#bend_range' do
    it 'sets the bend range of bend events' do
      s = stream(ev.bend(0.5), ev.bend(-1.0, channel: 3))
      a = s.bend_range(12.st).reader
      b = s.bend_range(1.oct).channel(3).reader
      expect(a.next(1).map(&:bend_semitones)).to eq([6.0, -12.0])
      expect(b.next(1).map(&:bend_semitones)).to eq([-12.0])
    end

    it 'lets RPN 0 change the range on its channel' do
      s = stream(ev.bend(1.0), ev.cc_raw(101, 0), ev.cc_raw(100, 0), ev.cc_raw(6, 24), ev.bend(1.0), ev.bend(1.0, channel: 1))
      expect(s.bend_range(12).reader.next(1).select(&:bend?).map(&:bend_semitones)).to eq([12.0, 24.0, 12.0])
    end

    it 'does not change the original stream' do
      s = stream(ev.bend(1.0))
      a = s.reader
      s.bend_range(7).reader.next(1)
      expect(a.next(1).first.bend_semitones).to eq(2.0)
    end
  end

  describe 'chains' do
    it 'combines transforms and runs each once for many readers' do
      src = MIDIListSource.new(timeline(ev.note_on(60, 0.5, channel: 2), ev.note_on(61, channel: 3), ev.note_off(60, channel: 2), ev.note_off(61, channel: 3)))
      view = MB::Sound::MIDI::Stream.new(src).channel(2).transpose(-12).velocity_curve(2)
      a = view.reader
      b = view.reader
      out = a.next(1)
      expect(out.map { |e| [e.type, e.note, e.velocity] }).to eq([[:note_on, 48, 0.25], [:note_off, 48, 64 / 127.0]])
      expect(b.next(1)).to eq(out)
      expect(src.reads).to eq(1)
    end
  end

  describe 'chased and first notes' do
    let(:clip) { MB::Sound.seq(MB::Sound::C4, MB::Sound.seq(MB::Sound::E4).vel(0.5)).n4.loop }
    let(:root) { MB::Sound::MIDI::Stream.new(MB::Sound::MIDI::ClipSource.new(clip, channel: 2)) }

    it 'passes through stateless transforms' do
      s = root.transpose(12).velocity_curve(2).sustain
      expect(s.first_note).to have_attributes(note: 72, velocity: 0.5625)
      r = s.reader
      r.next(1/10r)
      root.source.start_at(5/16r)
      expect(s.chase.event).to have_attributes(note: 76, velocity: 0.25)
      expect(s.chase.generation).to eq(s.generation)
    end

    it 'drops notes on other channels' do
      expect(root.channel(2).first_note.note).to eq(60)
      expect(root.channel(1).first_note).to eq(nil)
    end
  end

  it 'transposes glide events' do
    s = stream(ev.glide(48), ev.choke).transpose(12)
    expect(summary(s)).to eq([[:glide, 60, 0], [:choke, nil, 1]])
  end
end
