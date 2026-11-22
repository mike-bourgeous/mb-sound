# The console's `sysex` command (SysExMethods) with fake MIDI inputs and
# outputs and synthetic dumps.
RSpec.describe(MB::Sound::SysExMethods, :aggregate_failures) do
  # A MIDI input whose #read_raw hands out what the spec queued.
  class FakeConsoleSysExInput
    def initialize = @queue = Queue.new
    def feed(bytes) = @queue << [0.0, bytes]

    def read_raw
      out = []
      out << @queue.pop until @queue.empty?
      out
    end

    def close = nil
  end

  let(:sq80) { MB::Sound::SQ80 }
  let(:single) { sq80::SysEx.dump([sq80::Program.init('REESE ')]).pack('C*') }
  let(:inbox) { File.dirname(tmp_path('x')) }
  let(:input) { FakeConsoleSysExInput.new }

  before(:each) do
    stub_const('ENV', ENV.to_h.merge('MB_SOUND_CHECKOUT_TMP' => inbox))
    allow(MB::Sound::MIDI::SysExCapture).to receive(:sources).and_return([[:alsa, 1, 'USB MIDI:Port 2 24:1']])
    allow(MB::Sound::MIDI::Input).to receive(:new).and_return(input)
  end

  after(:each) { described_class.reset }

  def wait_for(timeout)
    deadline = MB::U.clock_now + timeout
    sleep 0.005 until yield || MB::U.clock_now > deadline
    yield
  end

  it 'says how to start before any capture' do
    expect(MB::Sound.sysex.inspect).to eq('sysex: nothing captured yet (sysex.capture listens; sysex.ports lists the sources)')
  end

  it 'captures in the background into the handoff inbox, then stops' do
    s = nil
    expect { s = MB::Sound.sysex.capture('USB', timeout: 30) }.to output("sysex: listening on USB MIDI:Port 2 24:1\n").to_stdout
    expect(s).to equal(MB::Sound.sysex)
    expect(MB::Sound::MIDI::Input).to have_received(:new).with(connect: 1, api: :alsa, queue_size: 8192, max_message: 1 << 20, from_env: false)
    expect(s.inspect).to start_with('sysex: listening on USB MIDI:Port 2 24:1 for 0:00 of 0:30, 0 messages')

    expect { MB::Sound.sysex.capture }.to output(/\Asysex: already listening on USB MIDI/).to_stdout

    expect {
      input.feed(single)
      expect(wait_for(5) { !s.messages.empty? }).to eq(true)
    }.to output(/sysex: Ensoniq ESQ-1\/SQ-80 program "REESE" \(channel 1\), 210 bytes from USB MIDI:Port 2 24:1\n  saved /).to_stdout

    expect(s.last.decode.first.name).to eq('REESE ')
    expect(s.paths.length).to eq(1)
    expect(File.dirname(s.paths.first)).to eq(File.join(inbox, 'sysex'))
    expect(File.binread(s.paths.first)).to eq(single)

    expect { s.stop }.to output("sysex: stopped after 0:00, 1 message\n").to_stdout
    expect(s.inspect).to eq("sysex: stopped after 0:00, 1 message; saved #{s.paths.first}")
  end

  it 'sends a dump request once listening' do
    out = instance_double(MB::Sound::MIDI::Output, closed?: false, connected_to: 'USB MIDI:Port 2 24:1', close: nil)
    written = []
    allow(out).to receive(:write) { |b| written << b }
    allow(MB::Sound::MIDI::Output).to receive(:new).and_return(out)

    expect {
      MB::Sound.sysex.capture('USB', request: sq80::SysEx.request(:program), to: 'USB')
    }.to output(/listening on USB.*\nsysex: sent 1 message \(6 bytes\) to USB MIDI:Port 2 24:1\n/).to_stdout
    expect(MB::Sound::MIDI::Output).to have_received(:new).with(connect: 'USB', api: nil, same_key: :raw)
    expect(written).to eq([[0xF0, 0x0F, 0x02, 0x00, 0x09, 0xF7].pack('C*')])
    expect { MB::Sound.sysex.capture('USB', request: [0xF0, 0xF7]) }.to output(/already listening/).to_stdout
  end

  it 'needs to: for a request' do
    expect { MB::Sound.sysex.capture(request: [0xF0, 0x7D, 0xF7]) }.to raise_error(ArgumentError, /needs to:/)
  end

  it 'loads a file and transmits it whole, keeping the output open, and refuses incomplete messages' do
    path = tmp_path('reese.syx')
    File.binwrite(path, single)
    dump = MB::Sound.sysex.load(path)
    expect(dump.programs.map(&:name)).to eq(['REESE '])

    out = instance_double(MB::Sound::MIDI::Output, closed?: false, connected_to: 'SQ', close: nil)
    written = []
    allow(out).to receive(:write) { |b| written << b }
    allow(MB::Sound::MIDI::Output).to receive(:new).and_return(out)

    expect { expect(MB::Sound.sysex.transmit(path, to: 'SQ')).to eq(1) }.to output("sysex: sent 1 message (210 bytes) to SQ\n").to_stdout
    expect { MB::Sound.sysex.transmit(dump, to: 'SQ') }.to output(/sent 1 message/).to_stdout
    expect(written).to eq([single, single])
    expect(MB::Sound::MIDI::Output).to have_received(:new).once

    expect { MB::Sound.sysex.transmit([0xF0, 0x7D, 1], to: 'SQ') }.to raise_error(ArgumentError, /no F7/)
    expect { MB::Sound.sysex.transmit([0x90, 60, 1], to: 'SQ') }.to raise_error(ArgumentError, /no SysEx/)
  end

  it 'lists the MIDI sources, numbered' do
    allow(MB::Sound::MIDI::Input).to receive(:ports).and_return(['Midi Through:Port-0 14:0', 'USB MIDI:Port 1 24:0'])
    expect { expect(MB::Sound.sysex.ports).to eq(['Midi Through:Port-0 14:0', 'USB MIDI:Port 1 24:0']) }
      .to output("   0: Midi Through:Port-0 14:0\n   1: USB MIDI:Port 1 24:0\n").to_stdout
  end
end
