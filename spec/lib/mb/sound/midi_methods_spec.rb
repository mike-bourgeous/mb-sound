RSpec.describe(MB::Sound::MidiMethods, :aggregate_failures) do
  around(:each) do |ex|
    names = %w[
      AUDIO_BACKEND OUTPUT_TYPE OUTPUT_DEVICE DEVICE MIDI_API MIDI_DEVICE MIDI_TIMING JACK_CLIENT_NAME
      AUDIO_PROFILE AUDIO_LATENCY AUDIO_BUFFER
    ]
    saved = names.to_h { |k| [k, ENV.delete(k)] }
    ex.run
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  after(:each) do
    MB::Sound.close_midi
    MB::Sound::Session.default.close
    MB::Sound.rewind
  end

  # A MIDI::Input stand-in (see LiveSource's spec) that never receives
  # anything.
  let(:fake_input) {
    double('MIDI::Input', read_raw: [], frame_times?: false, frame_rate: nil, close: nil, port: 'fake')
  }

  describe '#live_midi_latency' do
    before(:each) do
      ENV['OUTPUT_TYPE'] = 'device'
      ENV['AUDIO_BACKEND'] = 'null' # miniaudio's null sound card
    end

    it 'switches the background session to the :low profile' do
      expect { expect(MB::Sound.live_midi_latency).to eq(:low) }.to output(/:low latency profile/).to_stderr
      expect(MB::Sound::Session.default.output.profile).to eq(:low)
      expect(MB::Sound::Session.output_chosen?).to eq(false)
      expect { expect(MB::Sound.live_midi_latency).to eq(:low) }.not_to output.to_stderr
    end

    it 'replaces an automatic output that was already opened' do
      expect(MB::Sound::Session.default.output.profile).to eq(:default)
      expect(MB::Sound.live_midi_latency(quiet: true)).to eq(:low)
      expect(MB::Sound::Session.default.output.profile).to eq(:low)
    end

    it 'leaves a profile chosen with AUDIO_PROFILE (set by -L and profile: in scripts)' do
      ENV['AUDIO_PROFILE'] = 'safe'
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output.profile).to eq(:safe)
    end

    it 'leaves a profile chosen with #latency or an output given to #use_output' do
      MB::Sound.latency(:default)
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output.profile).to eq(:default)

      out = MB::Sound::NullOutput.new(channels: 2)
      MB::Sound.use_output(out)
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output).to equal(out)

      # Back to the automatic output
      MB::Sound.use_output(nil)
      expect(MB::Sound.live_midi_latency(quiet: true)).to eq(:low)
    end

    it 'gives a hint instead of restarting a session with players or master effects' do
      MB::Sound.bg(220.hz.sine)
      expect { expect(MB::Sound.live_midi_latency).to eq(nil) }.to output(/`latency :low`/).to_stderr
      MB::Sound.panic
      MB::Sound::Session.default.close

      MB::Sound.master { |mix| mix.softclip }
      expect { expect(MB::Sound.live_midi_latency).to eq(nil) }.to output(/`latency :low`/).to_stderr
      expect(MB::Sound::Session.default.output.profile).to eq(:default)
    end

    it 'does nothing for outputs other than the sound card' do
      ENV['OUTPUT_TYPE'] = 'null'
      expect(MB::Sound.live_midi_latency).to eq(nil)
      expect(MB::Sound::Session.default.output).to be_a(MB::Sound::NullOutput)
    end
  end

  describe '#midi' do
    before(:each) do
      ENV['OUTPUT_TYPE'] = 'device'
      ENV['AUDIO_BACKEND'] = 'null'
      allow(MB::Sound::MIDI::Input).to receive(:new).and_return(fake_input)
    end

    it 'is a Notes on a cached live stream that follows the session output, switched to :low' do
      midi = nil
      expect { midi = MB::Sound.midi }.to output(/:low latency profile/).to_stderr
      expect(midi).to be_a(MB::Sound::Notes)
      expect(MB::Sound.midi).to equal(midi)
      expect(MB::Sound.midi_stream).to equal(midi.stream)

      source = midi.stream.source
      expect(source).to be_a(MB::Sound::MIDI::LiveSource)
      expect(source.timing).to eq(:exact)
      expect(source.output).to equal(MB::Sound::Session.default.output)
      expect(source.output.profile).to eq(:low)
    end

    it 'follows the output when the session switches outputs' do
      midi = MB::Sound.midi
      MB::Sound.latency(:safe)
      expect(midi.stream.source.output).to equal(MB::Sound::Session.default.output)
      expect(midi.stream.source.output.profile).to eq(:safe)
    end

    it 'opens a new input after #close_midi' do
      midi = MB::Sound.midi
      MB::Sound.close_midi
      expect(midi.stream.source).to be_closed
      expect(MB::Sound.midi).not_to equal(midi)
    end

    it 'leaves the output alone if the input fails to open' do
      allow(MB::Sound::MIDI::Input).to receive(:new).and_raise(MB::Sound::FastMIDI::Error, 'no MIDI')
      expect { MB::Sound.midi }.to raise_error(MB::Sound::FastMIDI::Error)
      expect(MB::Sound::Session.default.output.profile).to eq(:default)
    end

    it 'makes synths with Notes#synth and Synth.new' do
      expect(MB::Sound.midi.synth(voices: 2) { |v| v.hz.saw * v.amp_env }).to be_a(MB::Sound::Synth)
      expect(MB::Sound::Synth.new(MB::Sound.midi) { |v| v.gate }).to be_a(MB::Sound::Synth)
    end
  end

  describe 'old MIDI APIs given a Notes (old synth scripts)' do
    it 'reads the MIDI file of a file Notes' do
      notes = MB::Sound::Notes.new('spec/test_data/c2_sustain.mid')
      manager = MB::Sound.midi_manager(notes)
      expect(manager.midi_in).to be_a(MB::Sound::MIDI::MIDIFile)
      expect(manager.midi_in.filename).to eq('spec/test_data/c2_sustain.mid')
      expect(MB::Sound.midi_file(notes)).to be_a(MB::Sound::GraphNode::MidiDsl)
    end

    it 'shares the MIDI::Input of a live Notes' do
      ENV['OUTPUT_TYPE'] = 'null'
      allow(MB::Sound::MIDI::Input).to receive(:new).and_return(fake_input)
      notes = MB::Sound.midi
      manager = MB::Sound.midi_manager(notes)
      expect(manager.midi_in).to equal(fake_input)
      expect(MB::Sound.midi_manager(notes.stream)).to equal(manager)
      expect(MB::Sound.midi_file(notes).manager).to equal(manager)

      pool = MB::Sound.synth(notes, osc_count: 2, parameter_map: false) { |m| m.hz * m.env }
      expect(pool).to be_a(MB::Sound::MIDI::VoicePool)
    end
  end

  context 'with a JACK server' do
    before(:context) { @jack_error = JackDummy.start }
    after(:context) { JackDummy.stop }

    before(:each) do
      skip @jack_error if @jack_error
      ENV['OUTPUT_TYPE'] = 'null'
      ENV['JACK_CLIENT_NAME'] = "mbspec_console#{rand(1 << 20)}"
    end

    after(:each) do
      MB::Sound.close_midi
      MB::Sound::Jack.close
    end

    it 'plays notes sent to a port given by name' do
      ENV['MIDI_TIMING'] = 'asap'
      keyboard = MB::Sound::FastMIDI::Output.new(:jack, "#{ENV['JACK_CLIENT_NAME']}_keys", nil, 'out')
      midi = MB::Sound.midi("#{ENV['JACK_CLIENT_NAME']}_keys")
      expect(midi.stream.source.input.api).to eq(:jack)
      expect(midi.stream.source.input.connections.join).to include("#{ENV['JACK_CLIENT_NAME']}_keys")

      gate = midi.gate
      number = midi.number
      mod = midi.mod
      sleep 0.1
      keyboard.send_bytes([0xb0, 1, 127].pack('C*'))
      keyboard.send_bytes([0x90, 67, 100].pack('C*'))

      deadline = MB::U.clock_now + 3
      seen = nil
      until seen || MB::U.clock_now > deadline
        g = gate.sample(256).max
        n = number.sample(256).max
        m = mod.sample(256).max
        seen = [g, n, m] if g > 0
        sleep 0.005
      end

      expect(seen).to eq([1, 67, 1])
    ensure
      keyboard&.close
    end
  end
end
