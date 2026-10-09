RSpec.describe(MB::Sound::MIDI::Transform::Echo, :midi_transforms) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:one_note) { note_stream }

  it 'repeats a note after each delay, rising in pitch and fading' do
    out = ons(read_all(one_note.echo(1/4r, 3, pitch: 7.st, velocity: 0.5)))
    expect(out).to eq([
      [:note_on, 60, 0r, 1.0],
      [:note_on, 67, 1/4r, 0.5],
      [:note_on, 74, 1/2r, 0.25],
      [:note_on, 81, 3/4r, 0.125],
    ])
  end

  it 'gives echoes the length of the played note by default' do
    out = read_all(one_note.echo(1/4r, 2, pitch: 12))
    expect(out.map { |e| e.first(3) }).to eq([
      [:note_on, 60, 0r], [:note_off, 60, 1/10r],
      [:note_on, 72, 1/4r], [:note_off, 72, 1/4r + 1/10r],
      [:note_on, 84, 1/2r], [:note_off, 84, 1/2r + 1/10r],
    ])
  end

  it 'gives echoes a fixed gate (a fraction of the delay, or a Length) with gate:' do
    s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 3r))
    out = read_all(s.echo(1/4r, 2, pitch: 1, gate: 0.5))
    expect(out.map { |e| e.first(3) }).to eq([
      [:note_on, 60, 0r], [:note_on, 61, 1/4r], [:note_off, 61, 3/8r],
      [:note_on, 62, 1/2r], [:note_off, 62, 5/8r], [:note_off, 60, 3r],
    ])

    s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 3r))
    out = read_all(s.echo(1/4r, 1, gate: 50.ms))
    expect(out.map { |e| e.first(3) }).to include([:note_off, 60, 1/4r + 1/20r])
  end

  it 'follows the tempo for Duration delays' do
    fast = ons(read_all(one_note.echo(1.n16, 2, transport: transport)))
    expect(fast.map { |e| e[2] }).to eq([0r, 1/8r, 1/4r])

    transport.bpm = 60
    slow = ons(read_all(note_stream.echo(1.n16, 2, transport: transport)))
    expect(slow.map { |e| e[2] }).to eq([0r, 1/4r, 1/2r])
  end

  describe 'pitch steps (scale degrees)' do
    it 'climbs a scale in degrees with scale: and root:' do
      s = note_stream(57)
      out = ons(read_all(s.echo(1/8r, 7, pitch: 2, scale: :minor, root: :a)))
      expect(out.map { |e| e[1] }).to eq([57, 60, 64, 67, 71, 74, 77, 81])
    end

    it 'takes a Scale object' do
      s = note_stream(57)
      out = ons(read_all(s.echo(1/8r, 3, pitch: 2, scale: MB::Sound.scale(:minor, :a))))
      expect(out.map { |e| e[1] }).to eq([57, 60, 64, 67])
    end

    it 'counts plain numbers as semitones without a scale (chromatic degrees)' do
      out = ons(read_all(one_note.echo(1/8r, 2, pitch: 2)))
      expect(out.map { |e| e[1] }).to eq([60, 62, 64])
    end

    it 'adds Intervals exactly in any scale' do
      s = note_stream(57)
      out = ons(read_all(s.echo(1/8r, 2, pitch: [1.oct, 2], scale: :minor, root: :a)))
      expect(out.map { |e| e[1] }).to eq([57, 69, 72])
    end

    it 'keeps a note between scale notes the same distance above its scale note' do
      s = note_stream(61) # C# in A minor: C + 1
      out = ons(read_all(s.echo(1/8r, 2, pitch: 1, scale: :minor, root: :a)))
      expect(out.map { |e| e[1] }).to eq([61, 63, 65])
    end

    it 'falls with negative steps' do
      s = note_stream(62)
      out = ons(read_all(s.echo(1/8r, 3, pitch: -1, scale: :dorian, root: :d)))
      expect(out.map { |e| e[1] }).to eq([62, 60, 59, 57])
    end

    it 'cycles through an Array of pitch steps' do
      out = ons(read_all(one_note.echo(1/8r, 6, pitch: [4, 3, 5])))
      expect(out.map { |e| e[1] }).to eq([60, 64, 67, 72, 76, 79, 84])
    end

    it 'raises for fractional degrees of a non-chromatic scale' do
      expect { one_note.echo(1/8r, 2, pitch: 1.5, scale: :major) }.to raise_error(ArgumentError, /whole/)
    end
  end

  it 'lets a block change or skip each echo' do
    out = ons(read_all(one_note.echo(1/8r, 4) { |e, i| i == 2 ? nil : e.transpose(i.odd? ? 12 : 0) }))
    expect(out.map { |e| [e[1], e[2]] }).to eq([[60, 0r], [72, 1/8r], [72, 3/8r], [60, 1/2r]])
  end

  it 'stops at the velocity floor and the MIDI note range' do
    quiet = ons(read_all(one_note.echo(1/8r, 20, velocity: 0.1)))
    expect(quiet.length).to eq(3) # 1, 0.1, 0.01 (>= 1/127), then 0.001

    high = ons(read_all(note_stream.echo(1/8r, 20, pitch: 1.oct)))
    expect(high.map { |e| e[1] }).to eq([60, 72, 84, 96, 108, 120])
  end

  it 'leaves out the played notes with dry: false' do
    out = read_all(one_note.echo(1/4r, 2, dry: false))
    expect(out.map { |e| e.first(3) }).to eq([
      [:note_on, 60, 1/4r], [:note_off, 60, 1/4r + 1/10r],
      [:note_on, 60, 1/2r], [:note_off, 60, 1/2r + 1/10r],
    ])
  end

  it 'passes other events through in time order' do
    s = list_stream(ev.cc(1, 0.5, time: 0r), ev.note_on(60, time: 1/10r), ev.bend(0.5, time: 2/10r), ev.note_off(60, time: 3/10r))
    out = read_all(s.echo(1/4r, 1))
    expect(out.map { |e| [e[0], e[2]] }).to eq([
      [:cc, 0r], [:note_on, 1/10r], [:bend, 2/10r], [:note_off, 3/10r], [:note_on, 7/20r], [:note_off, 11/20r],
    ])
  end

  it 'gives readers of any buffer size the same events' do
    make = -> { list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 1/3r), ev.note_on(64, time: 1/2r), ev.note_off(64, time: 2/3r)) }
    whole = read_all(make.().echo(1.n16.t, 9, pitch: 2, velocity: 0.8, transport: transport), seconds: 4)
    chunked = read_all(make.().echo(1.n16.t, 9, pitch: 2, velocity: 0.8, transport: transport), seconds: 4, chunk: 128/48000r)
    expect(chunked).to eq(whole)
    expect(whole.length).to eq(40)
  end

  describe 'same-key overlaps (overlap:)' do
    let(:s) {
      list_stream(
        ev.note_on(60, time: 0r), ev.note_on(67, time: 1/10r),
        ev.note_off(60, time: 1r), ev.note_off(67, time: 3/2r),
      )
    }

    it 'retriggers by default: the newest note owns the key' do
      out = read_all(s.echo(1/5r, 4, pitch: [0, 7]))
      expect_balanced(out)
      expect(ons(out).length).to eq(10)
      expect(out.last.first(3)).to eq([:note_off, 81, 3/2r + 4/5r]) # 67's echoes: 67, 74, 74, 81
    end

    it 'stacks notes with overlap: :stack, each note-off ending one' do
      out = read_all(s.echo(1/5r, 4, pitch: [0, 7], overlap: :stack))
      expect_balanced(out, stack: true)
      expect(ons(out).length).to eq(10)
      expect(out.count { |e| e[0] == :note_off }).to eq(10)
      # 60 at 0 and its first echo at 1/5 overlap on one key
      expect(out.select { |e| e[1] == 60 }.first(3).map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:note_on, 60, 1/5r], [:note_off, 60, 1r]])
    end

    it 'rejects unknown overlap modes' do
      expect { s.echo(1/5r, 1, overlap: :nope) }.to raise_error(ArgumentError, /overlap/)
    end
  end

  it 'sends a zero-length note-off right after its note-on' do
    s = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 0r))
    out = read_all(s.echo(1/4r, 2))
    expect(out.map { |e| e.first(3) }).to eq([
      [:note_on, 60, 0r], [:note_off, 60, 0r],
      [:note_on, 60, 1/4r], [:note_off, 60, 1/4r],
      [:note_on, 60, 1/2r], [:note_off, 60, 1/2r],
    ])
  end

  it 'never sends an echo note-off before its note-on when the tempo changes' do
    s = note_stream(60, off: 1/100r)
    e = s.echo(1.n4, 3, pitch: 1, transport: transport)
    r = e.reader
    first = r.next(1/50r)
    transport.bpm = 480
    rest = r.next(10)
    expect_balanced(first + rest)
  end

  it 'releases echoes still held when the input ends' do
    s = list_stream(ev.note_on(60, time: 0r)) # never released
    e = s.echo(1/4r, 2)
    out = read_all(e, seconds: 2)
    expect_balanced(out)
    expect(e.ended?).to eq(true)
  end

  it 'waits for its queue before reporting the end, and extends music_end' do
    e = one_note.echo(1/4r, 3)
    r = e.reader
    r.next(1/2r)
    expect(one_note.source.ended?).to eq(true)
    expect(e.ended?).to eq(false)
    expect(e.music_end).to eq(1/10r + 3/4r)
    r.next(1)
    expect(e.ended?).to eq(true)
  end

  describe 'content jumps' do
    let(:s) { list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 1/10r), ev.note_on(64, time: 1r), ev.note_off(64, time: 11/10r)) }

    it 'lets queued echoes ring on by default (jump: :ring), like an audio delay' do
      e = s.echo(1/4r, 3)
      r = e.reader
      a = r.next(3/10r)
      s.seek(1) # E4 next
      b = r.next(2)
      notes = (a + b).select(&:note_on?).map { |x| [x.note, x.time] }
      expect(notes).to eq([[60, 0r], [60, 1/4r], [64, 3/10r], [60, 1/2r], [64, 11/20r], [60, 3/4r], [64, 4/5r], [64, 21/20r]])
      expect_balanced(a + b)
    end

    it 'closes notes that were held at a jump in ring mode' do
      held = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 2r))
      e = held.echo(1/4r, 2, pitch: 12)
      r = e.reader
      a = r.next(3/10r)
      held.seek(5) # past the end: the source sends a note-off for 60 at the jump
      b = r.next(3)
      expect_balanced(a + b)
    end

    it 'drops queued echoes and releases sounding notes with jump: :cut' do
      long = list_stream(ev.note_on(60, time: 0r), ev.note_off(60, time: 2r), ev.note_on(64, time: 3r), ev.note_off(64, time: 31/10r))
      e = long.echo(1/4r, 3, jump: :cut)
      r = e.reader
      a = r.next(3/10r) # 60's echo at 1/4 retriggered the held 60: one 60 sounding
      long.seek(3)
      b = r.next(2)
      expect_balanced(a + b)
      expect(b.select(&:note_off?).map { |x| [x.note, x.time] }).to eq([[60, 3/10r], [64, 4/10r], [64, 13/20r], [64, 9/10r], [64, 23/20r]])
    end

    it 'stays balanced through clip swaps, ringing echoes on' do
      a = MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n4.loop
      b = MB::Sound.seq(MB::Sound::G4.n2)
      clip_stream = a.stream(transport: transport)
      e = clip_stream.echo(1.n8, 4, pitch: 12, transport: transport)
      r = e.reader
      list = r.next(0.6r)
      clip_stream.source.swap_clip(b, time: 1/4r * 3 / 2)
      list += r.next(3)
      expect_balanced(list)
      expect(e.ended?).to eq(true)
      expect(list.select(&:note_on?).map(&:note)).to include(84, 91)
    end
  end

  describe 'with a Session' do
    it 'uses the session transport and is found as a timeline node' do
      session_transport = MB::Sound::Sequence::Transport.new(bpm: 60)
      output = MB::Sound::NullOutput.new(channels: 2, sleep: false)
      session = MB::Sound::Session.new(output: output, transport: session_transport, buffer_size: 800, realtime: false, master_gain: 1)
      s = note_stream(60, off: 1/20r)
      echo = s.echo(1.n16, 1)
      gate = MB::Sound::Notes.new(echo, sustain: false).gate
      session.add(gate)
      data = Array.new(60) { session.process_buffer[0].dup }.reduce(:concatenate)
      expect(echo.source.transport).to equal(session_transport)
      edges = data.to_a.each_with_index.select { |v, i| i > 0 && v != data[i - 1] }.map(&:last)
      expect(edges).to eq([2400, 12000, 14400]) # 1/16 at 60 BPM = 0.25 s
    ensure
      session&.close
    end
  end

  it 'names itself for graph views' do
    e = one_note.echo(3.n16, 4, pitch: 7.st, velocity: 0.7)
    expect(e.to_s).to eq('MIDI echo(3 × n16, 4, pitch: 7 st, velocity: 0.7)')
    expect(one_note.echo(1/4r, 2, pitch: 2, scale: :minor, root: :a).to_s).to eq('MIDI echo(1/4, 2, pitch: 2, scale: A4 minor)')
  end

  it 'rejects bad arguments' do
    expect { one_note.echo(1/4r, -1) }.to raise_error(ArgumentError, /count/)
    expect { one_note.echo(:x, 1) }.to raise_error(ArgumentError)
    expect { one_note.echo(1/4r, 1, scale: :nope) }.to raise_error(ArgumentError, /Unknown scale/)
    expect { one_note.echo(1/4r, 1, jump: :nope) }.to raise_error(ArgumentError, /jump/)
    expect { one_note.echo(1/4r, 1, gate: -1) }.to raise_error(ArgumentError, /gate/)
  end

  describe 'entry points' do
    it 'Notes#echo plays echoes on a mono voice and in a Synth' do
      n = MB::Sound::Notes.new(one_note).echo(1/4r, 2, pitch: 12)
      expect(n).to be_a(MB::Sound::Notes)
      expect(n.sustain?).to eq(true)
      syn = n.synth(voices: 4) { |v| v.hz.ramp * v.amp_env(0.001, 0.1, 0, 0.05) }
      peaks = 40.times.map { syn.sample(1200).abs.max }
      expect(peaks[0]).to be > 0.1
      expect(peaks[10..12].max).to be > 0.1 # the first echo at 0.25 s (buffer 10)
    end

    it 'Clip#echo returns a stream of the clip with echoes' do
      clip = MB::Sound.seq(MB::Sound::C4).n4
      s = clip.echo(1.n8, 2, pitch: 2, transport: transport)
      expect(s).to be_a(MB::Sound::MIDI::Stream)
      expect(ons(read_all(s, seconds: 2)).map { |e| [e[1], e[2]] }).to eq([[60, 0r], [62, 1/4r], [64, 1/2r]])
    end

    it 'Stream#synth plays a stream on voices' do
      syn = one_note.echo(1/4r, 1).synth(voices: 2) { |v| v.gate }
      expect(syn).to be_a(MB::Sound::Synth)
      expect(syn.sample(800).max).to eq(1)
    end
  end
end
