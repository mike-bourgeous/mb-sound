# Receiving SysEx from live MIDI inputs (MIDI::SysExCapture) with fake
# inputs fed synthetic dumps, plus one run through a private JACK server.
RSpec.describe(MB::Sound::MIDI::SysExCapture, :aggregate_failures) do
  # A MIDI input whose #read_raw hands out what the spec queued.
  class FakeSysExInput
    attr_reader :closed
    attr_accessor :dropped

    def initialize
      @queue = []
      @closed = false
      @dropped = 0
    end

    def feed(*messages)
      messages.each { |m| @queue << [0.0, m.is_a?(Array) ? m.pack('C*') : m] }
      self
    end

    def read_raw
      out = @queue
      @queue = []
      out
    end

    def close = @closed = true
  end

  let(:sq80) { MB::Sound::SQ80 }
  let(:single) { sq80::SysEx.dump([sq80::Program.init('REESE ')]).pack('C*') }
  let(:bank) { sq80::SysEx.dump(Array.new(40) { |i| sq80::Program.init(format('P%02d', i)) }).pack('C*') }
  let(:korg) { [0xF0, 0x42, 0x30, 0x68, 0x01, 0x02, 0xF7].pack('C*') }
  let(:dir) { File.dirname(tmp_path('x')) }
  let(:lines) { [] }
  let(:now) { [0.0] }
  let(:a) { FakeSysExInput.new }
  let(:b) { FakeSysExInput.new }

  def capture(**opts)
    @capture = described_class.new([['Port A', a], ['Port B', b]], dir: dir, out: ->(l) { lines << l }, thread: false,
                                   clock: -> { now[0] }, **opts)
  end

  after(:each) { @capture&.stop }

  # Waits up to +timeout+ seconds for the block to be truthy; returns its
  # last value.
  def wait_for(timeout)
    deadline = MB::U.clock_now + timeout
    sleep 0.005 until yield || MB::U.clock_now > deadline
    yield
  end

  it 'saves a single SQ-80 program as it arrives, says which port it came from, and keeps listening' do
    cap = capture
    b.feed([0x90, 60, 100], single, [0x80, 60, 0])
    expect(cap.poll).to eq(true)

    expect(cap.messages.map(&:bytes)).to eq([single])
    expect(cap.messages.first.port).to eq('Port B')
    expect(cap.paths.length).to eq(1)
    expect(File.basename(cap.paths.first)).to match(/\A\d{4}-\d\d-\d\d_\d{6}_sq80-program-reese\.syx\z/)
    expect(File.binread(cap.paths.first)).to eq(single)
    expect(lines.first).to eq("sysex: Ensoniq ESQ-1/SQ-80 program \"REESE\" (channel 1), 210 bytes from Port B\n  saved #{cap.paths.first}")
    expect(cap.status).to match(%r{\Asysex: listening on 2 sources for 0:00 of 1:00, 1 message \(sysex.stop to stop\)\z})
    expect(cap.state).to eq(:listening)
  end

  it 'joins a bank dump split across reads and reports it while it arrives' do
    cap = capture
    pieces = bank.bytes.each_slice(1000).map { |s| s.pack('C*') }
    pieces[0..3].each { |p| a.feed(p) }
    cap.poll
    expect(cap.messages).to eq([])
    expect(cap.status).to include('receiving 4000 bytes from Port A')

    pieces[4..].each { |p| a.feed(p) }
    cap.poll
    expect(cap.messages.map(&:bytes)).to eq([bank])
    expect(File.basename(cap.paths.first)).to end_with('_sq80-bank.syx')
    expect(cap.messages.first.decode.length).to eq(40)
  end

  it 'saves messages from other manufacturers too' do
    cap = capture(count: 1)
    a.feed(korg)
    expect(cap.poll).to eq(false)
    expect(cap.state).to eq(:finished)
    expect(File.basename(cap.paths.first)).to end_with('_korg.syx')
    expect(lines).to eq(["sysex: Korg, 7 bytes from Port A\n  saved #{cap.paths.first}"])
    expect([a.closed, b.closed]).to eq([true, true])
    expect(cap.status).to eq("sysex: done after 0:00, 1 message; saved #{cap.paths.first}")
  end

  it 'times out, waiting for a dump still arriving until its bytes stop for GRACE seconds' do
    cap = capture(timeout: 10)
    now[0] = 9.5
    a.feed(bank[0, 500])
    expect(cap.poll).to eq(true)
    now[0] = 10.2
    expect(cap.poll).to eq(true) # still arriving: grace from 9.5
    a.feed(bank[500, 10])
    expect(cap.poll).to eq(true) # more bytes: grace from 10.2
    now[0] = 11.0
    expect(cap.poll).to eq(true) # bytes 0.6 s later: still within the grace
    a.feed(bank[510..])
    expect(cap.poll).to eq(false) # complete, past the timeout: ends at once
    expect(cap.messages.map(&:bytes)).to eq([bank])
    expect(cap.state).to eq(:timed_out)
    expect(lines.last).to eq('sysex: timed out after 0:11, 1 message')
  end

  it 'times out with nothing received' do
    cap = capture(timeout: 5)
    now[0] = 5
    expect(cap.poll).to eq(false)
    expect(cap.state).to eq(:timed_out)
    expect(lines).to eq(['sysex: timed out after 0:05, nothing received'])
    expect(cap.paths).to eq([])
  end

  it 'keeps a dump cut short by #stop as an incomplete file' do
    cap = capture
    a.feed(bank[0, 100])
    cap.poll
    cap.stop
    expect(cap.state).to eq(:stopped)
    expect(cap.messages.map(&:complete?)).to eq([false])
    expect(File.basename(cap.paths.first)).to end_with('_incomplete.syx')
    expect(lines.first).to include('INCOMPLETE')
    expect(cap.poll).to eq(false)
    cap.stop # nothing more happens
    expect(lines.length).to eq(2)
  end

  it 'never replaces a file: path: names the first file and later ones get -2, -3' do
    path = tmp_path('reese.syx')
    File.binwrite(path, 'his older file')
    cap = capture(path: path)
    a.feed(single, korg)
    cap.poll
    expect(cap.paths).to eq([path.sub('.syx', '-2.syx'), path.sub('.syx', '-3.syx')])
    expect(File.binread(path)).to eq('his older file')
  end

  it 'reports messages an input lost' do
    cap = capture
    a.dropped = 2
    cap.poll
    expect(lines).to eq(['sysex: 2 messages from Port A were lost (too long or the queue was full)'])
    cap.poll
    expect(lines.length).to eq(1)
  end

  it 'saves to the handoff inbox by default' do
    stub_const('ENV', ENV.to_h.merge('MB_SOUND_CHECKOUT_TMP' => dir))
    expect(described_class.default_dir).to eq(File.join(dir, 'sysex'))
  end

  it 'keeps messages in memory only with save: false' do
    cap = capture(save: false)
    a.feed(korg)
    cap.poll
    expect(cap.paths).to eq([])
    expect(lines).to eq(['sysex: Korg, 7 bytes from Port A'])
  end

  it 'ends as failed when an input raises, printing the error' do
    cap = capture
    allow(a).to receive(:read_raw).and_raise(IOError, 'gone')
    expect(cap.poll).to eq(false)
    expect(cap.state).to eq(:failed)
    expect(cap.error).to be_a(IOError)
    expect(lines).to eq(['sysex: capture failed: IOError: gone'])
    expect(cap.status).to include('failed', 'IOError: gone')
  end

  it 'checks its options' do
    expect { described_class.new([], thread: false) }.to raise_error(ArgumentError, /at least one input/)
    expect { capture(timeout: 0) }.to raise_error(ArgumentError, /timeout/)
    expect { capture(count: 0) }.to raise_error(ArgumentError, /count/)
  end

  it 'declares every state and moves only by its transition table' do
    expect(described_class::STATES).to eq(%i[listening finished timed_out stopped failed])
    described_class::TRANSITIONS.each do |from, events|
      expect(events.values - described_class::STATES).to eq([])
      expect(events).to be_empty unless from == :listening
    end
    expect(described_class::ENDINGS.keys).to eq(described_class::STATES - [:listening])
  end

  it 'runs in a background thread and stops' do
    cap = described_class.new([['Port A', a]], dir: dir, out: ->(l) { lines << l }, count: 1)
    a.feed(korg)
    cap.wait(5)
    expect(cap.state).to eq(:finished)
    expect(cap.paths.length).to eq(1)
  end

  describe '.sources' do
    before(:each) do
      allow(MB::Sound::MIDI::Input).to receive(:search_apis).and_return([:alsa])
      allow(MB::Sound::MIDI::Input).to receive(:port_names).with(:alsa, :input)
        .and_return(['Midi Through:Port-0 14:0', 'USB MIDI:Port 1 24:0', 'USB MIDI:Port 2 24:1', "#{MB::Sound::DeviceOutput.client_name}:midi_out 130:0"])
    end

    it 'lists every source but our own ports, or those matching part of a name, a Regexp, or an index' do
      expect(described_class.sources.map(&:last)).to eq(['Midi Through:Port-0 14:0', 'USB MIDI:Port 1 24:0', 'USB MIDI:Port 2 24:1'])
      expect(described_class.sources('usb')).to eq([[:alsa, 1, 'USB MIDI:Port 1 24:0'], [:alsa, 2, 'USB MIDI:Port 2 24:1']])
      expect(described_class.sources(/Port 2/)).to eq([[:alsa, 2, 'USB MIDI:Port 2 24:1']])
      expect(described_class.sources(0)).to eq([[:alsa, 0, 'Midi Through:Port-0 14:0']])
    end

    it 'raises with the sources when nothing matches' do
      expect { described_class.sources('Launchkey') }.to raise_error(ArgumentError, /No MIDI source matches "Launchkey".*1: USB MIDI:Port 1/m)
      expect { described_class.sources(1.5) }.to raise_error(ArgumentError, /part of a name/)
    end
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) { skip @jack_error if @jack_error }

    around(:each) do |ex|
      saved = %w[MIDI_API MIDI_DEVICE].to_h { |k| [k, ENV.delete(k)] }
      ex.run
    ensure
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end

    after(:each) do
      @capture&.stop
      @sender&.close
      MB::Sound::Jack.close
    end

    it 'receives a bank dump from another JACK client and saves it' do
      @sender = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_sq', nil, 'out')
      @capture = described_class.start('mbspec_sq', api: :jack, dir: dir, out: ->(l) { lines << l }, timeout: 20)
      expect(@capture.sources).to eq(['mbspec_sq:out'])

      # The connection is live once a probe arrives (an empty SysEx, saved)
      deadline = MB::U.clock_now + 10
      until !@capture.messages.empty? || MB::U.clock_now > deadline
        @sender.send_bytes([0xF0, 0x7D, 0xF7].pack('C*'))
        wait_for(0.2) { !@capture.messages.empty? }
      end
      @sender.send_bytes(bank)

      expect(wait_for(10) { @capture.messages.any? { |m| m.bytes == bank } }).to eq(true)
      saved = @capture.paths.find { |p| p.end_with?('_sq80-bank.syx') }
      expect(File.binread(saved)).to eq(bank)
    end
  end
end
