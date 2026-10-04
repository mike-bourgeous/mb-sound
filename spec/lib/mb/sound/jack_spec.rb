# Every JACK port of a script on one JACK client (one JACK/PipeWire node),
# added at any time: the user's qpwgraph arrangements need this.
RSpec.describe(MB::Sound::Jack, :aggregate_failures) do
  ENV_NAMES = %w[AUDIO_BACKEND OUTPUT_DEVICE INPUT_DEVICE DEVICE MIDI_API MIDI_DEVICE JACK_CLIENT_NAME AUDIO_PROFILE].freeze

  around(:each) do |ex|
    saved = ENV_NAMES.to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }

    before(:each) do
      skip @jack_error if @jack_error
      ENV['AUDIO_BACKEND'] = 'jack'
      ENV['JACK_CLIENT_NAME'] = "mbspec_node#{rand(1 << 20)}"
      @opened = []
    end

    after(:each) do
      @opened.each(&:close)
      MB::Sound::Jack.close
    end

    def open(obj)
      @opened << obj
      obj
    end

    let(:client) { ENV['JACK_CLIENT_NAME'] }

    def client_ports
      MB::Sound::FastAudio.jack_ports("^#{client}:", nil, 0).map { |n| n.delete_prefix("#{client}:") }.sort
    end

    it 'puts outputs, inputs, and MIDI ports on one client, added at any time' do
      out = open(MB::Sound::DeviceOutput.new(channels: 2))
      expect(out.backend).to eq(:jack)
      expect(out.device_name).to eq(client)
      expect(out.jack_ports).to eq(["#{client}:out_1", "#{client}:out_2"])
      expect(MB::Sound::Jack.client_name).to eq(client)

      midi = open(MB::Sound::MIDI::Input.new)
      expect(midi.api).to eq(:jack)

      inp = open(MB::Sound::DeviceInput.new(channels: 2))
      expect(inp.backend).to eq(:jack)
      expect(inp.jack_ports).to eq(["#{client}:in_1", "#{client}:in_2"])

      later = open(MB::Sound::DeviceOutput.new(channels: 1))
      midi_out = open(MB::Sound::MIDI::Output.new)

      expect(later.jack_ports).to eq(["#{client}:out_3", "#{client}:out_4"])
      expect(client_ports).to eq(%w[in_1 in_2 midi_in midi_out out_1 out_2 out_3 out_4])
      expect(MB::Sound::FastAudio.jack_ports('^mbspec_node', nil, 0).map { |n| n.split(':').first }.uniq).to eq([client])

      later.close
      midi_out.close
      expect(client_ports).to eq(%w[in_1 in_2 midi_in out_1 out_2])
    end

    it 'connects new audio ports to the physical ports once' do
      MB::Sound::Jack.open
      physical_out = MB::Sound::FastAudio.jack_ports(nil, false, MB::Sound::FastAudio::JACK_PORT_IS_INPUT | MB::Sound::FastAudio::JACK_PORT_IS_PHYSICAL)
      physical_in = MB::Sound::FastAudio.jack_ports(nil, false, MB::Sound::FastAudio::JACK_PORT_IS_OUTPUT | MB::Sound::FastAudio::JACK_PORT_IS_PHYSICAL)
      skip 'the dummy server has no physical ports' if physical_out.length < 2 || physical_in.length < 2

      out = open(MB::Sound::DeviceOutput.new(channels: 2))
      expect(MB::Sound::Jack.connections(out.jack_ports[0])).to eq([physical_out[0]])
      expect(MB::Sound::Jack.connections(out.jack_ports[1])).to eq([physical_out[1]])

      inp = open(MB::Sound::DeviceInput.new(channels: 1))
      expect(MB::Sound::Jack.connections(inp.jack_ports[0])).to eq([physical_in[0]])
    end

    it "leaves ports unconnected with OUTPUT_DEVICE=none, and connects by name otherwise" do
      ENV['OUTPUT_DEVICE'] = 'none'
      out = open(MB::Sound::DeviceOutput.new(channels: 2))
      expect(out.jack_ports.map { |p| MB::Sound::Jack.connections(p) }).to eq([[], []])

      ENV['INPUT_DEVICE'] = "#{client}:out"
      inp = open(MB::Sound::DeviceInput.new(channels: 2))
      expect(inp.jack_ports.map { |p| MB::Sound::Jack.connections(p) }).to eq([["#{client}:out_1"], ["#{client}:out_2"]])
    end

    it 'plays a DeviceOutput into a DeviceInput on the same client' do
      ENV['OUTPUT_DEVICE'] = 'none'
      out = open(MB::Sound::DeviceOutput.new(channels: 1, latency: 0.02))
      ENV['INPUT_DEVICE'] = "#{client}:out_1"
      inp = open(MB::Sound::DeviceInput.new(channels: 1))

      # Read from before the write, so the input never skips audio to stay
      # near real time (it would if nothing read while #write waits)
      got = []
      reader = Thread.new do
        deadline = MB::U.clock_now + 3
        got.concat(inp.read(480)[0].to_a) while got.length < 14400 && MB::U.clock_now < deadline
      end
      sleep 0.05

      tone = Numo::SFloat.new(4800).seq.map { |i| Math.sin(i * 0.1) }
      out.write([tone])
      reader.join
      start = got.index { |v| v != 0 }
      expect(start).not_to be_nil
      # The tone's first sample is 0, so the first one heard is tone[1]
      expect(got[start, 4799]).to eq(tone.to_a[1, 4799])
    end
  end

  context 'without a JACK server' do
    it 'falls back to the next backend with a note' do
      ENV['AUDIO_BACKEND'] = 'jack,null'
      allow(MB::Sound::FastAudio).to receive(:jack_open).and_raise(MB::Sound::FastAudio::Error, 'Could not connect to a JACK server')
      out = nil
      expect { out = MB::Sound::DeviceOutput.new(channels: 2) }.to output(/JACK: Could not connect.*trying null/).to_stderr
      expect(out.backend).to eq(:null)
    ensure
      out&.close
    end
  end
end
