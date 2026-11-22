# Timed JACK MIDI output (ext/mb/sound/fast_audio/mb_midi_timed.h):
# JackMIDIOutput#write_at queues short messages for exact JACK frames, the
# process callback sorts them and writes each at its frame offset.
RSpec.describe('MB::Sound::FastAudio::JackMIDIOutput timed messages', :aggregate_failures) do
  before(:context) { @jack_error = JackDummy.start }
  after(:context) { JackDummy.stop }
  before(:each) { skip @jack_error if @jack_error }

  let(:fa) { MB::Sound::FastAudio }
  let(:client) { "mbspec_timed#{rand(1 << 20)}" }

  before(:each) { @opened = [] }
  after(:each) do
    @opened.each(&:close)
    fa.jack_close
  end

  def loopback
    out = fa::JackMIDIOutput.new(client, 'midi_out', 65536).tap { |m| @opened << m }
    inp = fa::JackMIDIInput.new(client, 'midi_in', 65536).tap { |m| @opened << m }
    expect(fa.jack_connect("#{client}:midi_out", "#{client}:midi_in")).to eq(true)
    [out, inp]
  end

  def read_until(input, count, seconds = 3)
    events = []
    deadline = MB::U.clock_now + seconds
    events.concat(input.read(false)) while events.length < count && MB::U.clock_now < deadline && sleep(0.005)
    events
  end

  # Frames +b+ - +a+ on JACK's wrapping 32-bit clock
  def delta(a, b)
    ((b - a + 0x8000_0000) & 0xffff_ffff) - 0x8000_0000
  end

  # The loopback's own delay in frames (a message written in one cycle and
  # read back by the same client: the dummy server's 256-frame period, or 0)
  def loop_delay(out, inp)
    base = (fa.jack_frame_time + 4096) & 0xffff_ffff
    out.write_at(base, 0xb0, 1, 1)
    got = read_until(inp, 1)
    expect(got.length).to eq(1)
    delta(base, got[0][0])
  end

  it 'sends each message on its frame, sorted, whatever order it was queued in' do
    out, inp = loopback
    lag = loop_delay(out, inp)
    expect([0, 256]).to include(lag)

    base = (fa.jack_frame_time + 9600) & 0xffff_ffff
    # Two writers interleaved (two tracks on one port), and offsets inside
    # periods and on their edges
    offsets = [0, 1, 255, 256, 257, 1000, 1001, 4800]
    writes = offsets.each_with_index.map { |o, i| [o, [0x90 | (i % 2), 40 + i, 100]] }
    writes.reverse.each { |o, b| expect(out.write_at((base + o) & 0xffff_ffff, *b)).to eq(true) }
    # equal frames keep their queue order
    out.write_at((base + 1000) & 0xffff_ffff, 0x80, 47, 0)

    got = read_until(inp, offsets.length + 1)
    expect(got.map { |f, _| delta(base, f) - lag }).to eq([0, 1, 255, 256, 257, 1000, 1000, 1001, 4800])
    expect(got[6][1].bytes).to eq([0x80, 47, 0])
    expect(got[5][1].bytes).to eq([0x91, 45, 100])
    expect(out.stats).to include(timed_late: 0, timed_dropped: 0, timed_pending: 0)
  end

  it 'sends late messages at the start of the next cycle and counts them' do
    out, inp = loopback
    lag = loop_delay(out, inp)
    past = (fa.jack_frame_time - 10_000) & 0xffff_ffff
    out.write_at(past, 0x90, 60, 1)
    got = read_until(inp, 1)
    # (jack_frame_time is the server's estimate of now, up to a period past
    # the start of the cycle the message goes out in; memcheck found 9977)
    expect(delta(past, got[0][0]) - lag).to be >= 10_000 - 256
    expect(out.stats[:timed_late]).to eq(1)
    expect(out.stats[:timed_max_late]).to be >= 10_000 - 256
  end

  it 'takes one- and two-byte messages and refuses SysEx' do
    out, inp = loopback
    base = (fa.jack_frame_time + 4800) & 0xffff_ffff
    out.write_at(base, 0xf8, 0, 0)
    out.write_at(base, 0xc2, 12, 99)
    out.write_at(base, 0xf2, 0x10, 0x01)
    expect(read_until(inp, 3).map { |_, b| b.bytes }).to eq([[0xf8], [0xc2, 12], [0xf2, 0x10, 0x01]])
    expect { out.write_at(base, 0xf0, 1, 2) }.to raise_error(ArgumentError, /SysEx/)
  end

  it 'drops queued timed messages on discard_timed, keeping later ones' do
    out, inp = loopback
    lag = loop_delay(out, inp)
    base = (fa.jack_frame_time + 12_000) & 0xffff_ffff
    out.write_at(base, 0x90, 60, 100)
    sleep 0.05 # (staged by now)
    out.write_at((base + 10) & 0xffff_ffff, 0x90, 61, 100)
    out.discard_timed
    out.write_at((base + 20) & 0xffff_ffff, 0x90, 62, 100)
    got = read_until(inp, 1, 2)
    expect(got.map { |_, b| b.getbyte(1) }).to eq([62])
    expect(delta(base, got[0][0]) - lag).to eq(20)
  end

  it 'delivers a 4 KB SysEx intact while timed notes play, and states the per-message limit' do
    out, inp = loopback
    lag = loop_delay(out, inp)
    expect(out.max_message).to be > 4096
    base = (fa.jack_frame_time + 4800) & 0xffff_ffff
    64.times { |i| out.write_at((base + i * 37) & 0xffff_ffff, 0x90, 30 + (i % 60), 64) }
    sysex = ([0xf0] + Array.new(4094) { |i| (i * 7) % 128 } + [0xf7]).pack('C*')
    out.write(sysex)
    got = read_until(inp, 65)
    expect(got.length).to eq(65)
    expect(got.map(&:last)).to include(sysex)
    notes = got.reject { |_, b| b == sysex }
    expect(notes.map { |f, _| delta(base, f) - lag }).to eq(Array.new(64) { |i| i * 37 })
    expect { out.write('x'.b * (out.max_message + 1)) }.to raise_error(ArgumentError, /up to #{out.max_message} bytes/)
  end

  # (midi-one-based-1, from the review of midi-out-1: a long message queued
  # while it fit, whose room then shrank, must not hold the queue forever)
  it 'drops and counts a queued long message that no longer fits a cycle, and sends what follows it' do
    out, inp = loopback
    loop_delay(out, inp)
    out.cap_message(1000)
    sysex = ([0xf0] + Array.new(1998) { |i| i % 128 } + [0xf7]).pack('C*')
    small = ([0xf0] + Array.new(98) { |i| i % 128 } + [0xf7]).pack('C*')
    out.write(sysex) # (the port's own room still takes it: queued)
    out.write(small)
    out.write([0x90, 60, 100].pack('C*'))
    got = read_until(inp, 2)
    expect(got.map(&:last)).to eq([small, [0x90, 60, 100].pack('C*')])
    expect(out.stats[:too_large]).to eq(1)
    out.cap_message(0)
    out.write(sysex)
    expect(read_until(inp, 1).map(&:last)).to eq([sysex])
    expect(out.stats[:too_large]).to eq(1)
  end

  # A JACK playback capturing what it plays (the frames before its first
  # write included), its first cycle run
  def playback(name = 'out_1')
    p = fa::Playback.new(nil, -1, client, 1, 1, 48000, 0, 0, 8192, 48000, 2, false, 0, [name]).tap { |x| @opened << x }
    deadline = MB::U.clock_now + 2
    sleep 0.005 until p.jack_clock || MB::U.clock_now > deadline
    expect(p.jack_clock).not_to eq(nil)
    p
  end

  # The JACK frame where captured frame +k+ of +p+ left (the device clock
  # counts every frame played)
  def left(p, k)
    clock = p.jack_clock
    (clock[:frame_time] + k - clock[:frames_played]) & 0xffff_ffff
  end

  # midi-out-first-note-2: a message timed by a ring frame waits until that
  # frame's audio is queued, then leaves with it, however long the ring
  # stayed empty (by a JACK frame mapped before the write, it went a period
  # early when a cycle passed before the write)
  it 'holds a message timed by a ring frame until its audio is queued, then sends it with that audio' do
    out, inp = loopback
    lag = loop_delay(out, inp)
    p = playback
    expect(out.write_after(p, 100, 96, 0x90, 60, 100)).to eq(true)
    expect(out.write_after(p, 300, 0, 0x80, 60, 0)).to eq(true)
    c0 = p.jack_clock[:frame_time]
    deadline = MB::U.clock_now + 2
    sleep 0.002 until delta(c0, p.jack_clock[:frame_time]) >= 1024 || MB::U.clock_now > deadline
    expect(out.stats).to include(timed_waiting: 2, timed_sent: 1) # (the loop_delay probe)
    expect(inp.read(false)).to eq([])

    audio = Numo::SFloat.zeros(512)
    audio[100] = 1
    audio[300] = 1
    p.write([audio])
    got = read_until(inp, 2)
    expect(got.map { |_, b| b.bytes }).to eq([[0x90, 60, 100], [0x80, 60, 0]])
    played = p.captured.unpack('e*')
    clicks = (0...played.length).select { |k| played[k] > 0.5 }
    expect(clicks.length).to eq(2)
    expect(delta(left(p, clicks[0]), got[0][0]) - lag).to eq(96)
    expect(delta(left(p, clicks[1]), got[1][0]) - lag).to eq(0)
    expect(out.stats).to include(timed_waiting: 0, timed_late: 0)
  end

  it 'sends waiting messages at once, counted late, when the port follows another playback or the playback closes' do
    out, inp = loopback
    loop_delay(out, inp)
    p1 = playback('out_1')
    p2 = playback('out_2')
    expect(out.write_after(p1, 48_000, 0, 0x90, 61, 100)).to eq(true)
    expect(out.write_after(p2, 48_000, 0, 0x90, 62, 100)).to eq(true) # (the port follows p2 now)
    got = read_until(inp, 1)
    expect(got.map { |_, b| b.getbyte(1) }).to eq([61])
    expect(out.stats).to include(timed_late: 1, timed_waiting: 1)

    p2.close
    got = read_until(inp, 1)
    expect(got.map { |_, b| b.getbyte(1) }).to eq([62])
    expect(out.stats).to include(timed_late: 2, timed_waiting: 0)
    expect(out.write_after(p2, 0, 0, 0x90, 63, 100)).to eq(nil)
    expect { out.write_after(p1, 0, 0, 0xf0, 1, 2) }.to raise_error(ArgumentError, /SysEx/)
  end

  it 'drops messages waiting for their audio on discard_timed' do
    out, inp = loopback
    loop_delay(out, inp)
    p = playback
    out.write_after(p, 10, 0, 0x90, 64, 100)
    deadline = MB::U.clock_now + 2
    sleep 0.002 until out.stats[:timed_waiting] == 1 || MB::U.clock_now > deadline
    out.discard_timed
    out.write_after(p, 20, 0, 0x90, 65, 100)
    p.write([Numo::SFloat.zeros(256)])
    expect(read_until(inp, 1, 1).map { |_, b| b.getbyte(1) }).to eq([65])
    expect(out.stats).to include(timed_waiting: 0, timed_late: 0)
  end

  it "maps ring frames to JACK frames with a playback's clock" do
    p = fa::Playback.new(nil, -1, client, 1, 1, 48000, 0, 0, 2048, 0, 2, false, 0, ['out_1']).tap { |x| @opened << x }
    deadline = MB::U.clock_now + 2
    sleep 0.01 until p.jack_frame_of(0) || MB::U.clock_now > deadline
    a = p.jack_frame_of(0)
    expect(a).to be_a(Integer)
    expect(delta(a, p.jack_frame_of(100))).to eq(100)
    expect(delta(a, p.jack_frame_of(-5))).to eq(-5)
    clock = p.jack_clock
    expect(delta(clock[:frame_time] + clock[:write_pos] - clock[:read_pos], p.jack_frame_of(0))).to eq(0)
  end
end
