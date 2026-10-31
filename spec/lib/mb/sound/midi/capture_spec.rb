RSpec.describe(MB::Sound::MIDI::Capture) do
  let(:ev) { MB::Sound::MIDI::Event }

  def on(note, vel = 100, ch: 0)
    ev.parse([0x90 | ch, note, vel])
  end

  def off(note, ch: 0)
    ev.parse([0x80 | ch, note, 64])
  end

  def pedal(down, ch: 0)
    ev.parse([0xb0 | ch, 64, down ? 127 : 0])
  end

  def summary(clip)
    clip.events.map { |e| [e.start, e.length, e.value, e.velocity] }
  end

  it 'turns stamped events into a looping clip with exact Rational starts and lengths' do
    events = [
      [9 + 1/7r, on(60)], [9 + 3/7r, off(60)],
      [9 + 1/2r, on(64, 127)], [9 + 3/4r, off(64)],
    ]
    clip = MB::Sound::MIDI::Capture.clip(events, from: 9, length: 1)
    expect(clip.looping?).to eq(true)
    expect(clip.length).to eq(1r)
    expect(summary(clip)).to eq([[1/7r, 2/7r, 60, 100 / 127.0], [1/2r, 1/4r, 64, 1.0]])
    expect(clip.events.map(&:start)).to all(be_a(Rational))
    expect(clip.performed?).to eq(true)
  end

  it "keeps a loop in phase with the timeline when the window doesn't start on a multiple of its length" do
    g = MB::Sound::MIDI::Capture::GRACE
    events = [
      [1r, on(36)], [1 + 1/8r, off(36)],             # bar 2 (the window's first bar)
      [2 + 1/2r, on(38)], [2 + 5/8r, off(38)],       # bar 3
      [3 - g / 2, on(40)], [3 + 1/8r, off(40)],      # the next window's early downbeat: out
    ]
    clip = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2)
    expect(summary(clip).map { |s, l, n, _| [s, l, n] }).to eq([[1/2r, 1/8r, 38], [1r, 1/8r, 36]])
    # A launch-aligned loop: offsets into the window
    launch = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, align: :launch)
    expect(launch.align).to eq(:launch)
    expect(summary(launch).map { |s, _, n, _| [s, n] }).to eq([[0r, 36], [3/2r, 38]])
    expect { MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, align: :bar) }.to raise_error(ArgumentError, /alignment/)
    # Not a loop: offsets into the window
    once = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, loop: false)
    expect(summary(once).map { |s, _, n, _| [s, n] }).to eq([[0r, 36], [3/2r, 38]])
  end

  it 'wraps a downbeat played a little early to the end of the loop, and leaves the next downbeat out' do
    g = MB::Sound::MIDI::Capture::GRACE
    events = [
      [4 - g / 2, on(48)], [4 + 1/8r, off(48)],         # early downbeat: in
      [4 - 2 * g, on(50)], [4 - g, off(50)],            # earlier: before the window
      [6 - g / 2, on(52)], [6 + 1/8r, off(52)],         # the next downbeat: out
    ]
    clip = MB::Sound::MIDI::Capture.clip(events, from: 4, length: 2)
    expect(summary(clip)).to eq([[2 - g / 2, 1/8r + g / 2, 48, 100 / 127.0]])
  end

  it 'ends notes still held at the end of the window there, and ends a re-struck key at the new strike' do
    events = [
      [0r, on(60)], [1/4r, on(60)], [1/2r, off(60)],
      [3/4r, on(67)],
    ]
    clip = MB::Sound::MIDI::Capture.clip(events, from: 0, length: 1, grace: 0)
    expect(summary(clip).map { |s, l, n, _| [s, l, n] }).to eq([[0r, 1/4r, 60], [1/4r, 1/4r, 60], [3/4r, 1/4r, 67]])
  end

  it 'holds note-offs while the sustain pedal is down, unless sustain: false' do
    events = [
      [0r, on(60)], [1/8r, pedal(true)], [1/4r, off(60)], [1/2r, on(64)], [5/8r, off(64)], [3/4r, pedal(false)],
    ]
    held = MB::Sound::MIDI::Capture.clip(events, from: 0, length: 1, grace: 0)
    expect(summary(held).map { |s, l, n, _| [s, l, n] }).to eq([[0r, 3/4r, 60], [1/2r, 1/4r, 64]])

    dry = MB::Sound::MIDI::Capture.clip(events, from: 0, length: 1, grace: 0, sustain: false)
    expect(summary(dry).map { |s, l, n, _| [s, l, n] }).to eq([[0r, 1/4r, 60], [1/2r, 1/8r, 64]])
  end

  it 'keeps one channel with channel:, and ignores note-offs without note-ons' do
    events = [[0r, off(59)], [0r, on(60, ch: 0)], [0r, on(36, ch: 9)], [1/4r, off(60, ch: 0)], [1/4r, off(36, ch: 9)]]
    clip = MB::Sound::MIDI::Capture.clip(events, from: 0, length: 1, grace: 0, channel: 9)
    expect(summary(clip).map { |s, l, n, _| [s, l, n] }).to eq([[0r, 1/4r, 36]])
  end

  it 'refuses empty windows' do
    expect { MB::Sound::MIDI::Capture.clip([], from: 0, length: 0) }.to raise_error(ArgumentError, /positive/)
  end

  describe 'controller lanes (cc:, gen-midi-2)' do
    def cc(number, raw, ch: 0)
      ev.parse([0xb0 | ch, number, raw])
    end

    def bend(raw14)
      ev.parse([0xe0, raw14 & 0x7f, raw14 >> 7])
    end

    def lanes(clip)
      clip.controls.to_h { |l| [l.name, l.points.map { |p, v| [p, (v * 127).round] }] }
    end

    # Bar 2 of a 2-bar timeline loop (window 1...3): a CC 1 move before
    # the window (chased), moves inside it, the pedal, a bend, and a
    # bank select (skipped)
    let(:events) {
      [
        [1/2r, cc(1, 20)], [1/2r, pedal(true)], [3/4r, pedal(false)],
        [1r, on(60)], [1 + 1/4r, cc(1, 40)], [1 + 1/2r, off(60)], [1 + 1/2r, cc(0, 3)],
        [2r, pedal(true)], [2 + 1/4r, cc(74, 100)], [2 + 1/2r, bend(12288)], [2 + 3/4r, pedal(false)], [2 + 3/4r, cc(1, 90)],
      ]
    }

    it 'keeps notes only by default, and the same notes whatever it keeps' do
      plain = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2)
      expect(plain.controls).to eq([])
      [true, :steps, :fit, [1]].each do |opt|
        with = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: opt)
        expect(summary(with)).to eq(summary(plain)), opt.inspect
      end
      # (the pedal held from before the window doesn't hold the window's notes, with or without lanes)
      expect(summary(plain)).to eq([[1r, 1/2r, 60, 100 / 127.0]])
    end

    it 'keeps CCs, bend, and pressure at the notes\' clip positions with cc: true, chasing values from before the window and wrapping a timeline loop' do
      clip = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: true)
      g = MB::Sound::MIDI::Capture::GRACE
      # Positions are timeline phases (pos mod 2), like the notes: the
      # window's start (1 - grace) is phase 1 - grace, so 1's chased 20
      # lands there, and phase 0 gets what played at 2 (still 40)
      expect(lanes(clip)).to eq(
        cc1: [[0r, 40], [3/4r, 90], [1 - g, 20], [5/4r, 40]],
        cc74: [[1/4r, 100]],
        bend: [[1/2r, 64]],
      )
      expect(clip.controls.map(&:type)).to eq(%i[cc cc bend])
      expect(clip.control(:bend).points.first.last).to be_within(1e-3).of(0.5)
      # No pedal lane while the pedal holds notes; with sustain: false it is a lane
      expect(clip.control(64)).to be_nil
      dry = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: true, sustain: false)
      expect(lanes(dry)[:cc64]).to eq([[0r, 127], [3/4r, 0], [1 - g, 0]])

      # A launch-aligned loop: offsets into the window, the chased value at 0
      launch = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: true, align: :launch)
      expect(lanes(launch)[:cc1]).to eq([[0r, 20], [1/4r, 40], [7/4r, 90], [2 - g, 20]])
      expect(lanes(launch)[:cc1].length).to eq(4)

      # Some lanes, fitted lanes, and mistakes
      expect(lanes(MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: [74, :bend])).keys).to eq(%i[cc74 bend])
      expect(MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: :fit).controls.map(&:name)).to eq(%i[cc1 cc74 bend])
      expect { MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: :split) }.to raise_error(ArgumentError, /cc: is false, true/)
    end

    it 'splits a clip into its notes and a clip of its lanes (Clip#split_controls)' do
      clip = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2, cc: true)
      notes, moves = clip.split_controls
      expect(notes.controls).to eq([])
      expect(summary(notes)).to eq(summary(clip))
      expect(moves.events).to eq([])
      expect(moves.controls).to eq(clip.controls)
      expect([moves.length, moves.looping?, moves.align]).to eq([clip.length, true, clip.align])
      again = notes.with_controls(moves.controls)
      expect([summary(again), again.controls]).to eq([summary(clip), clip.controls])
      plain = MB::Sound::MIDI::Capture.clip(events, from: 1, length: 2)
      expect(plain.split_controls).to eq([plain, nil])
    end
  end
end
