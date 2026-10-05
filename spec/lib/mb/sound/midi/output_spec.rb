RSpec.describe(MB::Sound::MIDI::Output, :aggregate_failures) do
  around(:each) do |ex|
    saved = %w[MIDI_API MIDI_DEVICE JACK_CLIENT_NAME].to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) do
      skip @jack_error if @jack_error
      ENV['MIDI_API'] = 'jack'
      @ports = []
    end
    after(:each) do
      @ports.each(&:close)
      MB::Sound::Jack.close
    end

    def track(port)
      @ports << port
      port
    end

    # Reads until +count+ messages arrive
    def wait_for(input, count)
      events = []
      deadline = MB::U.clock_now + 2
      while events.length < count && MB::U.clock_now < deadline
        events.concat(input.read_raw)
        sleep 0.005
      end
      events.map { |_, b| b.bytes }
    end

    it 'connects to a destination by part of its name and sends Arrays and Strings' do
      ENV['JACK_CLIENT_NAME'] = 'mbspec_synth'
      input = track(MB::Sound::MIDI::Input.new) # mbspec_synth:midi_in on the shared client

      expect(MB::Sound::MIDI::Output.ports).to include('mbspec_synth:midi_in')
      out = track(MB::Sound::MIDI::Output.new(connect: 'SYNTH:midi_in'))
      expect(out.connected_to).to eq('mbspec_synth:midi_in')
      expect(out.port).to eq('mbspec_synth:midi_out')
      expect(out.connections).to eq(['mbspec_synth:midi_in'])
      expect(out.api).to eq(:jack)

      out.write([0x90, 62, 80])
      out << "\x80\x3e\x00".b
      expect(wait_for(input, 2)).to eq([[0x90, 62, 80], [0x80, 62, 0]])
    end

    it 'sends from a midi_out port on the script-named JACK client' do
      ENV['JACK_CLIENT_NAME'] = 'mbspec_seq'
      out = track(MB::Sound::MIDI::Output.new)
      expect(out.connections).to eq(['mbspec_seq:midi_out'])

      input = track(MB::Sound::MIDI::Input.new(connect: 'mbspec_seq:midi_out'))
      expect(input.connections).to eq(['mbspec_seq:midi_out'])
      expect(out.connections).to eq(['mbspec_seq:midi_in'])
      out.write([0xb0, 74, 33])
      expect(wait_for(input, 1)).to eq([[0xb0, 74, 33]])
    end

    it 'lists the destinations when none match' do
      expect { MB::Sound::MIDI::Output.new(connect: 'Prophet') }.to raise_error(ArgumentError, /No MIDI destination matches "Prophet"/)
    end

    it 'can be closed twice, and raises IOError when written after closing' do
      out = MB::Sound::MIDI::Output.new
      out.close
      out.close
      expect(out.closed?).to eq(true)
      expect(out.to_s).to include('closed')
      expect { out.write([0x90, 60, 1]) }.to raise_error(IOError, /closed/)
    end
  end
end
