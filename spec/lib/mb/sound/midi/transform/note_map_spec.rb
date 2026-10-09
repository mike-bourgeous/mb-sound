RSpec.describe(MB::Sound::MIDI::Transform::NoteMap, :midi_transforms) do
  # A new stream each call (a stream's events can be read once).
  def chordy
    list_stream(
      ev.note_on(60, 0.9, time: 0r), ev.note_on(64, 0.3, time: 0r), ev.cc(1, 0.5, time: 1/20r),
      ev.poly_pressure(64, 0.5, time: 1/20r),
      ev.note_off(64, time: 1/10r), ev.note_off(60, time: 2/10r),
    )
  end

  describe 'Stream#select and #reject' do
    it 'keeps or drops whole notes, passing other events' do
      out = read_all(chordy.select { |e| e.velocity > 0.5 })
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:cc, 1, 1/20r], [:note_off, 60, 2/10r]])

      out = read_all(chordy.reject { |e| e.velocity > 0.5 })
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 64, 0r], [:cc, 1, 1/20r], [:poly_pressure, 64, 1/20r], [:note_off, 64, 1/10r]])
    end

    it 'filters by velocity with #velocities' do
      out = read_all(chordy.velocities(0.5..1))
      expect(ons(out).map { |e| e[1] }).to eq([60])
    end
  end

  describe 'Stream#map_notes' do
    it 'changes notes and their note-offs follow' do
      out = read_all(chordy.map_notes { |e| e.transpose(12).with_channel(2) })
      expect(out.map { |e| e.first(3) }).to eq([
        [:note_on, 72, 0r], [:note_on, 76, 0r], [:cc, 1, 1/20r], [:poly_pressure, 76, 1/20r], [:note_off, 76, 1/10r], [:note_off, 72, 2/10r],
      ])
      expect(read_events(chordy.map_notes { |e| e.with_channel(2) }).select(&:note?).map(&:channel).uniq).to eq([2])
    end

    it 'makes several notes, delays them, or drops them' do
      out = read_all(note_stream.map_notes { |e| [e, e.transpose(7).at(e.time + 1/20r)] })
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:note_on, 67, 1/20r], [:note_off, 60, 1/10r], [:note_off, 67, 3/20r]])
      expect(read_all(note_stream.map_notes { nil })).to eq([])
    end
  end

  describe 'Stream#transpose with a scale' do
    it 'moves notes by degrees and keeps note-offs matched' do
      out = read_all(chordy.transpose(2, scale: :minor, root: :a))
      expect(out.select { |e| e[0] == :note_on || e[0] == :note_off }.map { |e| e.first(2) }).to eq([[:note_on, 64], [:note_on, 67], [:note_off, 67], [:note_off, 64]])
    end

    it 'keeps the old semitone transpose without a scale' do
      expect(ons(read_all(note_stream.transpose(-1.oct))).map { |e| e[1] }).to eq([48])
      expect(ons(read_all(note_stream.transpose(0.5))).map { |e| e[1] }).to eq([60.5])
    end
  end

  describe 'Stream#snap' do
    it 'snaps notes to a scale' do
      s = -> { list_stream(*[61, 63, 66].flat_map.with_index { |n, i| [ev.note_on(n, time: i / 4r), ev.note_off(n, time: i / 4r + 1/8r)] }) }
      out = read_all(s.().snap(:minor, :a))
      expect(ons(out).map { |e| e[1] }).to eq([60, 62, 65])
      expect_balanced(out)
      expect(ons(read_all(s.().snap(:minor, :a, direction: :up))).map { |e| e[1] }).to eq([62, 64, 67])
    end
  end

  describe 'Stream#chord' do
    it 'adds named chords that end with the played note' do
      out = read_all(note_stream.chord(:min7))
      expect(out.map { |e| e.first(3) }).to eq([
        [:note_on, 60, 0r], [:note_on, 63, 0r], [:note_on, 67, 0r], [:note_on, 70, 0r],
        [:note_off, 60, 1/10r], [:note_off, 63, 1/10r], [:note_off, 67, 1/10r], [:note_off, 70, 1/10r],
      ])
    end

    it 'adds diatonic notes by scale degrees' do
      s = list_stream(*[60, 62].flat_map.with_index { |n, i| [ev.note_on(n, time: i / 4r), ev.note_off(n, time: i / 4r + 1/8r)] })
      out = read_all(s.chord(2, 4, scale: :major, root: :c))
      expect(ons(out).map { |e| e[1] }).to eq([60, 64, 67, 62, 65, 69])
    end

    it 'takes Intervals and scales added velocities' do
      out = read_all(note_stream.chord(-1.oct, velocity: 0.5))
      expect(ons(out)).to eq([[:note_on, 60, 0r, 1.0], [:note_on, 48, 0r, 0.5]])
    end

    it 'stays balanced when chord notes of different keys overlap' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_on(67, time: 1/10r), ev.note_off(60, time: 2/10r), ev.note_off(67, time: 3/10r))
      expect_balanced(read_all(s.chord(:fifth)))
      expect_balanced(read_all(s.chord(:fifth, overlap: :stack)), stack: true)
    end

    it 'raises for unknown chords' do
      expect { note_stream.chord(:nope) }.to raise_error(ArgumentError, /Unknown chord/)
    end
  end

  describe 'Stream#note_length' do
    it 'gives every note a fixed length' do
      s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 1r))
      out = read_all(s.note_length(1/4r))
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:note_off, 60, 1/4r]])
      expect(read_all(note_stream.len(1.n8)).map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:note_off, 60, 1/4r]])
    end
  end

  describe 'Stream#shift' do
    it 'delays every event' do
      out = read_all(chordy.shift(1/2r))
      expect(out.map { |e| e[2] }).to eq([1/2r, 1/2r, 11/20r, 11/20r, 6/10r, 7/10r])
    end
  end

  describe 'Stream#rechannel' do
    it 'moves every channel message' do
      out = read_events(chordy.rechannel(9))
      expect(out.map(&:channel).uniq).to eq([9])
      expect(out.first.bytes.bytes).to eq([0x99, 60, 114])
      expect(chordy.to_channel(3)).to be_a(MB::Sound::MIDI::Stream)
    end
  end

  describe 'Stream#vel and #velocity_curve with a Range' do
    it 'sets or maps velocities' do
      expect(ons(read_all(chordy.vel(0.5))).map(&:last)).to eq([0.5, 0.5])
      expect(ons(read_all(chordy.velocity_curve(0.5..1.0))).map(&:last)).to eq([0.95, 0.65])
    end
  end

  describe 'Stream#split and #merge' do
    it 'splits keys at a note and merges streams in time order' do
      lo, hi = chordy.split(MB::Sound::E4)
      expect(ons(read_all(lo)).map { |e| e[1] }).to eq([60])
      expect(ons(read_all(hi)).map { |e| e[1] }).to eq([64])

      a = note_stream(60, on: 0r, off: 1/2r)
      b = note_stream(67, on: 1/4r, off: 3/4r)
      out = read_all(a.merge(b, MB::Sound.seq(MB::Sound::C5).n4))
      expect(out.map { |e| e.first(3) }).to eq([
        [:note_on, 60, 0r], [:note_on, 72, 0r], [:note_on, 67, 1/4r], [:note_off, 60, 1/2r], [:note_off, 72, 1/2r], [:note_off, 67, 3/4r],
      ])
    end

    it 'works on Notes' do
      n = MB::Sound::Notes.new(chordy)
      lo, hi = n.split(64)
      expect(lo).to be_a(MB::Sound::Notes)
      expect(hi.sustain?).to eq(true)
      expect(n.merge(note_stream)).to be_a(MB::Sound::Notes)
    end
  end

  describe 'unattached chains (Transform::Spec)' do
    it 'apply to streams with #through, and print themselves' do
      fx = MB::Sound.echo(1/4r, 1, pitch: 12).chord(7.st)
      expect(fx.to_s).to eq('echo(1/4, 1, pitch: 12).chord(7 st)')
      out = read_all(note_stream.through(fx))
      expect(ons(out).map { |e| e[1] }).to eq([60, 67, 72, 79])
      expect(ons(read_all(note_stream.through { |s| s.transpose(1) })).map { |e| e[1] }).to eq([61])
    end
  end

  it 'mirrors transforms on Notes and Clips' do
    n = MB::Sound::Notes.new(note_stream, sustain: false).chord(:maj)
    expect(n).to be_a(MB::Sound::Notes)
    expect(n.sustain?).to eq(false)
    expect(MB::Sound.seq(MB::Sound::C4).chord(:maj)).to be_a(MB::Sound::MIDI::Stream)
    expect(MB::Sound::MIDI::Stream::CLIP_TRANSFORMS).not_to include(:select)
  end
end
