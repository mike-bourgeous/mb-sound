RSpec.describe(MB::Sound::MIDI::Ports, :aggregate_failures) do
  around(:each) do |ex|
    saved = %w[MIDI_API MIDI_DEVICE JACK_CLIENT_NAME].to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  it 'refuses unknown directions and empty names' do
    expect { MB::Sound::MIDI::Ports.list(:sideways) }.to raise_error(ArgumentError, /:out .* or :in/)
    expect { MB::Sound::MIDI::Ports.find('', :out) }.to raise_error(ArgumentError, /part of a MIDI port name/)
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) do
      skip @jack_error if @jack_error
      ENV['MIDI_API'] = 'jack'
      ENV['JACK_CLIENT_NAME'] = 'mbspec_ports'
      # Two outside "synths" (their own JACK clients) and a keyboard
      @clients = [
        MB::Sound::FastMIDI::Input.new(:jack, 'mbspec_kronos', nil, 'MIDI 1', 100),
        MB::Sound::FastMIDI::Input.new(:jack, 'mbspec_sq80', nil, 'MIDI 1', 100),
        MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_keys', nil, 'out'),
      ]
    end
    after(:each) do
      @clients&.each(&:close)
      @own&.close
      MB::Sound::Jack.close
    end

    it 'lists destinations and sources with their clients and connections' do
      outs = MB::Sound::MIDI::Ports.list(:out)
      expect(outs.map(&:name)).to include('mbspec_kronos:MIDI 1', 'mbspec_sq80:MIDI 1')
      k = outs.find { |p| p.name == 'mbspec_kronos:MIDI 1' }
      expect([k.client, k.port, k.direction, k.api, k.own]).to eq(['mbspec_kronos', 'MIDI 1', :out, :jack, false])
      expect(k.connections).to eq([])
      expect(k.to_s).to start_with('out  mbspec_kronos:MIDI 1')

      ins = MB::Sound::MIDI::Ports.list(:in)
      expect(ins.map(&:name)).to include('mbspec_keys:out')
      expect(MB::Sound::MIDI::Ports.list.map(&:direction).uniq).to eq([:out, :in])

      @own = MB::Sound::MIDI::Output.new(connect: 'mbspec_kronos')
      k = MB::Sound::MIDI::Ports.list(:out).find { |p| p.name == 'mbspec_kronos:MIDI 1' }
      expect(k.connections).to eq(['mbspec_ports:midi_out'])
    end

    it 'finds one port by part of its name, ignoring case' do
      expect(MB::Sound::MIDI::Ports.find('KRONOS', :out).name).to eq('mbspec_kronos:MIDI 1')
      expect(MB::Sound::MIDI::Ports.find('keys', :in).name).to eq('mbspec_keys:out')
    end

    it 'reports ambiguous names with the candidates' do
      expect { MB::Sound::MIDI::Ports.find('MIDI 1', :out) }.to raise_error(MB::Sound::MIDI::Ports::Ambiguous) { |e|
        expect(e.message).to match(/2 MIDI destinations match "MIDI 1"; say more of the name/)
        expect(e.candidates.map(&:name)).to contain_exactly('mbspec_kronos:MIDI 1', 'mbspec_sq80:MIDI 1')
      }
    end

    it 'prefers a whole-name match among several that contain the name' do
      extra = MB::Sound::FastMIDI::Input.new(:jack, 'mbspec_kronos2', nil, 'in', 100)
      @clients << extra
      expect(MB::Sound::MIDI::Ports.find('mbspec_kronos', :out).name).to eq('mbspec_kronos:MIDI 1')
    end

    it 'says what is there, with a did-you-mean, when nothing matches' do
      expect { MB::Sound::MIDI::Ports.find('mbspec_kronoss', :out) }.to raise_error(MB::Sound::MIDI::Ports::NotFound) { |e|
        expect(e.message).to match(/No MIDI destination matches "mbspec_kronoss" \(did you mean "mbspec_kronos"\?\)/)
        expect(e.message).to include('  mbspec_sq80:MIDI 1')
        expect(e.names).to include('mbspec_kronos:MIDI 1')
      }
    end

    it 'leaves our own ports out of finds unless asked' do
      @own = MB::Sound::MIDI::Input.new # mbspec_ports:midi_in
      expect { MB::Sound::MIDI::Ports.find('mbspec_ports', :out) }.to raise_error(MB::Sound::MIDI::Ports::NotFound)
      expect(MB::Sound::MIDI::Ports.find('mbspec_ports', :out, own: true).name).to eq('mbspec_ports:midi_in')
      expect(MB::Sound::MIDI::Ports.list(:out).find(&:own).name).to eq('mbspec_ports:midi_in')
    end
  end
end
