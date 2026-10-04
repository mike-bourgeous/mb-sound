# The shared JACK client (ext/mb/sound/fast_audio/mb_jack.c): every output,
# input, and MIDI port of a process on one JACK client, added at any time.
RSpec.describe('MB::Sound::FastAudio JACK client', :aggregate_failures) do
  before(:context) { @jack_error = JackDummy.start }
  after(:context) { JackDummy.stop }
  before(:each) { skip @jack_error if @jack_error }

  let(:fa) { MB::Sound::FastAudio }
  let(:client) { "mbspec_client#{rand(1 << 20)}" }

  before(:each) { @opened = [] }
  after(:each) do
    @opened.each(&:close)
    fa.jack_close
  end

  # A JACK Playback with one port per name.  The dummy server runs at 48 kHz
  # with 256-frame periods.
  def jack_playback(names, sample_rate: 48000, queue: 2048, capture: 0, in_channels: names.length)
    fa::Playback.new(
      nil, -1, client, in_channels, names.length, sample_rate, 0, 0, queue, capture, 2, false, 0, names
    ).tap { |p| @opened << p }
  end

  def wait_until(seconds = 2)
    deadline = MB::U.clock_now + seconds
    sleep 0.01 until yield || MB::U.clock_now > deadline
  end

  it 'reports a JACK server' do
    expect(fa.jack_server?).to eq(true)
  end

  it 'opens one client and reports the server settings' do
    expect(fa.jack_info).to be_nil
    fa.jack_open(client)
    info = fa.jack_info
    expect(info[:client_name]).to eq(client)
    expect(info[:sample_rate]).to eq(48000)
    expect(info[:buffer_size]).to eq(256)

    wait_until { fa.jack_info[:cycles] > 2 }
    expect(fa.jack_info[:cycles]).to be > 2
  end

  it 'plays written audio through output ports on the shared client' do
    p = jack_playback(['out_1', 'out_2'], capture: 4096)
    expect(p.jack_ports).to eq(["#{client}:out_1", "#{client}:out_2"])
    expect(p.backend).to eq(:jack)
    expect(p.device_name).to eq(client)
    expect(p.sample_rate).to eq(48000)
    expect(p.device_rate).to eq(48000)
    expect(p.period).to eq(256)
    expect(p.resampling?).to eq(false)

    left = Numo::SFloat.linspace(0, 1, 2048)
    right = -left
    p.write([left, right])
    wait_until { p.stats[:frames_played] >= 4096 }

    played = Numo::SFloat.from_binary(p.captured).reshape(nil, 2)
    start = (0...played.shape[0]).find { |i| played[i, 0] != 0 } || 0
    expect(played[start...(start + 2047), 0]).to eq(left[1..])
    expect(played[start...(start + 2047), 1]).to eq(right[1..])
  end

  it 'reports where each cycle starts, mapping queued frames to JACK frame times' do
    p = jack_playback(['out_1'], capture: 8192)
    wait_until { p.jack_clock }
    first = p.jack_clock
    expect(first.keys).to eq([:frame_time, :read_pos, :frames_played, :write_pos])
    expect(first[:read_pos]).to eq(0)
    expect(first[:write_pos]).to eq(0)

    # The device clock and JACK's frame counter advance together
    wait_until { p.jack_clock[:frame_time] != first[:frame_time] }
    later = p.jack_clock
    expect((later[:frame_time] - first[:frame_time]) % 256).to eq(0)
    expect(later[:frames_played] - first[:frames_played]).to eq((later[:frame_time] - first[:frame_time]) & 0xffff_ffff)

    # Ring frame x plays at frame_time + x - read_pos, which is captured
    # index x - read_pos + frames_played
    ramp = Numo::SFloat.linspace(0, 1, 4096)
    p.write([ramp])
    clock = nil
    wait_until(2) { (c = p.jack_clock) && c[:read_pos] > 0 && (clock = c) }
    expect(clock[:write_pos]).to eq(4096)
    expect(clock[:read_pos]).to be < 4096

    wait_until { p.stats[:frames_played] >= clock[:frames_played] + 4096 }
    played = Numo::SFloat.from_binary(p.captured)
    start = (0...played.length).find { |i| played[i] != 0 }
    expect(start).to eq(1 - clock[:read_pos] + clock[:frames_played])
  end

  it 'has no JACK clock for miniaudio devices' do
    p = fa::Playback.new([:null], -1, client, 1, 2, 48000, 0, 0, 2048, 0, 2, false, 0)
    @opened << p
    expect(p.jack_clock).to be_nil
  end

  it 'puts later outputs on the same client, and removes ports on close' do
    a = jack_playback(['out_1', 'out_2'])
    b = jack_playback(['out_3'])
    expect(fa.jack_ports("^#{client}:", false, fa::JACK_PORT_IS_OUTPUT)).to eq(["#{client}:out_1", "#{client}:out_2", "#{client}:out_3"])

    a.close
    expect(a.closed?).to eq(true)
    expect(fa.jack_ports("^#{client}:", nil, 0)).to eq(["#{client}:out_3"])
    expect { a.write([Numo::SFloat.zeros(10)] * 2) }.to raise_error(IOError)

    b.write([Numo::SFloat.ones(256)])
    expect(b.stats[:frames_written]).to eq(256)
  end

  it 'resamples when the writer runs at another rate' do
    p = jack_playback(['out_1'], sample_rate: 44100)
    expect(p.sample_rate).to eq(44100)
    expect(p.device_rate).to eq(48000)
    expect(p.resampling?).to eq(true)
    p.write([Numo::SFloat.zeros(4410)])
    expect(p.stats[:frames_written]).to be_within(64).of(4800)
  end

  it 'connects and disconnects ports by name' do
    jack_playback(['out_1'])
    other = jack_playback(['out_2'])
    sinks = fa.jack_ports(nil, false, fa::JACK_PORT_IS_INPUT | fa::JACK_PORT_IS_PHYSICAL)
    skip 'the dummy server has no playback ports' if sinks.empty?

    expect(fa.jack_connect("#{client}:out_1", sinks[0])).to eq(true)
    expect(fa.jack_connections("#{client}:out_1")).to eq([sinks[0]])
    expect(fa.jack_disconnect("#{client}:out_1", sinks[0])).to eq(true)
    expect(fa.jack_connections("#{client}:out_1")).to eq([])
    other.close
  end

  def jack_capture(names, sample_rate: 48000, queue: 48000)
    fa::Capture.new(nil, -1, client, names.length, sample_rate, 0, 0, queue, 2, false, names).tap { |c| @opened << c }
  end

  it 'records input ports on the same client, sample for sample (loopback)' do
    out = jack_playback(['out_1', 'out_2'], queue: 4096)
    inp = jack_capture(['in_1', 'in_2'])
    expect(inp.jack_ports).to eq(["#{client}:in_1", "#{client}:in_2"])
    expect(inp.backend).to eq(:jack)
    expect(inp.period).to eq(256)
    expect(fa.jack_ports("^#{client}:", false, 0).sort).to eq(["#{client}:in_1", "#{client}:in_2", "#{client}:out_1", "#{client}:out_2"])

    expect(fa.jack_connect("#{client}:out_1", "#{client}:in_1")).to eq(true)
    expect(fa.jack_connect("#{client}:out_2", "#{client}:in_2")).to eq(true)

    ramp = Numo::SFloat.new(4096).seq(1) / 4096
    out.write([ramp, -ramp])

    # Silence until the written audio arrives, then the ramp exactly
    got = [[], []]
    deadline = MB::U.clock_now + 3
    while got[0].length < 12000 && MB::U.clock_now < deadline
      l, r = inp.read(512)
      got[0].concat(l.to_a)
      got[1].concat(r.to_a)
    end

    start = got[0].index { |v| v != 0 }
    expect(start).not_to be_nil
    expect(got[0][start, 4096]).to eq(ramp.to_a)
    expect(got[1][start, 4096]).to eq((-ramp).to_a)
  end

  it 'records a test pattern from JACK input ports' do
    inp = fa::Capture.new(nil, -1, client, 1, 48000, 0, 0, 48000, 2, true, ['in_1']).tap { |c| @opened << c }
    data = inp.read(1000)[0]
    expect(data.length).to eq(1000)
    expect(data[1] - data[0]).to be_within(1e-6).of(1.0 / 2048)
  end

  describe 'MIDI ports' do
    def midi_in(name = 'midi_in')
      fa::JackMIDIInput.new(client, name, 4096).tap { |m| @opened << m }
    end

    def midi_out(name = 'midi_out')
      fa::JackMIDIOutput.new(client, name, 4096).tap { |m| @opened << m }
    end

    def read_until(input, count)
      events = []
      deadline = MB::U.clock_now + 2
      events.concat(input.read(false)) while events.length < count && MB::U.clock_now < deadline && sleep(0.005)
      events
    end

    it 'sends MIDI out and back in on the same client, with JACK frame times' do
      out = midi_out
      inp = midi_in
      expect(out.port_name).to eq("#{client}:midi_out")
      expect(inp.port_name).to eq("#{client}:midi_in")
      expect(fa.jack_ports("^#{client}:", true, 0).sort).to eq(["#{client}:midi_in", "#{client}:midi_out"])
      expect(fa.jack_connect("#{client}:midi_out", "#{client}:midi_in")).to eq(true)

      out.write([0x90, 60, 100].pack('C*'))
      out.write([0x80, 60, 0].pack('C*'))
      sysex = ([0xf0] + Array.new(300) { |i| i % 128 } + [0xf7]).pack('C*')
      out.write(sysex)

      events = read_until(inp, 3)
      expect(events.map { |_, b| b }).to eq([[0x90, 60, 100].pack('C*'), [0x80, 60, 0].pack('C*'), sysex])
      expect(events.map { |_, b| b.encoding }.uniq).to eq([Encoding::BINARY])
      times = events.map(&:first)
      expect(times).to all(be_a(Integer))
      expect(times).to eq(times.sort)
      expect(inp.stats[:messages]).to eq(3)
      expect(out.stats).to include(messages: 3, dropped: 0, queued: 0)
    end

    it 'receives from another JACK client (e.g. jack-keyboard)' do
      inp = midi_in
      keyboard = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_keys', nil, 'out')
      expect(fa.jack_connect('mbspec_keys:out', "#{client}:midi_in")).to eq(true)

      keyboard.send_bytes([0xb0, 1, 64].pack('C*'))
      expect(read_until(inp, 1).map(&:last)).to eq([[0xb0, 1, 64].pack('C*')])
    ensure
      keyboard&.close
    end

    it 'waits for a message with read(true)' do
      out = midi_out
      inp = midi_in
      fa.jack_connect("#{client}:midi_out", "#{client}:midi_in")
      Thread.new { sleep 0.05; out.write([0xc0, 5].pack('C*')) }
      expect(inp.read(true).map(&:last)).to eq([[0xc0, 5].pack('C*')])
    end

    it 'puts MIDI and audio ports on one client, removing them on close' do
      jack_playback(['out_1', 'out_2'])
      inp = midi_in
      expect(fa.jack_ports("^#{client}:", nil, 0).sort).to eq(["#{client}:midi_in", "#{client}:out_1", "#{client}:out_2"])
      inp.close
      expect(inp.closed?).to eq(true)
      expect(inp.port_name).to be_nil
      expect(fa.jack_ports("^#{client}:", true, 0)).to eq([])
      expect { inp.read(false) }.to raise_error(IOError)
    end

    it 'raises when the output queue is full, and for the wrong direction' do
      out = fa::JackMIDIOutput.new(client, 'midi_out', 1024).tap { |m| @opened << m }
      inp = midi_in
      expect { out.read(false) }.to raise_error(NoMethodError)
      expect { 400.times { out.write([0x90, 1, 1].pack('C*')) } }.to raise_error(MB::Sound::FastAudio::Error, /full/)
      expect { inp.write('x') }.to raise_error(NoMethodError)
    end
  end

  it 'stops writers when the client closes' do
    p = jack_playback(['out_1'], queue: 512)
    fa.jack_close
    expect { 10.times { p.write([Numo::SFloat.zeros(512)]) } }.to raise_error(MB::Sound::FastAudio::Error, /stopped/)
  end
end
