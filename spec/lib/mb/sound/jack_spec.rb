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

      # Closed ports stay registered as disconnected spares while other
      # ports are in use (libjack can't unregister ports of an active client
      # safely; see mb_jack.c), and the next ports of their kind reuse them
      used, spare = client_ports.partition { |n| !n.start_with?('spare_') }
      expect(used).to eq(%w[in_1 in_2 midi_in out_1 out_2])
      expect(spare.map { |n| n[/\Aspare_(\w+?_\w+?)_\d+\z/, 1] }.sort).to eq(%w[audio_out audio_out midi_out])
      spare.each { |n| expect(MB::Sound::Jack.connections("#{client}:#{n}")).to eq([]) }

      again = open(MB::Sound::DeviceOutput.new(channels: 2))
      expect(again.jack_ports).to eq(["#{client}:out_3", "#{client}:out_4"])
      expect(client_ports.grep(/spare_audio/)).to eq([])
      expect(client_ports.grep(/spare_midi_out/).length).to eq(1)

      # Once no port is in use, spares are unregistered (behind a
      # deactivation that interrupts nothing)
      [out, midi, inp, again].each(&:close)
      expect(client_ports).to eq([])
      expect(MB::Sound::Jack.open?).to eq(true)
    end

    it 'closes the shared client at exit, so a --sync server goes on without waiting for it (test-speed-2)' do
      MB::Sound::Jack.open
      expect(MB::Sound::ExitClose.registered?(MB::Sound::Jack)).to eq(true)

      # A process that exited with the client open stalled the server for
      # 5 s (ten client timeouts), and with it this process's next cycle,
      # which a MIDI output's close waits for
      require 'shellwords'
      code = "require 'mb-sound'; MB::Sound::Jack.port_names('midi_in', 1); p MB::Sound::Jack.open?"
      out = `ruby -I#{File.expand_path('../../../../lib', __dir__).shellescape} -e #{code.shellescape} 2>&1`
      expect(out.strip.lines.last).to eq('true'), out
      keys = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_exit', nil, 'out')
      t = MB::U.clock_now
      keys.close
      expect(MB::U.clock_now - t).to be < 2.5
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

    it 'names CUE channels cue_1 and cue_2 after the outputs, connected to the next physical ports' do
      MB::Sound::Jack.open
      physical_out = MB::Sound::FastAudio.jack_ports(nil, false, MB::Sound::FastAudio::JACK_PORT_IS_INPUT | MB::Sound::FastAudio::JACK_PORT_IS_PHYSICAL)

      out = open(MB::Sound::DeviceOutput.new(channels: 4, cue: 2))
      expect(out.jack_ports).to eq(%w[out_1 out_2 cue_1 cue_2].map { |p| "#{client}:#{p}" })
      expect(out.cue_channels).to eq(2)
      out.jack_ports.each_with_index do |port, i|
        expect(MB::Sound::Jack.connections(port)).to eq(physical_out[i] ? [physical_out[i]] : [])
      end
      out.write(Array.new(4) { Numo::SFloat.zeros(out.buffer_size) })
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
