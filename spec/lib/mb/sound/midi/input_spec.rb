RSpec.describe(MB::Sound::MIDI::Input, :aggregate_failures) do
  around(:each) do |ex|
    saved = %w[MIDI_API MIDI_DEVICE JACK_CLIENT_NAME].to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  describe '.api' do
    it 'uses MIDI_API over the argument' do
      ENV['MIDI_API'] = 'alsa'
      expect(MB::Sound::MIDI::Input.api(:jack)).to eq(:alsa)
    end

    it 'uses the argument' do
      expect(MB::Sound::MIDI::Input.api(':jack')).to eq(:jack)
    end

    it 'uses JACK on Linux only when a JACK server is running' do
      allow(MB::Sound::FastMIDI).to receive(:compiled_apis).and_return([:alsa, :jack])

      allow(MB::Sound::DeviceOutput).to receive(:jack_running?).and_return(true)
      expect(MB::Sound::MIDI::Input.api).to eq(:jack)

      allow(MB::Sound::DeviceOutput).to receive(:jack_running?).and_return(false)
      expect(MB::Sound::MIDI::Input.api).to eq(:alsa)
    end

    it 'uses JACK even when RtMidi was built without it (JACK MIDI is the shared client)' do
      stub_const('RUBY_PLATFORM', 'x86_64-linux')
      allow(MB::Sound::FastMIDI).to receive(:compiled_apis).and_return([:alsa])
      allow(MB::Sound::DeviceOutput).to receive(:jack_running?).and_return(true)
      expect(MB::Sound::MIDI::Input.apis).to eq([:alsa, :jack])
      expect(MB::Sound::MIDI::Input.api).to eq(:jack)
    end

    it 'uses CoreMIDI on macOS' do
      allow(MB::Sound::FastMIDI).to receive(:compiled_apis).and_return([:core])
      expect(MB::Sound::MIDI::Input.api).to eq(:core)
    end
  end

  describe '#read_raw with RtMidi' do
    it "passes RtMidi's deltas through" do
      rtmidi = instance_double(MB::Sound::FastMIDI::Input, close: nil, closed?: false)
      allow(MB::Sound::FastMIDI::Input).to receive(:new).and_return(rtmidi)
      allow(rtmidi).to receive(:read).and_return([[0.5, "\x90<d"], [0.25, "\x80<\x00"]])

      inp = MB::Sound::MIDI::Input.new(api: :alsa)
      expect(inp.frame_times?).to eq(false)
      expect(inp.frame_rate).to be_nil
      expect(inp.read_raw).to eq([[0.5, "\x90<d"], [0.25, "\x80<\x00"]])
    ensure
      inp&.close
    end
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) { skip @jack_error if @jack_error }

    let!(:keyboard) { MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_keyboard', nil, 'out') }

    before(:each) do
      ENV['MIDI_API'] = 'jack'
      @inputs = []
    end
    after(:each) do
      @inputs.each(&:close)
      keyboard.close
      MB::Sound::Jack.close
    end

    def input(**kwargs)
      MB::Sound::MIDI::Input.new(**kwargs).tap { |i| @inputs << i }
    end

    def send(*messages)
      messages.each { |m| keyboard.send_bytes(m.pack('C*')) }
    end

    # Reads until +count+ events arrive (#read_raw's [time, bytes] pairs)
    def wait_for(inp, count)
      events = []
      deadline = MB::U.clock_now + 2
      while events.length < count && MB::U.clock_now < deadline
        events.concat(inp.read_raw)
        sleep 0.005
      end
      events
    end

    it 'sees the running server' do
      expect(MB::Sound::DeviceOutput.jack_running?).to eq(true)
    end

    it 'lists sources' do
      expect(MB::Sound::MIDI::Input.ports).to include('mbspec_keyboard:out')
    end

    it 'connects to a source by part of its name, ignoring case' do
      inp = input(connect: 'KEYBOARD')
      expect(inp.connected_to).to eq('mbspec_keyboard:out')
      expect(inp.connections).to eq(['mbspec_keyboard:out'])
      expect(inp.api).to eq(:jack)
      sleep 0.05

      send([0x90, 64, 90], [0x80, 64, 0])
      events = wait_for(inp, 2)
      expect(events.map { |_, b| b.bytes }).to eq([[0x90, 64, 90], [0x80, 64, 0]])
      expect(events.map(&:first)).to all(be_a(Integer)) # JACK frame times
    end

    it 'defaults to JACK MIDI when a JACK server answers' do
      ENV.delete('MIDI_API')
      expect(MB::Sound::FastAudio.jack_server?).to eq(true)
      expect(MB::Sound::MIDI::Input.api).to eq(:jack)

      inp = input(connect: 'mbspec_key')
      expect(inp.api).to eq(:jack)
      expect(inp.connected_to).to eq('mbspec_keyboard:out')

      sleep 0.05
      send([0x90, 64, 90])
      expect(wait_for(inp, 1).map { |_, b| b.bytes }).to eq([[0x90, 64, 90]])
    end

    it 'also searches ALSA sequencer ports when JACK is the default' do
      ENV.delete('MIDI_API')
      allow(MB::Sound::FastMIDI).to receive(:input_ports).and_call_original
      allow(MB::Sound::FastMIDI).to receive(:input_ports).with(:alsa, anything).and_return(['Launchkey MIDI 20:0'])

      api, index, name, lists = MB::Sound::MIDI::Input.find_port('launchkey', kind: :input)
      expect([api, index, name]).to eq([:alsa, 0, 'Launchkey MIDI 20:0'])
      expect(lists.keys).to eq([:jack, :alsa])
      expect(MB::Sound::MIDI::Input.port_list(lists)).to match(/0: mbspec_keyboard:out \(jack\).*0: Launchkey MIDI 20:0 \(alsa\)/m)
    end

    it 'searches only ALSA without a JACK server' do
      ENV.delete('MIDI_API')
      allow(MB::Sound::DeviceOutput).to receive(:jack_running?).and_return(false)
      allow(MB::Sound::FastMIDI).to receive(:input_ports).and_call_original
      allow(MB::Sound::FastMIDI).to receive(:input_ports).with(:alsa, anything).and_return([])

      expect(MB::Sound::MIDI::Input.find_port('mbspec_key', kind: :input)).to eq([:alsa, nil, nil, { alsa: [] }])
      expect(MB::Sound::FastMIDI).not_to have_received(:input_ports).with(:jack, anything)
    end

    it 'connects to MIDI_DEVICE' do
      ENV['MIDI_DEVICE'] = 'mbspec_key'
      expect(input.connected_to).to eq('mbspec_keyboard:out')
    end

    it 'warns with the sources and opens an unconnected port when none match' do
      inp = nil
      expect { inp = input(connect: 'Launchkey') }.to output(/No MIDI source matches "Launchkey"; opening an unconnected port.*0: mbspec_keyboard:out/m).to_stderr
      expect(inp.connected_to).to be_nil
      expect(inp.connections).to eq(["#{MB::Sound::Jack.client_name}:midi_in"])
    end

    it 'creates midi_in on the script-named JACK client when not connecting' do
      MB::Sound::Jack.close
      ENV['JACK_CLIENT_NAME'] = 'my_synth'
      inp = input
      expect(inp.connected_to).to be_nil
      expect(inp.port).to eq('my_synth:midi_in')
      expect(inp.connections).to eq(['my_synth:midi_in'])

      second = input
      expect(second.port).to eq('my_synth:midi_in_2')
    end

    it 'gives raw JACK frame times with read_raw' do
      inp = input(connect: 'mbspec_keyboard')
      expect(inp.frame_times?).to eq(true)
      expect(inp.frame_rate).to eq(48000)
      expect(inp.read_raw).to eq([])
      sleep 0.05

      send([0x90, 64, 90])
      sleep 0.02
      send([0x80, 64, 0])
      raw = []
      deadline = MB::U.clock_now + 2
      raw.concat(inp.read_raw) while raw.length < 2 && MB::U.clock_now < deadline && sleep(0.005)

      expect(raw.map { |_, b| b.bytes }).to eq([[0x90, 64, 90], [0x80, 64, 0]])
      expect(raw.map(&:first)).to all(be_a(Integer))
      # About 20 ms apart, in whole 256-frame cycles (RtMidi's JACK output
      # sends at the start of a cycle)
      gap = (raw[1][0] - raw[0][0]) & 0xffff_ffff
      expect(gap % 256).to eq(0)
      expect(gap).to be_between(512, 4800)
    end

    it 'returns [] from #read_raw when nothing has arrived' do
      inp = input(connect: 'mbspec_keyboard')
      expect(inp.read_raw).to eq([])

      sleep 0.05
      send([0xb0, 7, 100])
      expect(wait_for(inp, 1).map { |_, b| b.bytes }).to eq([[0xb0, 7, 100]])
    end
  end
end
