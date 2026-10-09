RSpec.describe(MB::Sound::MIDI::Transform::Arp, :midi_transforms) do
  # 120 BPM: a 16th note is 1/8 s
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }

  # Keys held together from +on+ to +off+ seconds.
  def held(*notes, on: 0r, off: 1r, velocity: 0.8)
    list_stream(*notes.flat_map { |n| [ev.note_on(n, velocity, time: on), ev.note_off(n, time: off)] })
  end

  def arp_notes(stream, seconds: 2, **options)
    ons(read_all(stream, seconds: seconds, **options)).map { |e| [e[1], e[2]] }
  end

  it 'plays held keys upward on the 16th grid with half-step gates' do
    out = read_all(held(64, 60, 67, off: 3/4r).arp(:up, 16, transport: transport))
    expect(out.map { |e| e.first(3) }).to eq([
      [:note_on, 60, 0r], [:note_off, 60, 1/16r],
      [:note_on, 64, 1/8r], [:note_off, 64, 3/16r],
      [:note_on, 67, 1/4r], [:note_off, 67, 5/16r],
      [:note_on, 60, 3/8r], [:note_off, 60, 7/16r],
      [:note_on, 64, 1/2r], [:note_off, 64, 9/16r],
      [:note_on, 67, 5/8r], [:note_off, 67, 11/16r],
    ])
    expect_balanced(out)
  end

  describe 'modes' do
    def mode(m, octaves: 1, count: 8)
      arp_notes(held(60, 64, 67, off: 10r).arp(m, 16, octaves: octaves, transport: transport), seconds: count / 8r).map(&:first)
    end

    it 'plays every mode in its order' do
      expect(mode(:down)).to eq([67, 64, 60, 67, 64, 60, 67, 64])
      expect(mode(:updown)).to eq([60, 64, 67, 64, 60, 64, 67, 64])
      expect(mode(:downup)).to eq([67, 64, 60, 64, 67, 64, 60, 64])
      expect(mode(:up_down)).to eq([60, 64, 67, 67, 64, 60, 60, 64])
      expect(mode(:down_up)).to eq([67, 64, 60, 60, 64, 67, 67, 64])
      expect(mode(:converge, count: 4)).to eq([60, 67, 64, 60])
      expect(mode(:diverge, count: 4)).to eq([64, 67, 60, 64])
      expect(mode(:pinky, count: 4)).to eq([60, 67, 64, 67])
      expect(mode(:thumb, count: 4)).to eq([60, 64, 60, 67])
    end

    it 'plays in the order played with :played' do
      s = list_stream(ev.note_on(67, time: 0r), ev.note_on(60, time: 0r), ev.note_on(64, time: 0r), *[67, 60, 64].map { |n| ev.note_off(n, time: 5r) })
      expect(arp_notes(s.arp(:played, 16, transport: transport), seconds: 3/8r).map(&:first)).to eq([67, 60, 64])
    end

    it 'adds octaves' do
      expect(mode(:up, octaves: 2, count: 6)).to eq([60, 64, 67, 72, 76, 79])
    end

    it 'plays every key at once with :chord' do
      out = arp_notes(held(60, 64, off: 1/4r).arp(:chord, 8, transport: transport))
      expect(out).to eq([[60, 0r], [64, 0r]])
    end

    it 'picks repeatably from a seed with :random' do
      a = mode_random = arp_notes(held(60, 64, 67, 71, off: 2r).arp(:random, 16, seed: 3, transport: transport))
      b = arp_notes(held(60, 64, 67, 71, off: 2r).arp(:random, 16, seed: 3, transport: transport))
      expect(a).to eq(b)
      expect(a.map(&:first).uniq - [60, 64, 67, 71]).to eq([])
      expect(a.map(&:first).uniq.length).to be >= 3
      expect(mode_random.length).to eq(16)
    end

    it 'rejects unknown modes' do
      expect { held(60).arp(:sideways, 16) }.to raise_error(ArgumentError, /mode/)
    end
  end

  describe 'the clock' do
    it 'waits for the next grid step when a key comes between steps (grid start)' do
      out = arp_notes(held(60, on: 1/20r, off: 1/2r).arp(:up, 16, transport: transport))
      expect(out.map(&:last)).to eq([1/8r, 1/4r, 3/8r])
    end

    it 'starts on the key with start: :key (Juno-style)' do
      out = arp_notes(held(60, on: 1/20r, off: 1/2r).arp(:up, 16, start: :key, transport: transport))
      expect(out.map(&:last)).to eq([1/20r, 1/20r + 1/8r, 1/20r + 1/4r, 1/20r + 3/8r])
    end

    it 'follows the session timeline, so a graph started mid-bar stays on the grid' do
      a = held(60, off: 1r).arp(:up, 4, transport: transport)
      a.source.start_at(1/8r) # an eighth into the timeline: next quarter step in 1/8 whole note = 1/4 s
      expect(arp_notes(a).map(&:last)).to eq([1/4r, 3/4r])
    end

    it 're-phases on timeline jumps' do
      a = held(60, off: 10r).arp(:up, 4, transport: transport)
      r = a.reader
      first = r.next(1/2r) # steps at 0
      a.source.start_at(1/8r) # jump: the timeline is now 1/8 whole note in at stream time 1/2
      rest = r.next(1)
      times = (first + rest).select(&:note_on?).map(&:time)
      expect(times).to eq([0r, 1/2r + 1/4r, 1/2r + 3/4r])
    end

    it 'follows tempo changes' do
      a = held(60, off: 10r).arp(:up, 16, transport: transport)
      r = a.reader
      t1 = r.next(1/4r).select(&:note_on?).map(&:time)
      transport.bpm = 60
      t2 = r.next(1/2r).select(&:note_on?).map(&:time)
      expect(t1).to eq([0r, 1/8r])
      expect(t2).to eq([1/4r, 1/2r])
    end

    it 'swings every other step' do
      out = arp_notes(held(60, off: 1/2r).arp(:up, 16, swing: 0.75, transport: transport))
      expect(out.map(&:last)).to eq([0r, 3/16r, 1/4r, 7/16r])
    end

    it 'gives readers of any buffer size the same events' do
      make = -> { held(60, 64, 67, on: 1/30r, off: 1r).arp(:updown, 1.n16.t, octaves: 2, gate: 0.8, transport: transport) }
      expect(read_all(make.(), seconds: 2, chunk: 128/48000r)).to eq(read_all(make.(), seconds: 2))
    end
  end

  describe 'pattern changes' do
    it 'keeps counting when keys are added and starts over after silence' do
      s = list_stream(
        ev.note_on(60, time: 0r), ev.note_on(64, time: 1/8r), ev.note_off(60, time: 1/2r), ev.note_off(64, time: 1/2r),
        ev.note_on(67, time: 1r), ev.note_off(67, time: 1r + 1/4r),
      )
      out = arp_notes(s.arp(:up, 16, transport: transport))
      expect(out).to eq([[60, 0r], [64, 1/8r], [60, 1/4r], [64, 3/8r], [67, 1r], [67, 9/8r]])
    end

    it 'keeps playing released keys with latch: true until a new chord' do
      s = list_stream(
        ev.note_on(60, time: 0r), ev.note_on(64, time: 0r), ev.note_off(60, time: 1/8r), ev.note_off(64, time: 1/8r),
        ev.note_on(67, time: 1r), ev.note_off(67, time: 1r + 1/16r),
      )
      out = arp_notes(s.arp(:up, 8, latch: true, transport: transport), seconds: 3/2r)
      expect(out.first(5)).to eq([[60, 0r], [64, 1/4r], [60, 1/2r], [64, 3/4r], [67, 1r]])
      expect(out[5..].map(&:first).uniq).to eq([67])
    end

    it 'stops when the input ends, even latched, and ends balanced' do
      a = held(60, 64, off: 1/4r).arp(:up, 16, latch: true, transport: transport)
      out = read_all(a, seconds: 3)
      expect_balanced(out)
      expect(a.ended?).to eq(true)
    end
  end

  describe 'notes' do
    it 'sets lengths with gate:' do
      out = read_all(held(60, off: 1/4r).arp(:up, 16, gate: 1.5, transport: transport))
      expect(out.map { |e| e.first(3) }).to eq([
        [:note_on, 60, 0r], [:note_off, 60, 1/8r], [:note_on, 60, 1/8r], [:note_off, 60, 1/8r + 3/16r],
      ])
      expect_balanced(out)
    end

    it 'sets velocities from the keys, a number, or accents' do
      expect(ons(read_all(held(60, off: 1/4r).arp(:up, 16, transport: transport))).map(&:last)).to eq([0.8, 0.8])
      expect(ons(read_all(held(60, off: 1/4r).arp(:up, 16, velocity: 0.5, transport: transport))).map(&:last)).to eq([0.5, 0.5])
      expect(ons(read_all(held(60, off: 3/8r).arp(:up, 16, velocity: [1, 0.5], transport: transport))).map(&:last)).to eq([0.8, 0.4, 0.8])
    end

    it 'adds pitch offsets per step with steps:, in scale degrees' do
      out = arp_notes(held(57, off: 1/2r).arp(:up, 16, steps: [0, 2, 4, 1.oct], scale: :minor, root: :a, transport: transport))
      expect(out.map(&:first)).to eq([57, 60, 64, 69])
    end

    it 'steps octaves by scale degrees or Intervals with step:' do
      out = arp_notes(held(57, off: 1/2r).arp(:up, 16, octaves: 4, step: 2, scale: :minor, root: :a, transport: transport))
      expect(out.map(&:first)).to eq([57, 60, 64, 67])
    end

    it 'passes other events and consumes the played notes' do
      s = list_stream(ev.note_on(60, time: 0r), ev.cc(1, 0.5, time: 1/100r), ev.note_off(60, time: 1/10r))
      out = read_all(s.arp(:up, 16, transport: transport))
      expect(out.map { |e| e.first(3) }).to eq([[:note_on, 60, 0r], [:cc, 1, 1/100r], [:note_off, 60, 1/16r]])
    end
  end

  it 'stays balanced through clip swaps and jumps' do
    a = MB::Sound.seq(MB::Sound::C4.n2, MB::Sound::E4.n2).loop
    b = MB::Sound.seq(MB::Sound::G4.n4)
    stream = a.stream(transport: transport)
    arp = stream.arp(:up, 16, octaves: 2, transport: transport)
    r = arp.reader
    list = r.next(0.7r)
    stream.source.swap_clip(b, time: 3/8r)
    list += r.next(3)
    expect_balanced(list)
    expect(arp.ended?).to eq(true)
  end

  it 'arpeggiates clips and live Notes' do
    clip = MB::Sound.seq(MB::Sound::A3.n2) & MB::Sound.seq(MB::Sound::C4.n2)
    expect(clip.arp(:up, 8)).to be_a(MB::Sound::MIDI::Stream)
    n = MB::Sound::Notes.new(held(60, 64)).arp(:down, 16)
    expect(n).to be_a(MB::Sound::Notes)
    expect(n.to_s).to include('arp(:down, n16)')
  end
end
