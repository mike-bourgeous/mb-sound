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

  it 'stops writers when the client closes' do
    p = jack_playback(['out_1'], queue: 512)
    fa.jack_close
    expect { 10.times { p.write([Numo::SFloat.zeros(512)]) } }.to raise_error(MB::Sound::FastAudio::Error, /stopped/)
  end
end
