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
end
