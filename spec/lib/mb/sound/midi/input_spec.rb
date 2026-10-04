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

    it 'uses CoreMIDI on macOS' do
      allow(MB::Sound::FastMIDI).to receive(:compiled_apis).and_return([:core])
      expect(MB::Sound::MIDI::Input.api).to eq(:core)
    end
  end

  describe 'MB::Sound.midi_manager' do
    it 'refuses an existing file that is not a MIDI file' do
      expect { MB::Sound.midi_manager('spec/test_data/make_arp_a7.rb') }.to raise_error(ArgumentError, /make_arp_a7.rb is not a MIDI file/)
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
    end

    def input(**kwargs)
      MB::Sound::MIDI::Input.new(**kwargs).tap { |i| @inputs << i }
    end

    def send(*messages)
      messages.each { |m| keyboard.send_bytes(m.pack('C*')) }
    end

    # Reads until +count+ events arrive (Manager#update's read format)
    def wait_for(inp, count)
      events = []
      deadline = MB::U.clock_now + 2
      while events.length < count && MB::U.clock_now < deadline
        events.concat(inp.read[0])
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
      expect(events[0][0]).to eq(0.0)
      expect(events[1][0]).to be >= 0
    end

    it 'defaults to JACK MIDI when a JACK server answers' do
      ENV.delete('MIDI_API')
      expect(MB::Sound::FastMIDI.jack_server?).to eq(true)
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
      expect(inp.connections).to eq(["#{MB::Sound::DeviceOutput.client_name}:midi_in (virtual)"])
    end

    it 'creates a virtual port named after the script when not connecting' do
      ENV['JACK_CLIENT_NAME'] = 'my_synth'
      inp = input
      expect(inp.connected_to).to be_nil
      expect(inp.connections).to eq(['my_synth:midi_in (virtual)'])
    end

    it 'returns [[]] when nothing has arrived, and waits with blocking: true' do
      inp = input(connect: 'mbspec_keyboard')
      expect(inp.read).to eq([[]])

      Thread.new { sleep 0.05; send([0xb0, 7, 100]) }
      expect(inp.read(blocking: true)[0].map { |_, b| b.bytes }).to eq([[0xb0, 7, 100]])
    end

    it 'feeds a MIDI::Manager' do
      inp = input(connect: 'mbspec_keyboard')
      manager = MB::Sound::MIDI::Manager.new(input: inp, update_rate: 100)
      expect(manager.connections).to eq(['mbspec_keyboard:out'])

      notes = []
      manager.on_note { |note, velocity, onoff| notes << [note, velocity, onoff] }
      mod = nil
      manager.on_cc(1, range: 0..127, filter_hz: nil) { |v| mod = v }
      sleep 0.05
      send([0x90, 60, 100], [0xb0, 1, 127], [0x80, 60, 0])

      deadline = MB::U.clock_now + 2
      until notes.length >= 2 || MB::U.clock_now > deadline
        manager.update
        sleep 0.005
      end
      manager.update

      expect(notes.map { |n, v, on| [n, on] }).to eq([[60, true], [60, false]])
      expect(mod).to be_within(0.01).of(127)
    end

    it 'is what MB::Sound.midi_manager opens for live MIDI' do
      manager = MB::Sound.midi_manager('mbspec_keyboard')
      @inputs << manager.instance_variable_get(:@midi_in)
      expect(manager.connections).to eq(['mbspec_keyboard:out'])
    ensure
      MB::Sound.instance_variable_get(:@midi_managers)&.delete('mbspec_keyboard')
    end
  end
end
