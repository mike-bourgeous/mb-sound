require 'shellwords'

# Real MIDI messages through a private JACK server with the dummy driver
# (see spec/support/jack_dummy.rb); the container has no ALSA sequencer.
RSpec.describe('MB::Sound::FastMIDI', :aggregate_failures) do
  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_midi.so', __dir__)
    code = 'require "bundler/setup"; GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastMIDI.respond_to?(:input_ports)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  it 'is RtMidi 6.0.0' do
    expect(MB::Sound::FastMIDI::RTMIDI_VERSION).to eq('6.0.0')
  end

  it 'lists its compiled APIs' do
    apis = MB::Sound::FastMIDI.compiled_apis
    if RUBY_PLATFORM =~ /darwin/
      expect(apis).to include(:core)
    else
      expect(apis).to include(:alsa)
    end
  end

  it 'raises for APIs that are not compiled in' do
    expect { MB::Sound::FastMIDI.input_ports(:winmm, 'x') }.to raise_error(ArgumentError, /not compiled in/)
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }
    before(:each) { skip @jack_error if @jack_error }

    let(:output) { @output = MB::Sound::FastMIDI::Output.new(:jack, 'mbspec_sender', nil, 'out') }
    after(:each) { @output&.close }

    def open_input(name = 'mbspec_receiver')
      index = MB::Sound::FastMIDI.input_ports(:jack, 'list').index('mbspec_sender:out')
      MB::Sound::FastMIDI::Input.new(:jack, name, index, 'midi_in', 100)
    end

    def wait_for(input, count)
      messages = []
      deadline = MB::U.clock_now + 2
      while messages.length < count && MB::U.clock_now < deadline
        messages.concat(input.read)
        sleep 0.005
      end
      messages
    end

    # Sends a probe until it arrives, so the JACK connection is live (under
    # load it can take longer than a fixed sleep; messages sent earlier are
    # lost), then drops anything still queued.
    def wait_for_connection(input)
      deadline = MB::U.clock_now + 5
      until MB::U.clock_now > deadline
        output.send_bytes([0x80, 0, 0].pack('C*'))
        sleep 0.02
        break unless input.read.empty?
      end
      sleep 0.05
      input.read
    end

    it 'receives exactly the messages sent' do
      output
      input = open_input
      expect(input.api).to eq(:jack)
      expect(input.ports).to include('mbspec_sender:out')
      wait_for_connection(input)

      sent = [[0x90, 60, 100], [0xb0, 1, 64], [0xe0, 0, 0x40], [0x80, 60, 0]]
      sent.each { |m| output.send_bytes(m.pack('C*')) }

      messages = wait_for(input, 4)
      expect(messages.map { |_, b| b.bytes }).to eq(sent)
      expect(messages.map(&:first)).to all(be >= 0)
      expect(input.read).to eq([])
    ensure
      input&.close
    end

    it 'receives SysEx' do
      output
      input = open_input
      sleep 0.05
      sysex = [0xf0, 0x7d, 1, 2, 3, 0xf7]
      output.send_bytes(sysex.pack('C*'))
      expect(wait_for(input, 1).map { |_, b| b.bytes }).to eq([sysex])
    ensure
      input&.close
    end

    it 'creates virtual input ports' do
      input = MB::Sound::FastMIDI::Input.new(:jack, 'mbspec_virtual', nil, 'virtual_in', 100)
      expect(input.closed?).to eq(false)
      input.close
      input.close
      expect(input.closed?).to eq(true)
      expect { input.read }.to raise_error(IOError, /closed/)
    end

    it 'refuses to read in a forked child' do
      input = open_input
      rd, wr = IO.pipe
      pid = fork do
        rd.close
        begin
          input.read
          wr.write('read')
        rescue IOError => e
          wr.write(e.message)
        end
        wr.close
        exit!(0)
      end
      wr.close
      Process.wait(pid)
      expect(rd.read).to match(/another process/)
    ensure
      input&.close
    end
  end
end
