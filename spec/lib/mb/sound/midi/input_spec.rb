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

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) { skip @jack_error if @jack_error }

    let!(:output) { MB::Sound::FastMIDI::TestOutput.new(:jack, 'mbspec_keyboard', 'out') }

    before(:each) do
      ENV['MIDI_API'] = 'jack'
      @inputs = []
    end
    after(:each) do
      @inputs.each(&:close)
      output.close
    end

    def input(**kwargs)
      MB::Sound::MIDI::Input.new(**kwargs).tap { |i| @inputs << i }
    end

    def send(*messages)
      messages.each { |m| output.send_bytes(m.pack('C*')) }
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

    it 'connects to MIDI_DEVICE' do
      ENV['MIDI_DEVICE'] = 'mbspec_key'
      expect(input.connected_to).to eq('mbspec_keyboard:out')
    end

    it 'lists the sources when none match' do
      expect { input(connect: 'Launchkey') }.to raise_error(ArgumentError, /No MIDI source matches "Launchkey".*0: mbspec_keyboard:out/m)
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

    it 'is what MB::Sound.midi_manager opens for live MIDI (no JackFFI)' do
      expect(MB::Sound::JackFFI).not_to receive(:[]) if defined?(MB::Sound::JackFFI)
      manager = MB::Sound.midi_manager('mbspec_keyboard')
      @inputs << manager.instance_variable_get(:@midi_in)
      expect(manager.connections).to eq(['mbspec_keyboard:out'])
    ensure
      MB::Sound.instance_variable_get(:@midi_managers)&.delete('mbspec_keyboard')
    end
  end
end
